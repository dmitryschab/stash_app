"""Contract tests for the only trust boundary: sign-in, invites, sessions, isolation."""

import base64
import hashlib
import hmac
import json
import time
from types import SimpleNamespace

import jwt
import pytest
from cryptography.hazmat.primitives import serialization
from fastapi.testclient import TestClient

import cloud_import_api
import manage_invites
import stash_auth
import stash_secrets
import stash_subscription
from app import app
from conftest import ConditionalTable

USER_A = "apple-sub-a"
USER_B = "apple-sub-b"


class FakeQueue:
    def __init__(self):
        self.messages = []

    def enqueue(self, user_id, import_id, video_id, url=None):
        self.messages.append({"userID": user_id, "importID": import_id, "videoID": video_id})


@pytest.fixture
def table(monkeypatch, apple):
    fake = ConditionalTable()
    # 32+ bytes, matching what the box's Secrets Manager entry must hold for HS256.
    monkeypatch.setenv("STASH_JWT_SECRET", "test-signing-secret-at-least-32-bytes-long")
    stash_secrets.reset_cache()
    monkeypatch.setattr(stash_auth, "shared_table", lambda: fake)
    # Pre-seed the JWKS cache and mark it just-fetched, so an unknown kid in a test never
    # reaches out to Apple: the 60 s refetch floor is what blocks it.
    monkeypatch.setattr(stash_auth, "_jwks", {
        "keys": {apple.kid: apple.private_key.public_key()},
        "fetched_at": time.monotonic(),
        "attempted_at": time.monotonic(),
    })
    # The paid-era grandfather is a calendar transition: every account a test creates is made
    # "now", which is inside the window, so leaving it on would silently entitle every account
    # in this file and quietly disarm the paywall tests. Off by default; the rule has its own
    # tests below that set the cutoff explicitly.
    monkeypatch.setattr(stash_subscription, "PAID_ERA_ENDS", 0)
    app.dependency_overrides[cloud_import_api.get_queue] = FakeQueue
    yield fake
    app.dependency_overrides.clear()
    stash_secrets.reset_cache()


def invite(table, code="STASH-TEST-AAAA", uses=1, expires_in=3600, demo=False):
    table.put_item(Item={"PK": f"INVITE#{code}", "SK": "META", "code": code, "maxUses": uses,
                         "usedCount": 0, "createdAt": int(time.time()),
                         "expiresAt": int(time.time()) + expires_in, "demo": demo})
    return code


def sign_in(client, apple, sub=USER_A, code=None):
    body = {"identityToken": apple.token(sub)}
    if code:
        body["inviteCode"] = code
    return client.post("/v1/auth/apple", json=body)


def session(client, apple, table, sub=USER_A, entitled=True):
    response = sign_in(client, apple, sub, invite(table, f"STASH-{sub[-1].upper()*4}-CODE"))
    assert response.status_code == 200, response.text
    if entitled:
        # Since 1.1 every metered route 402s without a subscription, which would stop these
        # tests at the paywall instead of at the thing they are about (isolation, quota,
        # idempotency). Stamp the row the way a grandfathered 1.0 buyer's would be. The
        # paywall itself is tested separately, below.
        grant(table, sub)
    return response.json()


def grant(table, sub=USER_A, **fields):
    """Write an entitlement straight onto the user row, bypassing receipt verification."""
    fields = fields or {"lifetime": True}
    names = ", ".join(f"{key} = :{key}" for key in fields)
    table.update_item(Key=stash_auth._user_key(stash_auth.user_id_for(sub)),
                      UpdateExpression=f"SET {names}",
                      ExpressionAttributeValues={f":{k}": v for k, v in fields.items()})


def auth(token):
    return {"Authorization": f"Bearer {token}"}


def payload(count=2, client_import_id="11111111-1111-4111-8111-111111111111"):
    return {
        "clientImportID": client_import_id,
        "videos": [
            {"videoID": str(index), "url": f"https://www.tiktok.com/@x/video/{index}",
             "bookmarkedAt": "2026-07-01T00:00:00Z"}
            for index in range(1, count + 1)
        ],
    }


# ------------------------------------------------------------------ Apple verification


