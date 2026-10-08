"""Stash /v1 TikTok connection — link, unlink, and revoke when the account is deleted.

  POST   /v1/tiktok/connect  {code, codeVerifier, storefront} -> {displayName, connectedAt}
  DELETE /v1/tiktok/connect                       -> 204

The app runs TikTok's Login Kit (PKCE, scope user.info.basic) and hands over the authorization
code and the PKCE verifier. The code is traded for tokens here, because the client secret lives
on the box and never reaches the app. Nothing is downloaded or imported yet: P1 is the
connection and its clean ending. See docs/superpowers/specs/2026-09-13-tiktok-oauth-p1-design.md.

One row per account, PK="INSTALL#<userID>" SK="TIKTOK", so DELETE /v1/me takes it with the rest
of the partition and connecting again replaces it. The tokens sit in that row under DynamoDB's
server-side encryption, like appleRefreshToken, and GET /v1/me/export strips them.

No entitlement check: connecting spends nothing, so a caller with no subscription may link.
There is a region check: the approved Data Portability application offers the integration in
the EEA and the UK only, told apart by the App Store storefront the app reports.
"""
import logging
import time

import requests
from fastapi import APIRouter, Depends, HTTPException, Response
from pydantic import Field

import stash_secrets
from cloud_import_models import ContractModel
from cloud_import_store import _is_conditional_failure, shared_table
from stash_auth import _tiktok_key, current_user

log = logging.getLogger("stash-webhook")

router = APIRouter(prefix="/v1")

TIKTOK_TOKEN_URL = "https://open.tiktokapis.com/v2/oauth/token/"
TIKTOK_REVOKE_URL = "https://open.tiktokapis.com/v2/oauth/revoke/"
TIKTOK_USER_INFO_URL = "https://open.tiktokapis.com/v2/user/info/"
# Must match, byte for byte, the redirect URI the app sends and the one registered in the portal.
TIKTOK_REDIRECT_URI = "https://stash.dmitrijs.dev/tiktok/callback"
TIKTOK_TIMEOUT = 15

# A 24 h access token this close to lapsing is refreshed before it is used: revoking a dead
# token ends nothing, and the grant would live on at TikTok; a sync with one is refused.
REFRESH_MARGIN_SECONDS = 60

# The storefronts TikTok sync is offered in: the EU27, the rest of the EEA, and the UK, in the
# ISO 3166-1 alpha-3 form StoreKit's `Storefront.countryCode` reports. The app keeps the same
# list as `TikTokConnectClient.allowedStorefronts` in TikTokBrainKit's TikTokConnect.swift;
# change both together.
ALLOWED_STOREFRONTS = frozenset({
    "AUT", "BEL", "BGR", "HRV", "CYP", "CZE", "DNK", "EST", "FIN", "FRA", "DEU", "GRC", "HUN",
    "IRL", "ITA", "LVA", "LTU", "LUX", "MLT", "NLD", "POL", "PRT", "ROU", "SVK", "SVN", "ESP",
    "SWE",
    "ISL", "LIE", "NOR",
    "GBR",
})
OUTSIDE_REGION = "TikTok sync is available in the EEA and the UK."


def _json(response) -> dict:
    """The response body as a dict, or {} for anything that is not one."""
    try:
        body = response.json()
    except ValueError:
        return {}
    return body if isinstance(body, dict) else {}


class ConnectRequest(ContractModel):
    code: str = Field(min_length=1, max_length=1024)
    code_verifier: str = Field(alias="codeVerifier", min_length=43, max_length=128)
    # Optional in the schema so an app too old to send it gets the region's 403, not a 422.
    storefront: str | None = None


@router.post("/tiktok/connect")
def connect(body: ConnectRequest, user_id: str = Depends(current_user)):
    if (body.storefront or "").upper() not in ALLOWED_STOREFRONTS:
        log.info("tiktok connect refused: storefront %r is outside the EEA and the UK",
                 (body.storefront or "")[:16])
        raise HTTPException(status_code=403, detail=OUTSIDE_REGION)
    client_key = stash_secrets.secret("TIKTOK_CLIENT_KEY")
    client_secret = stash_secrets.secret("TIKTOK_CLIENT_SECRET")
    if not (client_key and client_secret):
        log.warning("tiktok connect refused: TIKTOK_CLIENT_KEY / TIKTOK_CLIENT_SECRET not configured")
        raise HTTPException(status_code=503, detail="TikTok sign-in is not configured")
    try:
        response = requests.post(
            TIKTOK_TOKEN_URL,
            data={"client_key": client_key, "client_secret": client_secret, "code": body.code,
                  "grant_type": "authorization_code", "redirect_uri": TIKTOK_REDIRECT_URI,
                  "code_verifier": body.code_verifier},
            timeout=TIKTOK_TIMEOUT,
        )
    except requests.RequestException as error:
        log.exception("tiktok code exchange failed")
        raise HTTPException(status_code=502, detail="couldn't reach TikTok") from error
    if response.status_code >= 500:
        log.warning("tiktok code exchange returned %s", response.status_code)
        raise HTTPException(status_code=502, detail="couldn't reach TikTok")
    token = _json(response)
    if not token.get("access_token"):
        log.warning("tiktok rejected the code: %s %s", response.status_code, token.get("error"))
        raise HTTPException(status_code=400, detail="TikTok didn't accept that sign-in")

    # The name is cosmetic. A failure here must not undo a sign-in TikTok already granted.
    user: dict = {}
    try:
        info = requests.get(
            TIKTOK_USER_INFO_URL,
            params={"fields": "open_id,display_name"},
            headers={"Authorization": f"Bearer {token['access_token']}"},
            timeout=TIKTOK_TIMEOUT,
        )
        if info.status_code != 200:
            log.warning("tiktok user info returned %s", info.status_code)
        user = (_json(info).get("data") or {}).get("user") or {}
    except Exception:
        log.exception("tiktok user info failed")
    display_name = user.get("display_name") or ""

    now = int(time.time())
    shared_table().put_item(Item={
        **_tiktok_key(user_id),
        "openID": token.get("open_id") or user.get("open_id") or "",
        "displayName": display_name,
        "scope": token.get("scope") or "",
        "accessToken": token["access_token"],
        "accessExpiresAt": now + int(token.get("expires_in") or 0),
        "refreshToken": token.get("refresh_token") or "",
        "refreshExpiresAt": now + int(token.get("refresh_expires_in") or 0),
        "connectedAt": now,
    })
    return {"displayName": display_name, "connectedAt": now}


