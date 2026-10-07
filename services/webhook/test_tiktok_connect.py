"""The TikTok connection: connect, disconnect, and revoke on account deletion.

TikTok is never reached. `requests.post` and `requests.get` are replaced inside tiktok_connect
by a recorder, so every test can say exactly what was sent, to which URL, and in what order.
"""

import time
from types import SimpleNamespace

import pytest
import requests
from fastapi.testclient import TestClient

import stash_auth
import stash_secrets
import tiktok_connect
from app import app
from conftest import ConditionalTable

USER = "user-a"
CODE = "auth-code-1"
VERIFIER = "v" * 64
ROW_KEY = ("INSTALL#user-a", "TIKTOK")

TOKEN = {"access_token": "at-1", "expires_in": 86_400, "open_id": "oid-1",
         "refresh_token": "rt-1", "refresh_expires_in": 31_536_000,
         "scope": "user.info.basic", "token_type": "Bearer"}
INFO = {"data": {"user": {"open_id": "oid-1", "display_name": "Ana"}}, "error": {"code": "ok"}}


def reply(status=200, body=None):
    return SimpleNamespace(status_code=status, json=lambda: {} if body is None else body)


@pytest.fixture
def table(monkeypatch):
    fake = ConditionalTable()
    monkeypatch.setenv("STASH_JWT_SECRET", "test-signing-secret-at-least-32-bytes-long")
    monkeypatch.setenv("TIKTOK_CLIENT_KEY", "ck-test")
    monkeypatch.setenv("TIKTOK_CLIENT_SECRET", "cs-test")
    stash_secrets.reset_cache()
    monkeypatch.setattr(stash_auth, "shared_table", lambda: fake)
    monkeypatch.setattr(tiktok_connect, "shared_table", lambda: fake)
    fake.put_item(Item={**stash_auth._user_key(USER), "userID": USER, "createdAt": 1, "demo": False})
    yield fake
    stash_secrets.reset_cache()


@pytest.fixture
def headers(table):
    return {"Authorization": f"Bearer {stash_auth.mint_stash_jwt(USER)[0]}"}


@pytest.fixture
def client(table):
    return TestClient(app)


@pytest.fixture
def tiktok(monkeypatch):
    """Stand in for TikTok. Set `exchange`, `info`, `refresh` or `revoke` to a reply() or an
    exception to raise; `calls` records (method, url, form-or-query, headers) in order."""
    state = SimpleNamespace(exchange=reply(body=TOKEN), info=reply(body=INFO),
                            refresh=reply(body={"access_token": "at-2"}), revoke=reply(body={}),
                            calls=[])

    def respond(response):
        if isinstance(response, Exception):
            raise response
        return response

    def post(url, data=None, timeout=None, **_):
        state.calls.append(("POST", url, data, None))
        if url == tiktok_connect.TIKTOK_REVOKE_URL:
            return respond(state.revoke)
        return respond(state.exchange if data["grant_type"] == "authorization_code" else state.refresh)

    def get(url, params=None, headers=None, timeout=None, **_):
        state.calls.append(("GET", url, params, headers))
        return respond(state.info)

    monkeypatch.setattr(tiktok_connect.requests, "post", post)
    monkeypatch.setattr(tiktok_connect.requests, "get", get)
    return state


def connect(client, headers, code=CODE, verifier=VERIFIER):
    return client.post("/v1/tiktok/connect", json={"code": code, "codeVerifier": verifier},
                       headers=headers)


def seed_row(table, **fields):
    now = int(time.time())
    table.put_item(Item={**stash_auth._tiktok_key(USER), "openID": "oid-1", "displayName": "Ana",
                         "scope": "user.info.basic", "accessToken": "at-1",
                         "accessExpiresAt": now + 86_400, "refreshToken": "rt-1",
                         "refreshExpiresAt": now + 31_536_000, "connectedAt": now, **fields})


def revokes(tiktok):
    return [call for call in tiktok.calls if call[1] == tiktok_connect.TIKTOK_REVOKE_URL]


# ------------------------------------------------------------------ connect