def test_apple_token_rejected_on_bad_signature(table, apple):
    from conftest import AppleSigner

    forger = AppleSigner(kid=apple.kid)  # same kid, different private key
    with TestClient(app) as client:
        response = client.post("/v1/auth/apple", json={"identityToken": forger.token(USER_A)})
    assert response.status_code == 401


def test_apple_token_rejected_on_wrong_audience(table, apple):
    with TestClient(app) as client:
        response = client.post("/v1/auth/apple",
                               json={"identityToken": apple.token(USER_A, audience="com.other.app")})
    assert response.status_code == 401


def test_apple_token_rejected_when_expired(table, apple):
    with TestClient(app) as client:
        response = client.post("/v1/auth/apple",
                               json={"identityToken": apple.token(USER_A, expires_in=-30)})
    assert response.status_code == 401


def test_apple_token_rejected_on_wrong_issuer(table, apple):
    with TestClient(app) as client:
        response = client.post("/v1/auth/apple",
                               json={"identityToken": apple.token(USER_A, issuer="https://evil.test")})
    assert response.status_code == 401


def test_unsigned_apple_token_is_rejected(table, apple):
    """alg:none is the cheapest forgery there is; the RS256 allowlist is what stops it."""
    now = int(time.time())
    unsigned = jwt.encode(
        {"iss": "https://appleid.apple.com", "aud": "dev.dmitryschab.Stash",
         "sub": USER_A, "iat": now, "exp": now + 600},
        key="", algorithm="none", headers={"kid": apple.kid},
    )
    with TestClient(app) as client:
        response = client.post("/v1/auth/apple", json={"identityToken": unsigned})
    assert response.status_code == 401


def test_symmetrically_signed_apple_token_is_rejected(table, apple):
    """Key confusion: claim HS256 in the header and sign with Apple's *public* key as the
    shared secret. Assembled by hand because PyJWT refuses to build it — only an algorithm
    allowlist that never reads the token header defeats this on the verifying side."""
    now = int(time.time())
    public_pem = apple.private_key.public_key().public_bytes(
        serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo)

    def segment(payload):
        return base64.urlsafe_b64encode(json.dumps(payload).encode()).rstrip(b"=")

    signing_input = b".".join([
        segment({"alg": "HS256", "kid": apple.kid, "typ": "JWT"}),
        segment({"iss": "https://appleid.apple.com", "aud": "dev.dmitryschab.Stash",
                 "sub": USER_A, "iat": now, "exp": now + 600}),
    ])
    signature = hmac.new(public_pem, signing_input, hashlib.sha256).digest()
    forged = (signing_input + b"." + base64.urlsafe_b64encode(signature).rstrip(b"=")).decode()

    with TestClient(app) as client:
        response = client.post("/v1/auth/apple", json={"identityToken": forged})
    assert response.status_code == 401


def test_unknown_kid_does_not_reach_apple(table, apple):
    from conftest import AppleSigner

    stranger = AppleSigner(kid="unknown-kid")
    with TestClient(app) as client:
        response = client.post("/v1/auth/apple", json={"identityToken": stranger.token(USER_A)})
    assert response.status_code == 401


# ------------------------------------------------------------------ invites


def test_first_time_sub_without_a_code_gets_an_ordinary_account(table, apple):
    """Sign-up is open — the App Store price is the gate. A code is optional."""
    with TestClient(app) as client:
        response = sign_in(client, apple)
    assert response.status_code == 200, response.text
    assert response.json()["demo"] is False
    assert table.items[("INSTALL#" + stash_auth.user_id_for(USER_A), "USER")]


def test_a_wrong_code_is_still_refused(table, apple):
    """Silently ignoring a bad code would hand App Review an empty library after they
    typed the demo code correctly-but-not-quite. Only a supplied-and-wrong code 403s."""
    with TestClient(app) as client:
        assert sign_in(client, apple, code="STASH-NOPE-NOPE").status_code == 403
    assert ("INSTALL#" + stash_auth.user_id_for(USER_A), "USER") not in table.items


def test_single_use_invite_cannot_be_redeemed_twice(table, apple):
    code = invite(table, uses=1)
    with TestClient(app) as client:
        assert sign_in(client, apple, USER_A, code).status_code == 200
        assert sign_in(client, apple, USER_B, code).status_code == 403
    assert int(table.items[(f"INVITE#{code}", "META")]["usedCount"]) == 1


