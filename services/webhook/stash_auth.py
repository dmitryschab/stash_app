"""Sign in with Apple, Stash session tokens, invite codes, and the account routes.

This module is the only trust boundary the API has. There is no shared compiled-in
bearer token any more: every /v1 route except /health and /v1/auth/* hangs off
`current_user`, which returns an opaque per-user id or raises 401.

Token shapes:
  Apple identity token  RS256, verified against Apple's JWKS, iss/aud/exp all checked.
  Stash session JWT     HS256, 30 days, {sub, iat, exp, ver: 1}, signed with STASH_JWT_SECRET.
  Refresh token         32 random bytes hex, 180 days, stored only as a sha256 digest,
                        rotated on every use with the old one revoked first.

Item layout (all in the one imports table):
  PK="INSTALL#<userID>", SK="USER"          the account record
  PK="INSTALL#<userID>", SK="RT#<digest>"   mirror row, so DELETE /v1/me can find a
                                            user's refresh tokens without a GSI
  PK="RT#<digest>",      SK="META"          the lookup row a refresh call reads
  PK="INVITE#<code>",    SK="META"          invite code, redeemed by conditional write

Invite codes no longer gate sign-up (decided 2026-08-16: the €5 App Store price is the gate,
and an invite wall is what TikTok's reviewer read as internal use). They survive for one job:
a `demo` invite (manage_invites.py --demo) stamps `demo: true` on the account it creates, and
every session response plus /v1/me echoes it. That is the whole server side of the App Review
demo library — the library itself is local SwiftData, so seeding it here would mean inventing
a discovery path for imports the client never created. See SampleData.swift.

The Apple `sub` is never persisted: the user id is uuid5("stash-user/" + sub), so a
dump of this table cannot be joined back to an Apple account identifier.
"""

from __future__ import annotations

import hashlib
import json
import logging
import secrets
import time
import uuid
from datetime import datetime
from decimal import Decimal
from typing import Any, Iterator

import jwt
import requests
from fastapi import APIRouter, Depends, Header, HTTPException, Request, Response
from fastapi.responses import StreamingResponse
from pydantic import Field

import stash_secrets
import stash_subscription
from cloud_import_models import ContractModel
from cloud_import_store import DynamoImportStore, _is_conditional_failure, shared_table

log = logging.getLogger("stash-webhook")
router = APIRouter(prefix="/v1")

APPLE_JWKS_URL = "https://appleid.apple.com/auth/keys"
APPLE_ISS = "https://appleid.apple.com"
APPLE_TOKEN_URL = "https://appleid.apple.com/auth/token"
APPLE_REVOKE_URL = "https://appleid.apple.com/auth/revoke"
APP_AUD = "dev.dmitryschab.Stash"

STASH_JWT_VERSION = 1
STASH_JWT_TTL_SECONDS = 30 * 24 * 3600
REFRESH_TTL_SECONDS = 180 * 24 * 3600

# Apple rotates signing keys; 24 h is well inside their published cadence. An unknown
# kid triggers an out-of-band refetch, rate-limited so a caller spraying random kid
# values cannot turn this box into an outbound request amplifier.
JWKS_TTL_SECONDS = 24 * 3600
JWKS_REFETCH_MIN_INTERVAL = 60

_jwks: dict[str, Any] = {"keys": {}, "fetched_at": float("-inf"), "attempted_at": float("-inf")}


def _unauthorized(detail: str = "unauthorized") -> HTTPException:
    return HTTPException(status_code=401, detail=detail)


# ------------------------------------------------------------------ Apple identity


def _refresh_jwks() -> None:
    _jwks["attempted_at"] = time.monotonic()
    try:
        response = requests.get(APPLE_JWKS_URL, timeout=10)
        response.raise_for_status()
        keys = {}
        for entry in response.json().get("keys", []):
            if entry.get("kid") and entry.get("kty") == "RSA":
                # alg is forced, never read from the JWKS or the token header — the
                # algorithm allowlist is the whole defence against key-confusion.
                keys[entry["kid"]] = jwt.PyJWK({**entry, "alg": "RS256"}).key
    except Exception:
        log.exception("apple jwks fetch failed")
        return
    if keys:
        _jwks["keys"] = keys
        _jwks["fetched_at"] = time.monotonic()