def test_connect_stores_the_row_and_me_then_returns_the_display_name(client, headers, table, tiktok):
    assert client.get("/v1/me", headers=headers).json()["tiktok"] is None

    response = connect(client, headers)

    assert response.status_code == 200, response.text
    body = response.json()
    assert body["displayName"] == "Ana"
    row = table.items[ROW_KEY]
    assert (row["openID"], row["displayName"], row["scope"]) == ("oid-1", "Ana", "user.info.basic")
    assert (row["accessToken"], row["refreshToken"]) == ("at-1", "rt-1")
    assert row["connectedAt"] == body["connectedAt"]
    assert row["accessExpiresAt"] == row["connectedAt"] + 86_400
    assert row["refreshExpiresAt"] == row["connectedAt"] + 31_536_000
    # The user info call carried the new access token and asked for the two fields we keep.
    method, url, params, call_headers = tiktok.calls[1]
    assert (method, url, params) == ("GET", tiktok_connect.TIKTOK_USER_INFO_URL,
                                     {"fields": "open_id,display_name"})
    assert call_headers == {"Authorization": "Bearer at-1"}

    assert client.get("/v1/me", headers=headers).json()["tiktok"] == {
        "displayName": "Ana", "connectedAt": body["connectedAt"]}


def test_the_token_exchange_sends_the_verifier_and_the_exact_redirect_uri(client, headers, tiktok):
    connect(client, headers)

    method, url, data, _ = tiktok.calls[0]
    assert (method, url) == ("POST", "https://open.tiktokapis.com/v2/oauth/token/")
    assert data == {"client_key": "ck-test", "client_secret": "cs-test", "code": CODE,
                    "grant_type": "authorization_code", "code_verifier": VERIFIER,
                    "redirect_uri": "https://stash.dmitrijs.dev/tiktok/callback"}
    assert tiktok_connect.TIKTOK_REDIRECT_URI == "https://stash.dmitrijs.dev/tiktok/callback"


@pytest.mark.parametrize("rejection", [reply(200, {"error": "invalid_grant"}),
                                       reply(400, {"error": "invalid_grant"}),
                                       reply(400)])
def test_a_rejected_code_is_400_and_writes_nothing(client, headers, table, tiktok, rejection):
    tiktok.exchange = rejection

    response = connect(client, headers)

    assert response.status_code == 400
    assert response.json() == {"detail": "TikTok didn't accept that sign-in"}
    assert ROW_KEY not in table.items
    assert len(tiktok.calls) == 1  # no user info call for a sign-in that never happened


@pytest.mark.parametrize("failure", [requests.ConnectionError("down"), reply(503, {})])
def test_tiktok_unreachable_is_502_and_writes_nothing(client, headers, table, tiktok, failure):
    tiktok.exchange = failure

    response = connect(client, headers)

    assert response.status_code == 502
    assert response.json() == {"detail": "couldn't reach TikTok"}
    assert ROW_KEY not in table.items


@pytest.mark.parametrize("missing", ["TIKTOK_CLIENT_KEY", "TIKTOK_CLIENT_SECRET"])
def test_missing_credentials_are_503_with_no_outbound_call(client, headers, table, tiktok,
                                                           monkeypatch, missing):
    monkeypatch.delenv(missing)

    response = connect(client, headers)

    assert response.status_code == 503
    assert response.json() == {"detail": "TikTok sign-in is not configured"}
    assert tiktok.calls == []
    assert ROW_KEY not in table.items


@pytest.mark.parametrize("failure", [requests.Timeout("slow"), reply(401, {"data": {}})])
def test_a_failed_user_info_call_still_connects_with_an_empty_name(client, headers, table, tiktok,
                                                                    failure):
    tiktok.info = failure

    response = connect(client, headers)

    assert response.status_code == 200
    assert response.json()["displayName"] == ""
    assert table.items[ROW_KEY]["displayName"] == ""
    assert table.items[ROW_KEY]["accessToken"] == "at-1"