def test_expired_and_spent_invites_are_indistinguishable_from_invalid(table, apple):
    expired = invite(table, "STASH-OLDY-CODE", expires_in=-1)
    with TestClient(app) as client:
        response = sign_in(client, apple, USER_A, expired)
    assert response.status_code == 403
    assert response.json()["detail"] == "that code was not accepted"


def test_returning_sub_needs_no_invite(table, apple):
    code = invite(table)
    with TestClient(app) as client:
        first = sign_in(client, apple, USER_A, code)
        second = sign_in(client, apple, USER_A)  # no invite this time
    assert first.status_code == 200 and second.status_code == 200
    assert first.json()["userID"] == second.json()["userID"]
    assert int(table.items[(f"INVITE#{code}", "META")]["usedCount"]) == 1


def test_a_racing_first_sign_in_still_gets_a_session(table, apple, monkeypatch):
    """The account row appearing between the existence check and the create means a
    concurrent sign-in, or the client retrying after a response it never saw. Both are the
    same Apple sub, so both must end in a session — this used to 500, which made a
    double-tapped Sign in with Apple look like an outage."""
    code = invite(table, uses=2)
    real_get_user = stash_auth._get_user

    def racing_get_user(target, user_id):
        # Report "no account", then do exactly what the request that wins the race does:
        # spend a use of the code and write the row, so the create below loses its condition.
        if not planted:
            planted.append(user_id)
            stash_auth.redeem_invite(target, code)
            target.put_item(Item={"PK": f"INSTALL#{user_id}", "SK": "USER",
                                  "userID": user_id, "createdAt": int(time.time())})
            return None
        return real_get_user(target, user_id)

    planted: list[str] = []
    monkeypatch.setattr(stash_auth, "_get_user", racing_get_user)
    with TestClient(app) as client:
        response = sign_in(client, apple, USER_A, code)

    assert response.status_code == 200, response.text
    assert response.json()["userID"] == stash_auth.user_id_for(USER_A)
    # The loser hands its use back, so the code is charged once for the one account made.
    assert int(table.items[(f"INVITE#{code}", "META")]["usedCount"]) == 1


def test_a_failed_account_create_still_surfaces(table, apple, monkeypatch):
    """Only 'it already exists' is recoverable; a real write failure must not be swallowed
    into a session for an account that was never stored."""
    code = invite(table)
    monkeypatch.setattr(stash_auth, "_create_user",
                        lambda *_args: (_ for _ in ()).throw(RuntimeError("dynamo down")))
    with TestClient(app) as client, pytest.raises(RuntimeError):
        sign_in(client, apple, USER_A, code)
    assert int(table.items[(f"INVITE#{code}", "META")]["usedCount"]) == 0


# ------------------------------------------------------------------ the demo library flag


def test_a_demo_invite_marks_the_account_in_every_response(table, apple, monkeypatch):
    """App Review redeems this code and the app seeds its sample library off the flag, so it
    has to outlive a token rotation and be readable by a reinstall that only calls /v1/me."""
    monkeypatch.setattr(manage_invites, "shared_table", lambda: table)
    minted = manage_invites.mint(table, uses=2, expiry_days=120, label="app review", demo=True)

    with TestClient(app) as client:
        signed_in = sign_in(client, apple, USER_A, minted["code"])
        assert signed_in.status_code == 200, signed_in.text
        rotated = client.post("/v1/auth/refresh",
                              json={"refreshToken": signed_in.json()["refreshToken"]})
        me = client.get("/v1/me", headers=auth(rotated.json()["token"]))

    assert signed_in.json()["demo"] is True
    assert rotated.json()["demo"] is True
    assert me.json()["demo"] is True


def test_an_ordinary_invite_leaves_the_demo_flag_off(table, apple):
    with TestClient(app) as client:
        body = session(client, apple, table)
        me = client.get("/v1/me", headers=auth(body["token"]))
    assert body["demo"] is False
    assert me.json()["demo"] is False


def test_apple_sub_is_never_persisted(table, apple):
    with TestClient(app) as client:
        body = session(client, apple, table)
    assert USER_A not in body["userID"]
    assert USER_A not in repr(table.items)


# ------------------------------------------------------------------ sessions