@router.delete("/tiktok/connect", status_code=204)
def disconnect(user_id: str = Depends(current_user)):
    """Unlink TikTok. Idempotent: a 204 whether or not a connection existed."""
    table = shared_table()
    revoke_tiktok(table, user_id)
    table.delete_item(Key=_tiktok_key(user_id))
    return Response(status_code=204)


def revoke_tiktok(table, user_id: str) -> None:
    """End the user's TikTok access, for disconnect and for account deletion. Never raises on a
    TikTok failure: a deletion that failed because TikTok was unreachable would leave the user's
    data behind, which is the worse outcome of the two. Every failure is a warning instead."""
    row = table.get_item(Key=_tiktok_key(user_id)).get("Item")
    if not row:
        return
    client_key = stash_secrets.secret("TIKTOK_CLIENT_KEY")
    client_secret = stash_secrets.secret("TIKTOK_CLIENT_SECRET")
    if not (client_key and client_secret):
        log.warning("tiktok revoke skipped: TikTok credentials not configured, %s keeps its grant",
                    user_id)
        return
    try:
        token = row["accessToken"]
        try:
            # A refresh TikTok refused or failed leaves the old token, which is still worth a try.
            token = live_access_token(table, user_id, row, client_key, client_secret) or token
        except requests.RequestException:
            log.warning("tiktok refresh before revoke failed")
        response = requests.post(
            TIKTOK_REVOKE_URL,
            data={"client_key": client_key, "client_secret": client_secret, "token": token},
            timeout=TIKTOK_TIMEOUT,
        )
        if response.status_code != 200:
            log.warning("tiktok revoke returned %s", response.status_code)
    except Exception:
        log.exception("tiktok revoke failed")


def live_access_token(table, user_id: str, row: dict, client_key: str,
                      client_secret: str) -> str | None:
    """The row's access token, or a refreshed one when it lapses within REFRESH_MARGIN_SECONDS.

    A refresh is persisted on the row straight away, refresh token included: TikTok may rotate
    it, and a row left holding the old one could never refresh again. None when the refresh
    token has lapsed or TikTok rejected the grant, which means the user revoked us. Raises
    requests.RequestException when TikTok could not be reached, failed (5xx) or was busy (429),
    so a caller never mistakes TikTok being down for the user leaving.

    ponytail: two calls refreshing at the same moment both spend the same refresh token. If
    TikTok voids it on rotation, the loser reads that as a revoke and its caller drops the
    connection. One reconnect per collision; a lock is not worth it at one sync a day.
    """
    now = int(time.time())
    if int(row["accessExpiresAt"]) - now >= REFRESH_MARGIN_SECONDS:
        return row["accessToken"]
    if int(row["refreshExpiresAt"]) <= now:
        return None
    response = requests.post(
        TIKTOK_TOKEN_URL,
        data={"client_key": client_key, "client_secret": client_secret,
              "grant_type": "refresh_token", "refresh_token": row["refreshToken"]},
        timeout=TIKTOK_TIMEOUT,
    )
    if response.status_code >= 500 or response.status_code == 429:
        raise requests.HTTPError(f"tiktok refresh returned {response.status_code}")
    token = _json(response)
    if not token.get("access_token"):
        log.warning("tiktok refresh returned %s %s", response.status_code, token.get("error"))
        return None
    try:
        # Conditional, so a connection removed meanwhile is not resurrected as a bare token row.
        table.update_item(
            Key=_tiktok_key(user_id),
            UpdateExpression="SET accessToken = :access, accessExpiresAt = :access_expires, "
                             "refreshToken = :refresh, refreshExpiresAt = :refresh_expires",
            ConditionExpression="attribute_exists(PK)",
            ExpressionAttributeValues={
                ":access": token["access_token"],
                ":access_expires": now + int(token.get("expires_in") or 0),
                ":refresh": token.get("refresh_token") or row["refreshToken"],
                ":refresh_expires": now + int(token["refresh_expires_in"])
                                    if token.get("refresh_expires_in")
                                    else int(row["refreshExpiresAt"]),
            },
        )
    except Exception as error:
        if not _is_conditional_failure(error):
            raise
    return token["access_token"]