@pytest.mark.parametrize("body", [{"code": "", "codeVerifier": VERIFIER},
                                  {"code": "c" * 1025, "codeVerifier": VERIFIER},
                                  {"code": CODE, "codeVerifier": "v" * 42},
                                  {"code": CODE, "codeVerifier": "v" * 129}])
def test_a_malformed_body_is_422_and_never_reaches_tiktok(client, headers, tiktok, body):
    assert client.post("/v1/tiktok/connect", json=body, headers=headers).status_code == 422
    assert tiktok.calls == []


# ------------------------------------------------------------------ disconnect


def test_disconnect_with_a_live_token_revokes_it_and_deletes_the_row(client, headers, table, tiktok):
    seed_row(table)

    response = client.delete("/v1/tiktok/connect", headers=headers)

    assert response.status_code == 204
    assert tiktok.calls == [("POST", tiktok_connect.TIKTOK_REVOKE_URL,
                             {"client_key": "ck-test", "client_secret": "cs-test", "token": "at-1"},
                             None)]
    assert ROW_KEY not in table.items
    assert client.get("/v1/me", headers=headers).json()["tiktok"] is None


@pytest.mark.parametrize("expires_in", [-10, 30])  # lapsed, and inside the 60 s margin
def test_disconnect_with_an_expiring_token_refreshes_then_revokes_the_new_one(
        client, headers, table, tiktok, expires_in):
    seed_row(table, accessExpiresAt=int(time.time()) + expires_in)

    assert client.delete("/v1/tiktok/connect", headers=headers).status_code == 204

    assert [call[:3] for call in tiktok.calls] == [
        ("POST", tiktok_connect.TIKTOK_TOKEN_URL,
         {"client_key": "ck-test", "client_secret": "cs-test",
          "grant_type": "refresh_token", "refresh_token": "rt-1"}),
        ("POST", tiktok_connect.TIKTOK_REVOKE_URL,
         {"client_key": "ck-test", "client_secret": "cs-test", "token": "at-2"}),
    ]
    assert ROW_KEY not in table.items


@pytest.mark.parametrize("failure", [reply(500, {}), requests.ConnectionError("down")])
def test_disconnect_when_revoke_fails_is_still_204_and_deletes_the_row(client, headers, table,
                                                                       tiktok, failure):
    seed_row(table)
    tiktok.revoke = failure

    assert client.delete("/v1/tiktok/connect", headers=headers).status_code == 204

    assert len(revokes(tiktok)) == 1
    assert ROW_KEY not in table.items


def test_disconnect_without_a_connection_is_204_and_calls_nobody(client, headers, tiktok):
    assert client.delete("/v1/tiktok/connect", headers=headers).status_code == 204
    assert tiktok.calls == []


# ------------------------------------------------------------------ account deletion, export


def test_deleting_the_account_revokes_tiktok_and_removes_the_row(client, headers, table, tiktok):
    assert connect(client, headers).status_code == 200

    assert client.delete("/v1/me", headers=headers).status_code == 204

    assert [call[2]["token"] for call in revokes(tiktok)] == ["at-1"]
    assert ROW_KEY not in table.items
    assert table.items == {}


def test_the_export_carries_the_connection_but_never_a_token(client, headers, tiktok):
    assert connect(client, headers).status_code == 200

    response = client.get("/v1/me/export", headers=headers)

    assert response.status_code == 200
    rows = [item for item in response.json()["items"] if item.get("SK") == "TIKTOK"]
    assert len(rows) == 1 and rows[0]["displayName"] == "Ana"
    assert "accessToken" not in rows[0] and "refreshToken" not in rows[0]
    assert "at-1" not in response.text and "rt-1" not in response.text


# ------------------------------------------------------------------ auth


def test_both_routes_refuse_a_caller_with_no_bearer_token(client, table, tiktok):
    body = {"code": CODE, "codeVerifier": VERIFIER}

    assert client.post("/v1/tiktok/connect", json=body).status_code == 401
    assert client.delete("/v1/tiktok/connect").status_code == 401
    assert tiktok.calls == []
    assert ROW_KEY not in table.items