def _apple_key(kid: str | None):
    now = time.monotonic()
    stale = now - _jwks["fetched_at"] >= JWKS_TTL_SECONDS
    if (stale or kid not in _jwks["keys"]) and now - _jwks["attempted_at"] >= JWKS_REFETCH_MIN_INTERVAL:
        _refresh_jwks()
    key = _jwks["keys"].get(kid)
    if key is None:
        raise _unauthorized("invalid apple token")
    return key


def verify_apple_identity_token(token: str) -> str:
    """Verify an Apple identity token end to end and return its `sub`."""
    try:
        kid = jwt.get_unverified_header(token).get("kid")
    except jwt.PyJWTError as error:
        raise _unauthorized("invalid apple token") from error
    key = _apple_key(kid)
    try:
        claims = jwt.decode(
            token,
            key,
            algorithms=["RS256"],
            audience=APP_AUD,
            issuer=APPLE_ISS,
            options={"require": ["exp", "iat", "aud", "iss", "sub"]},
        )
    except jwt.PyJWTError as error:
        raise _unauthorized("invalid apple token") from error
    sub = claims.get("sub")
    if not sub:
        raise _unauthorized("invalid apple token")
    return str(sub)


def user_id_for(apple_sub: str) -> str:
    return str(uuid.uuid5(uuid.NAMESPACE_URL, f"stash-user/{apple_sub}"))


# ------------------------------------------------------------------ Stash session JWT


def _jwt_secret() -> str:
    value = stash_secrets.secret("STASH_JWT_SECRET")
    if not value:
        # Fail closed: an unsigned or default-signed session token is worse than downtime.
        raise HTTPException(status_code=503, detail="auth not configured")
    return value


def mint_stash_jwt(user_id: str) -> tuple[str, int]:
    now = int(time.time())
    expires_at = now + STASH_JWT_TTL_SECONDS
    claims = {"sub": user_id, "iat": now, "exp": expires_at, "ver": STASH_JWT_VERSION}
    return jwt.encode(claims, _jwt_secret(), algorithm="HS256"), expires_at


def verify_stash_jwt(token: str) -> str:
    try:
        claims = jwt.decode(
            token, _jwt_secret(), algorithms=["HS256"], options={"require": ["exp", "iat", "sub"]}
        )
    except jwt.PyJWTError as error:
        raise _unauthorized() from error
    if claims.get("ver") != STASH_JWT_VERSION or not claims.get("sub"):
        raise _unauthorized()
    return str(claims["sub"])


# ------------------------------------------------------------------ records


def _user_key(user_id: str) -> dict[str, str]:
    return {"PK": f"INSTALL#{user_id}", "SK": "USER"}


def _get_user(table, user_id: str) -> dict[str, Any] | None:
    return table.get_item(Key=_user_key(user_id)).get("Item")


def _create_user(table, user_id: str, demo: bool = False) -> dict[str, Any]:
    item = {**_user_key(user_id), "userID": user_id, "createdAt": int(time.time()),
            "demo": demo}
    table.put_item(Item=item, ConditionExpression="attribute_not_exists(PK)")
    return item