def test_sign_in_returns_a_usable_session_and_quota(table, apple):
    with TestClient(app) as client:
        body = session(client, apple, table)
        me = client.get("/v1/me", headers=auth(body["token"]))
    assert body["quota"] == {"initialRemaining": 500, "monthRemaining": 100,
                             "monthResetAt": body["quota"]["monthResetAt"],
                             "initialLimit": 500, "monthLimit": 100}
    assert body["expiresAt"] > int(time.time())
    assert me.status_code == 200 and me.json()["userID"] == body["userID"]


def test_refresh_rotation_invalidates_the_old_token(table, apple):
    with TestClient(app) as client:
        body = session(client, apple, table)
        rotated = client.post("/v1/auth/refresh", json={"refreshToken": body["refreshToken"]})
        replayed = client.post("/v1/auth/refresh", json={"refreshToken": body["refreshToken"]})
        again = client.post("/v1/auth/refresh", json={"refreshToken": rotated.json()["refreshToken"]})

    assert rotated.status_code == 200
    assert rotated.json()["refreshToken"] != body["refreshToken"]
    assert "userID" not in rotated.json()
    assert replayed.status_code == 401
    assert again.status_code == 200


def test_refresh_tokens_are_only_stored_hashed(table, apple):
    with TestClient(app) as client:
        body = session(client, apple, table)
    assert body["refreshToken"] not in repr(table.items)
    assert (f"RT#{stash_auth._hash(body['refreshToken'])}", "META") in table.items


def test_expired_refresh_token_is_refused(table, apple):
    with TestClient(app) as client:
        body = session(client, apple, table)
        digest = stash_auth._hash(body["refreshToken"])
        table.items[(f"RT#{digest}", "META")]["expiresAt"] = int(time.time()) - 1
        response = client.post("/v1/auth/refresh", json={"refreshToken": body["refreshToken"]})
    assert response.status_code == 401


PROTECTED = [
    ("GET", "/v1/me", None),
    ("DELETE", "/v1/me", None),
    ("GET", "/v1/me/export", None),
    ("POST", "/v1/imports", payload()),
    ("GET", "/v1/imports/abc", None),
    ("GET", "/v1/imports/abc/results", None),
    ("POST", "/v1/videos/transcript", {"url": "https://www.tiktok.com/@x/video/123"}),
    ("POST", "/v1/chat/completions", {"messages": []}),
    ("GET", "/v1/tiktok/download/1234567890", None),
]


@pytest.mark.parametrize("method,path,body", PROTECTED)
def test_every_route_rejects_a_request_without_a_token(table, method, path, body):
    with TestClient(app) as client:
        response = client.request(method, path, json=body)
    assert response.status_code == 401


@pytest.mark.parametrize("method,path,body", PROTECTED)
def test_every_route_rejects_a_junk_token(table, method, path, body):
    with TestClient(app) as client:
        response = client.request(method, path, json=body, headers=auth("not.a.jwt"))
    assert response.status_code == 401


def test_session_dies_with_the_account(table, apple):
    """A 30-day JWT must stop working the moment the account row is gone."""
    with TestClient(app) as client:
        body = session(client, apple, table)
        assert client.get("/v1/me", headers=auth(body["token"])).status_code == 200
        client.delete("/v1/me", headers=auth(body["token"]))
        assert client.get("/v1/me", headers=auth(body["token"])).status_code == 401


# ------------------------------------------------------------------ isolation


def test_user_a_cannot_read_user_b_import(table, apple):
    with TestClient(app) as client:
        a = session(client, apple, table, USER_A)
        b = session(client, apple, table, USER_B)
        created = client.post("/v1/imports", headers=auth(a["token"]), json=payload())
        import_id = created.json()["importID"]

        assert client.get(f"/v1/imports/{import_id}", headers=auth(a["token"])).status_code == 200
        assert client.get(f"/v1/imports/{import_id}", headers=auth(b["token"])).status_code == 404
        assert client.get(f"/v1/imports/{import_id}/results",
                          headers=auth(b["token"])).status_code == 404


def test_same_client_import_id_yields_different_import_ids_per_user(table, apple):
    with TestClient(app) as client:
        a = session(client, apple, table, USER_A)
        b = session(client, apple, table, USER_B)
        first = client.post("/v1/imports", headers=auth(a["token"]), json=payload())
        second = client.post("/v1/imports", headers=auth(b["token"]), json=payload())
    assert first.json()["importID"] != second.json()["importID"]


# ------------------------------------------------------------------ account lifecycle


def test_delete_me_erases_everything_including_refresh_tokens(table, apple):
    with TestClient(app) as client:
        body = session(client, apple, table)
        client.post("/v1/imports", headers=auth(body["token"]), json=payload())
        user_id = body["userID"]
        assert any(key[0] == f"INSTALL#{user_id}" for key in table.items)

        response = client.delete("/v1/me", headers=auth(body["token"]))
        assert response.status_code == 204
        assert not any(key[0] == f"INSTALL#{user_id}" for key in table.items)
        assert not any(str(key[0]).startswith("RT#") for key in table.items)
        assert client.post("/v1/auth/refresh",
                           json={"refreshToken": body["refreshToken"]}).status_code == 401


def test_an_authorization_code_is_exchanged_and_revoked_on_delete(table, apple, monkeypatch):
    """The whole revocation path hangs off the one-time code the client sends at sign-in.
    Without it there is no Apple refresh token to revoke, deletion silently skips, and Stash
    stays listed under Settings → Apple ID — which is what guideline 5.1.1(v) is about."""
    calls = []

    def apple_post(url, data=None, timeout=None, **_kwargs):
        calls.append((url, dict(data or {})))
        return SimpleNamespace(status_code=200, json=lambda: {"refresh_token": "apple-rt"})

    monkeypatch.setattr(stash_auth, "_apple_client_secret", lambda: "client-secret")
    monkeypatch.setattr(stash_auth.requests, "post", apple_post)

    with TestClient(app) as client:
        body = client.post("/v1/auth/apple", json={
            "identityToken": apple.token(USER_A),
            "inviteCode": invite(table),
            "authorizationCode": "apple-one-time-code"}).json()
        assert table.items[(f"INSTALL#{body['userID']}", "USER")]["appleRefreshToken"] == "apple-rt"
        assert client.delete("/v1/me", headers=auth(body["token"])).status_code == 204

    assert [url for url, _ in calls] == [stash_auth.APPLE_TOKEN_URL, stash_auth.APPLE_REVOKE_URL]
    assert calls[0][1]["code"] == "apple-one-time-code"
    assert calls[1][1]["token"] == "apple-rt"


def test_missing_apple_credentials_are_loud_at_sign_in_and_at_deletion(table, apple, caplog):
    """A box without the Apple trio still signs users in and still deletes them — that is
    deliberate — but every such account keeps its Sign in with Apple grant forever. The only
    thing standing between that and a 5.1.1(v) rejection is these two log lines, so they are
    asserted: deploy.sh now refuses the deploy, and this covers a box emptied afterwards."""
    for name in ("APPLE_TEAM_ID", "APPLE_KEY_ID", "APPLE_PRIVATE_KEY"):
        assert not stash_secrets.secret(name), f"{name} leaked into the test environment"

    with caplog.at_level("WARNING", logger="stash-webhook"), TestClient(app) as client:
        body = client.post("/v1/auth/apple", json={
            "identityToken": apple.token(USER_A),
            "inviteCode": invite(table),
            "authorizationCode": "apple-one-time-code"}).json()
        assert "appleRefreshToken" not in table.items[(f"INSTALL#{body['userID']}", "USER")]
        assert client.delete("/v1/me", headers=auth(body["token"])).status_code == 204

    warnings = [record.message for record in caplog.records if record.levelname == "WARNING"]
    assert any("apple code exchange skipped" in message for message in warnings), warnings
    assert any("apple revoke skipped" in message for message in warnings), warnings


def test_export_returns_the_users_items_without_credentials(table, apple):
    with TestClient(app) as client:
        body = session(client, apple, table)
        client.post("/v1/imports", headers=auth(body["token"]), json=payload())
        table.items[(f"INSTALL#{body['userID']}", "USER")]["appleRefreshToken"] = "apple-secret"
        response = client.get("/v1/me/export", headers=auth(body["token"]))

    assert response.status_code == 200
    exported = response.json()
    assert exported["userID"] == body["userID"]
    sort_keys = [item["SK"] for item in exported["items"]]
    assert "USER" in sort_keys and "QUOTA" in sort_keys
    assert any(key.endswith("#VIDEO#1") for key in sort_keys)
    assert not any(key.startswith("RT#") for key in sort_keys)
    assert "apple-secret" not in response.text