def _hash(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


def issue_refresh_token(table, user_id: str) -> str:
    """Mint a refresh token, store only its digest, and mirror it into the user partition."""
    token = secrets.token_hex(32)
    digest = _hash(token)
    expires_at = int(time.time()) + REFRESH_TTL_SECONDS
    table.put_item(Item={"PK": f"RT#{digest}", "SK": "META", "userID": user_id,
                         "expiresAt": expires_at, "ttl": expires_at})
    table.put_item(Item={"PK": f"INSTALL#{user_id}", "SK": f"RT#{digest}", "expiresAt": expires_at,
                         "ttl": expires_at})
    return token


def revoke_refresh_token(table, user_id: str, digest: str) -> bool:
    """Delete the lookup row first, conditionally. The condition is what makes a replayed
    token lose the race: whoever deletes the row wins, the other caller gets 401."""
    try:
        table.delete_item(Key={"PK": f"RT#{digest}", "SK": "META"},
                          ConditionExpression="attribute_exists(PK)")
    except Exception as error:
        if _is_conditional_failure(error):
            return False
        raise
    table.delete_item(Key={"PK": f"INSTALL#{user_id}", "SK": f"RT#{digest}"})
    return True


def redeem_invite(table, code: str) -> dict[str, Any] | None:
    """Consume one use of an invite code and return it, or None if it was not redeemable.
    The conditional increment is atomic, so a single-use code cannot be redeemed twice even
    under concurrent sign-ups.

    Invites minted by manage_invites.py always carry expiresAt, which keeps this
    condition a plain AND chain; an invite written without it simply never matches.

    The redeemed row comes back rather than a bare bool because the caller needs its `demo`
    attribute, and ALL_NEW is free here — reading it separately would be a second round trip
    against a row another sign-up may already have moved.
    """
    try:
        response = table.update_item(
            Key={"PK": f"INVITE#{code}", "SK": "META"},
            UpdateExpression="SET usedCount = usedCount + :one",
            ConditionExpression="attribute_exists(PK) AND usedCount < maxUses AND expiresAt > :now",
            ExpressionAttributeValues={":one": 1, ":now": int(time.time())},
            ReturnValues="ALL_NEW",
        )
    except Exception as error:
        if _is_conditional_failure(error):
            return None
        raise
    return response.get("Attributes") or {}


def _return_invite(table, code: str) -> None:
    """Best-effort undo when the account create that followed a redemption failed."""
    try:
        table.update_item(
            Key={"PK": f"INVITE#{code}", "SK": "META"},
            UpdateExpression="SET usedCount = usedCount - :one",
            ConditionExpression="usedCount > :zero",
            ExpressionAttributeValues={":one": 1, ":zero": 0},
        )
    except Exception:
        log.exception("could not return invite use for %s", code)


# ------------------------------------------------------------------ dependencies


def current_user(request: Request, authorization: str | None = Header(None)) -> str:
    """Resolve the caller, or 401. Every /v1 route except /health and /v1/auth/* uses this."""
    if not authorization or not authorization.startswith("Bearer "):
        raise _unauthorized()
    user_id = verify_stash_jwt(authorization[7:].strip())
    # The account row is re-read on every request so DELETE /v1/me takes effect
    # immediately rather than when the 30-day session token happens to expire.
    if _get_user(shared_table(), user_id) is None:
        raise _unauthorized()
    request.state.user_id = user_id
    return user_id


def user_store(user_id: str = Depends(current_user)) -> DynamoImportStore:
    """The only way to get a store. There is no path to one without an authenticated user."""
    return DynamoImportStore(table=shared_table(), user_id=user_id)


def entitled_store(user_id: str = Depends(current_user)) -> DynamoImportStore:
    """A store for a caller who is allowed to spend money, or 402.

    Every route that reaches Bedrock, Groq or yt-dlp takes this one instead of `user_store`.
    It is a separate dependency rather than a check inside `peek_quota` on purpose: the store
    a metered route holds *is* the entitled store, so there is no version of that route that
    compiles without the check having run. Since 1.1 the app is free to download, and this is
    the whole of what stops a stranger signing in and spending our money.

    There are two ways through: a subscription (or demo, or a grandfathered purchase), and an
    unspent free trial. The trial is read from the quota row rather than the user record so
    that spending it, refunding it and reporting it all go through the one compare-and-set
    path that already exists — a second counter kept somewhere else is a second counter to
    get wrong.
    """
    store = DynamoImportStore(table=shared_table(), user_id=user_id)
    if stash_subscription.is_entitled(_get_user(shared_table(), user_id)):
        return store
    if store.get_quota().trial_remaining > 0:
        return store
    raise SubscriptionRequired()


class SubscriptionRequired(HTTPException):
    """402, and deliberately the same status as an exhausted quota — both mean "this costs
    money and you have none". The client tells them apart by `detail`: "quota exhausted"
    shows the counter and the reset date, this one shows the paywall. A plain HTTPException
    subclass, so app.py needs no handler for it.
    """

    def __init__(self):
        super().__init__(status_code=402, detail="subscription required")


class QuotaExhausted(Exception):
    """402. A plain HTTPException cannot express this: FastAPI always renders the body as
    {"detail": ...}, and the contract wants "detail" and "quota" as siblings at the top
    level. app.py registers the handler that renders it.
    """

    def __init__(self, quota):
        super().__init__("quota exhausted")
        self.quota = quota

    def body(self) -> dict[str, Any]:
        return {"detail": "quota exhausted", "quota": self.quota.model_dump(by_alias=True)}


def quota_exhausted(quota) -> QuotaExhausted:
    return QuotaExhausted(quota)


def peek_quota(store: DynamoImportStore):
    """402 before spending real money on a caller who has no budget left.

    ponytail: peek-then-commit is racy — two concurrent requests can both peek a single
    remaining unit and both proceed. The ceiling is one unit of overspend per user per
    race, which is not worth a lock on a single-box beta.
    """
    quota = store.get_quota()
    if quota.trial_remaining <= 0 and quota.initial_remaining <= 0 and quota.month_remaining <= 0:
        raise quota_exhausted(quota)
    return quota


# ------------------------------------------------------------------ Apple revocation


def _apple_client_secret() -> str | None:
    """The ES256 client-secret JWT Apple wants in place of a static secret."""
    team_id = stash_secrets.secret("APPLE_TEAM_ID")
    key_id = stash_secrets.secret("APPLE_KEY_ID")
    private_key = stash_secrets.secret("APPLE_PRIVATE_KEY")
    if not (team_id and key_id and private_key):
        return None
    now = int(time.time())
    return jwt.encode(
        {"iss": team_id, "iat": now, "exp": now + 300, "aud": APPLE_ISS, "sub": APP_AUD},
        private_key.replace("\\n", "\n"),
        algorithm="ES256",
        headers={"kid": key_id},
    )


def exchange_apple_code(code: str) -> str | None:
    """Trade a Sign in with Apple authorization code for a refresh token.

    Stored solely so DELETE /v1/me can call Apple's revoke endpoint, which App Store
    guideline 5.1.1(v) requires. Returns None when Apple credentials are not configured
    yet — sign-in must never fail because revocation plumbing is incomplete.

    That case is a WARNING, not silence: every account created while it is true can never
    have its Apple grant revoked, and the only other place it surfaces is a reviewer finding
    Stash still listed under Settings → Apple ID. deploy.sh refuses to deploy without the
    three credentials for the same reason; this covers a box whose secret was emptied after.
    """
    client_secret = _apple_client_secret()
    if not client_secret:
        log.warning("apple code exchange skipped: APPLE_TEAM_ID / APPLE_KEY_ID / "
                    "APPLE_PRIVATE_KEY not configured — this account cannot be revoked")
        return None
    try:
        response = requests.post(
            APPLE_TOKEN_URL,
            data={"client_id": APP_AUD, "client_secret": client_secret,
                  "code": code, "grant_type": "authorization_code"},
            timeout=15,
        )
        if response.status_code != 200:
            log.warning("apple code exchange returned %s", response.status_code)
            return None
        return response.json().get("refresh_token")
    except Exception:
        log.exception("apple code exchange failed")
        return None


def revoke_apple_token(table, user_id: str) -> None:
    """Revoke the user's Apple token on account deletion. Never raises: a deletion that
    failed because Apple was unreachable would leave the user's data behind, which is
    the worse outcome of the two."""
    user = _get_user(table, user_id) or {}
    token = user.get("appleRefreshToken")
    if not token:
        log.warning("apple revoke skipped: no stored refresh token for %s", user_id)
        return
    client_secret = _apple_client_secret()
    if not client_secret:
        log.warning("apple revoke skipped: apple credentials not configured, %s keeps its grant",
                    user_id)
        return
    try:
        response = requests.post(
            APPLE_REVOKE_URL,
            data={"client_id": APP_AUD, "client_secret": client_secret,
                  "token": token, "token_type_hint": "refresh_token"},
            timeout=15,
        )
        if response.status_code != 200:
            log.warning("apple revoke returned %s", response.status_code)
    except Exception:
        log.exception("apple revoke failed")


# ------------------------------------------------------------------ routes


class AppleAuthRequest(ContractModel):
    identity_token: str = Field(alias="identityToken", min_length=1, max_length=8192)
    invite_code: str | None = Field(alias="inviteCode", default=None, max_length=64)
    # Optional: only an authorization code lets the server obtain the Apple refresh token
    # that DELETE /v1/me needs in order to revoke. Sign-in works fine without it.
    authorization_code: str | None = Field(alias="authorizationCode", default=None, max_length=1024)


class RefreshRequest(ContractModel):
    refresh_token: str = Field(alias="refreshToken", min_length=1, max_length=256)


def _session_response(table, user_id: str, *, include_user_id: bool, demo: bool,
                      entitled: bool) -> dict[str, Any]:
    token, expires_at = mint_stash_jwt(user_id)
    quota = DynamoImportStore(table=table, user_id=user_id).get_quota()
    body = {
        "token": token,
        "expiresAt": expires_at,
        "refreshToken": issue_refresh_token(table, user_id),
        "quota": quota.model_dump(by_alias=True),
        # Rides on refresh as well as sign-in: the client keeps this in its session, and a
        # session that rotated its way out of the flag would stop being a demo account.
        "demo": demo,
        # Saves the app a round trip before it knows whether to draw the paywall. Advisory
        # only — the server re-checks on every metered route, so a client that lies about
        # this gets a 402 the moment it tries to spend anything.
        "entitled": entitled,
    }
    if include_user_id:
        body["userID"] = user_id
    return body


@router.post("/auth/apple")
def auth_apple(body: AppleAuthRequest):
    apple_sub = verify_apple_identity_token(body.identity_token)
    user_id = user_id_for(apple_sub)
    table = shared_table()

    user = _get_user(table, user_id)
    demo = bool((user or {}).get("demo"))
    if user is None:
        # Sign-up is open: the €5 App Store price is the gate, not an invite code (decided
        # 2026-08-16 — an invite wall is what TikTok's reviewer read as internal use). Codes
        # still exist for one reason: a `--demo` invite stamps demo=true, which seeds App
        # Review a populated library. So a code is optional, and only a *wrong* one is refused.
        code = (body.invite_code or "").strip().upper()
        invite = redeem_invite(table, code) if code else None
        if code and invite is None:
            # A spent, expired and never-minted code are indistinguishable here on purpose,
            # so this endpoint cannot be used to probe which codes exist.
            raise HTTPException(status_code=403, detail="that code was not accepted")
        demo = bool((invite or {}).get("demo"))
        try:
            _create_user(table, user_id, demo)
        except Exception as error:
            if code:
                _return_invite(table, code)
            # A conditional failure here means the row appeared between the read above and
            # this write — a concurrent sign-in, or the client retrying after a response it
            # never saw. Same Apple sub, so it is the same person: hand the invite use back
            # and go on to issue the session. 500ing a caller whose account now exists made
            # a double-tapped Sign in with Apple look like an outage.
            if not _is_conditional_failure(error):
                raise

    if body.authorization_code:
        apple_refresh = exchange_apple_code(body.authorization_code)
        if apple_refresh:
            table.update_item(
                Key=_user_key(user_id),
                UpdateExpression="SET appleRefreshToken = :token",
                ExpressionAttributeValues={":token": apple_refresh},
            )
    # Re-read rather than trusting `demo`: a returning subscriber's entitlement is on the row,
    # and a brand-new account has none until it posts a transaction to /v1/me/subscription.
    return _session_response(table, user_id, include_user_id=True, demo=demo,
                             entitled=stash_subscription.is_entitled(_get_user(table, user_id)))


@router.post("/auth/refresh")
def auth_refresh(body: RefreshRequest):
    table = shared_table()
    digest = _hash(body.refresh_token)
    item = table.get_item(Key={"PK": f"RT#{digest}", "SK": "META"}).get("Item")
    # Expiry is checked here, not left to Dynamo's TTL sweeper, which lags up to 48 h.
    if not item or int(item.get("expiresAt", 0)) <= int(time.time()):
        raise _unauthorized()
    user_id = str(item["userID"])
    user = _get_user(table, user_id)
    if user is None:
        raise _unauthorized()
    # Revoke before issuing: a crash in between logs the user out, which fails closed.
    if not revoke_refresh_token(table, user_id, digest):
        raise _unauthorized()
    return _session_response(table, user_id, include_user_id=False, demo=bool(user.get("demo")),
                             entitled=stash_subscription.is_entitled(user))


@router.get("/me")
def get_me(user_id: str = Depends(current_user)):
    table = shared_table()
    user = _get_user(table, user_id) or {}
    quota = DynamoImportStore(table=table, user_id=user_id).get_quota()
    return {
        "userID": user_id,
        "createdAt": int(user.get("createdAt", 0)),
        "quota": quota.model_dump(by_alias=True),
        # Repeated here so a reinstall that restores a session from the Keychain still
        # learns it is a demo account without waiting for the next token rotation.
        "demo": bool(user.get("demo")),
        "entitled": stash_subscription.is_entitled(user),
        "subscriptionExpiresAt": int(user.get("subscriptionExpiresAt", 0) or 0),
    }


class SubscriptionRequest(ContractModel):
    """Whatever StoreKit 2 had to offer. Both are optional and both are JWS blobs Apple
    signed: a subscriber has the transaction, someone who bought 1.0 outright has only the
    AppTransaction, and an app posting on a cold launch may have neither — which is itself
    the answer, and drops the account back to unentitled."""

    signed_transaction: str | None = Field(alias="signedTransaction", default=None,
                                           max_length=16384)
    signed_app_transaction: str | None = Field(alias="signedAppTransaction", default=None,
                                               max_length=16384)


@router.post("/me/subscription")
def put_subscription(body: SubscriptionRequest, user_id: str = Depends(current_user)):
    """Record what Apple says this account is entitled to.

    The app posts here on launch, after a purchase and after a restore. Everything it sends
    is verified against Apple's root CA before it is written, so the worst a hostile client
    can do is send nothing — and nothing means no entitlement.
    """
    table = shared_table()
    try:
        fields = stash_subscription.entitlement(
            signed_transaction=body.signed_transaction,
            signed_app_transaction=body.signed_app_transaction,
        )
    except Exception as error:
        # A blob that fails verification is not a server fault and must not read as one.
        log.warning("subscription verification failed for %s: %s", user_id, error)
        raise HTTPException(status_code=400, detail="could not verify that receipt")

    # `lifetime` is sticky: an owner of the paid 1.0 who later reinstalls onto a device whose
    # AppTransaction we cannot read must not lose what they bought.
    expression = "SET subscriptionExpiresAt = :expires"
    values: dict[str, Any] = {":expires": fields["subscriptionExpiresAt"]}
    if fields["lifetime"]:
        expression += ", lifetime = :lifetime"
        values[":lifetime"] = True
    table.update_item(Key=_user_key(user_id), UpdateExpression=expression,
                      ExpressionAttributeValues=values)

    user = _get_user(table, user_id)
    return {"entitled": stash_subscription.is_entitled(user),
            "subscriptionExpiresAt": fields["subscriptionExpiresAt"],
            "lifetime": bool((user or {}).get("lifetime"))}


@router.delete("/me", status_code=204)
def delete_me(user_id: str = Depends(current_user)):
    """Erase the account. Required by App Store guideline 5.1.1(v)."""
    table = shared_table()
    revoke_apple_token(table, user_id)
    removed = DynamoImportStore(table=table, user_id=user_id).delete_user_items()
    for key in removed:
        # The mirror row's SK is the lookup row's PK, so no extra bookkeeping is needed.
        if key["SK"].startswith("RT#"):
            table.delete_item(Key={"PK": key["SK"], "SK": "META"})
    log.info("deleted account %s (%d items)", user_id, len(removed))
    return Response(status_code=204)


def _json_safe(value: Any) -> Any:
    if isinstance(value, Decimal):
        return int(value) if value == value.to_integral_value() else float(value)
    if isinstance(value, datetime):
        return value.isoformat()
    raise TypeError(f"cannot serialise {type(value).__name__}")


def _export_items(store: DynamoImportStore) -> Iterator[dict[str, Any]]:
    for item in store.iter_user_items():
        if item.get("SK", "").startswith("RT#"):
            continue  # session credentials are not user data
        item.pop("appleRefreshToken", None)
        yield item


def _export_stream(store: DynamoImportStore, user_id: str) -> Iterator[str]:
    """Assemble the export while paging. A 1200-video account will not fit twice in
    the 1 GB this box has, so the document is never materialised in memory."""
    yield '{"userID":%s,"exportedAt":%d,"items":[' % (json.dumps(user_id), int(time.time()))
    separator = ""
    for item in _export_items(store):
        yield separator + json.dumps(item, default=_json_safe)
        separator = ","
    yield "]}"


@router.get("/me/export")
def export_me(user_id: str = Depends(current_user)):
    store = DynamoImportStore(table=shared_table(), user_id=user_id)
    return StreamingResponse(_export_stream(store, user_id), media_type="application/json")