# ------------------------------------------------------------------ the invite CLI


def test_minted_codes_are_redeemable_and_revocable(table, apple, monkeypatch):
    monkeypatch.setattr(manage_invites, "shared_table", lambda: table)
    minted = manage_invites.mint(table, uses=2, expiry_days=30, label="beta wave 1")

    with TestClient(app) as client:
        assert sign_in(client, apple, USER_A, minted["code"]).status_code == 200
        assert manage_invites.main(["revoke", minted["code"].lower()]) == 0
        # One use was left, but revocation expires the code regardless.
        assert sign_in(client, apple, USER_B, minted["code"]).status_code == 403


def test_listing_reports_usage_and_ignores_non_invite_rows(table, apple, monkeypatch):
    monkeypatch.setattr(manage_invites, "shared_table", lambda: table)
    spent = manage_invites.mint(table, uses=1, expiry_days=30, label="")
    open_code = manage_invites.mint(table, uses=5, expiry_days=30, label="")
    table.put_item(Item={"PK": "INSTALL#someone", "SK": "META"})  # must not be listed
    with TestClient(app) as client:
        sign_in(client, apple, USER_A, spent["code"])

    listed = {item["code"]: int(item["usedCount"]) for item in manage_invites.list_invites(table)}
    assert listed == {spent["code"]: 1, open_code["code"]: 0}


def test_the_reviewer_mint_command_from_the_checklist_yields_a_demo_account(
        table, apple, monkeypatch, capsys):
    """The literal command in docs/app-store-submission.md §6, through argparse. Drop `--demo`
    from it and App Review's account comes back `"demo": false`, the app seeds nothing, and the
    reviewer lands in the empty library that whole section exists to prevent."""
    monkeypatch.setattr(manage_invites, "shared_table", lambda: table)
    assert manage_invites.main(
        ["mint", "--uses", "50", "--expires-days", "120", "--label", "app review", "--demo"]) == 0
    code = capsys.readouterr().out.split()[0]

    with TestClient(app) as client:
        body = sign_in(client, apple, USER_A, code).json()
        assert body["demo"] is True
        assert client.get("/v1/me", headers=auth(body["token"])).json()["demo"] is True


def test_revoking_an_unknown_code_reports_failure(table, monkeypatch):
    monkeypatch.setattr(manage_invites, "shared_table", lambda: table)
    assert manage_invites.main(["revoke", "STASH-NOPE-NOPE"]) == 1


def test_export_only_covers_the_calling_user(table, apple):
    with TestClient(app) as client:
        a = session(client, apple, table, USER_A)
        b = session(client, apple, table, USER_B)
        client.post("/v1/imports", headers=auth(b["token"]), json=payload())
        exported = client.get("/v1/me/export", headers=auth(a["token"])).json()
    assert all(item["PK"] == f"INSTALL#{a['userID']}" for item in exported["items"])


# ---------------------------------------------------------------- the paywall
#
# 1.1 is free to download, so these are the tests that stand where the €5 price used to.
# Every one of them asserts about money leaving the building.


def test_a_new_account_cannot_spend_anything(table, apple):
    """The whole point: signing in is free, spending is not."""
    with TestClient(app) as client:
        body = session(client, apple, table, USER_A, entitled=False)
        assert body["entitled"] is False
        refused = client.post("/v1/imports", headers=auth(body["token"]), json=payload())
    assert refused.status_code == 402
    # Distinct from an exhausted quota: the client shows a paywall for one and a counter
    # for the other, and it tells them apart by this string.
    assert refused.json()["detail"] == "subscription required"


def test_a_subscription_opens_the_metered_routes(table, apple):
    with TestClient(app) as client:
        body = session(client, apple, table, USER_A, entitled=False)
        grant(table, USER_A, subscriptionExpiresAt=int(time.time()) + 3600)
        accepted = client.post("/v1/imports", headers=auth(body["token"]), json=payload())
        assert client.get("/v1/me", headers=auth(body["token"])).json()["entitled"] is True
    assert accepted.status_code == 202


def test_a_lapsed_subscription_closes_them_again(table, apple):
    with TestClient(app) as client:
        body = session(client, apple, table, USER_A, entitled=False)
        grant(table, USER_A, subscriptionExpiresAt=int(time.time()) - 1)
        refused = client.post("/v1/imports", headers=auth(body["token"]), json=payload())
        assert client.get("/v1/me", headers=auth(body["token"])).json()["entitled"] is False
    assert refused.status_code == 402


def test_a_lapsed_subscriber_can_still_collect_work_already_paid_for(table, apple):
    """Submitting costs money; reading the results of a finished import does not. Taking
    the library hostage the moment a card expires would be both rude and a refund magnet."""
    with TestClient(app) as client:
        body = session(client, apple, table, USER_A)
        import_id = client.post("/v1/imports", headers=auth(body["token"]),
                                json=payload()).json()["importID"]
        grant(table, USER_A, lifetime=False, subscriptionExpiresAt=0)
        status = client.get(f"/v1/imports/{import_id}", headers=auth(body["token"]))
        results = client.get(f"/v1/imports/{import_id}/results", headers=auth(body["token"]))
        blocked = client.post("/v1/imports", headers=auth(body["token"]),
                              json=payload(client_import_id="22222222-2222-4222-8222-222222222222"))
    assert status.status_code == 200
    assert results.status_code == 200
    assert blocked.status_code == 402


def test_a_demo_account_never_meets_the_paywall(table, apple):
    """App Review redeems a --demo code. A reviewer who lands on a checkout they cannot
    complete is a 2.1 rejection, so demo accounts are entitled by definition."""
    with TestClient(app) as client:
        body = sign_in(client, apple, USER_A, invite(table, "STASH-DEMO-CODE", demo=True)).json()
        assert body["demo"] is True and body["entitled"] is True
        accepted = client.post("/v1/imports", headers=auth(body["token"]), json=payload())
    assert accepted.status_code == 202


def test_a_paid_1_0_owner_keeps_the_app_they_bought(table, apple):
    """`lifetime` is what grandfathering writes. It outranks any subscription state."""
    with TestClient(app) as client:
        body = session(client, apple, table, USER_A, entitled=False)
        grant(table, USER_A, lifetime=True, subscriptionExpiresAt=0)
        accepted = client.post("/v1/imports", headers=auth(body["token"]), json=payload())
    assert accepted.status_code == 202


def test_an_unverifiable_receipt_is_refused_and_grants_nothing(table, apple):
    """The blob is not a claim, it is evidence. Garbage in gets a 400, not an entitlement."""
    with TestClient(app) as client:
        body = session(client, apple, table, USER_A, entitled=False)
        posted = client.post("/v1/me/subscription", headers=auth(body["token"]),
                             json={"signedTransaction": "not.a.jws"})
        assert client.get("/v1/me", headers=auth(body["token"])).json()["entitled"] is False
    assert posted.status_code == 400


def test_the_entitlement_predicate_holds():
    import stash_subscription
    assert stash_subscription.selftest()


def test_an_account_from_the_paid_era_is_entitled_without_a_receipt(table, apple, monkeypatch):
    """Build 24 has no StoreKit in it, so a €5 buyer cannot prove anything. The cutoff is what
    stops the paywall locking them — and everyone who grabs build 24 while it is briefly free —
    out of an app that would 402 on every tap."""
    with TestClient(app) as client:
        body = session(client, apple, table, USER_A, entitled=False)
        monkeypatch.setattr(stash_subscription, "PAID_ERA_ENDS", int(time.time()) + 3600)
        accepted = client.post("/v1/imports", headers=auth(body["token"]), json=payload())
        assert client.get("/v1/me", headers=auth(body["token"])).json()["entitled"] is True
    assert accepted.status_code == 202


def test_the_paid_era_closes(table, apple, monkeypatch):
    """After the window, a fresh account is just a fresh account."""
    with TestClient(app) as client:
        body = session(client, apple, table, USER_A, entitled=False)
        monkeypatch.setattr(stash_subscription, "PAID_ERA_ENDS", 1)
        refused = client.post("/v1/imports", headers=auth(body["token"]), json=payload())
    assert refused.status_code == 402
    assert refused.json()["detail"] == "subscription required"
