"""The TikTok sync: Add -> Check -> Download, at most once a day, Favorite Videos only.

TikTok is never reached. `requests.post` is replaced by a recorder that answers each Data
Portability URL (and the refresh grant) from a queue the test sets, with real `requests.Response`
objects so streaming and `.json()` behave as they do in production. Fixture archives are built
in tmp_path in both layouts TikTok has used for favourites.
"""

import io
import json
import os
import tempfile
import threading
import time
import zipfile
from types import SimpleNamespace

import pytest
import requests
from fastapi.testclient import TestClient

import stash_auth
import stash_secrets
import tiktok_connect
import tiktok_sync
from app import app
from conftest import ConditionalTable

USER = "user-a"
ROW_KEY = ("INSTALL#user-a", "TIKTOK")
PORTABILITY = "user.info.basic,portability.activity.single,portability.activity.ongoing"
REQUEST_ID = 7_400_000_000_000_000_123
DAY = tiktok_sync.SYNC_INTERVAL

FAVORITES = [{"Date": "2026-10-01 12:00:00",
              "Link": "https://www.tiktokv.com/share/video/7400000000000000001/"},
             {"date": "2026-09-30 08:15:00",
              "link": "https://www.tiktokv.com/share/video/7400000000000000002/"}]
EXPECTED = [{"date": "2026-10-01 12:00:00",
             "link": "https://www.tiktokv.com/share/video/7400000000000000001/"},
            {"date": "2026-09-30 08:15:00",
             "link": "https://www.tiktokv.com/share/video/7400000000000000002/"}]
# Same {Date, Link} shape as a favourite, under keys that must never match.
OTHER = {"Date": "2026-10-02 09:00:00", "Link": "https://www.tiktokv.com/share/video/9999/"}
ACTIVITY_LAYOUT = {"Activity": {
    "Favorite Videos": {"FavoriteVideoList": FAVORITES},
    "Watch History": {"VideoList": [OTHER]},
    "Search History": {"SearchList": [{"Date": "2026-10-02 09:00:00", "SearchTerm": "secret"}]},
}}
LIKES_LAYOUT = {"Likes and Favorites": {
    "Favorite Videos": {"FavoriteVideoList": FAVORITES},
    "Like List": {"ItemFavoriteList": [OTHER]},
    "Favorite Sounds": {"FavoriteSoundList": [OTHER]},
}}


def reply(status=200, body=None, raw=None):
    """A real requests.Response: JSON `body`, or `raw` bytes such as an archive."""
    response = requests.Response()
    response.status_code = status
    response.raw = io.BytesIO(raw if raw is not None else json.dumps(body or {}).encode())
    return response


def ok(**data):
    return reply(body={"data": data, "error": {"code": "ok", "message": ""}})


def refused(status, code):
    return reply(status, {"error": {"code": code, "message": "", "log_id": "x"}})


def archive(tmp_path, layout, name="user_data_tiktok.json") -> bytes:
    path = tmp_path / "fixture.zip"
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as zipped:
        zipped.writestr(name, json.dumps(layout))
        zipped.writestr("readme.txt", "not json, never read")
    return path.read_bytes()


@pytest.fixture
def table(monkeypatch):
    fake = ConditionalTable()
    monkeypatch.setenv("STASH_JWT_SECRET", "test-signing-secret-at-least-32-bytes-long")
    monkeypatch.setenv("TIKTOK_CLIENT_KEY", "ck-test")
    monkeypatch.setenv("TIKTOK_CLIENT_SECRET", "cs-test")
    stash_secrets.reset_cache()
    for module in (stash_auth, tiktok_connect, tiktok_sync):
        monkeypatch.setattr(module, "shared_table", lambda: fake)
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
    """Stand in for TikTok. `replies[url]` is a list consumed in order, each a Response or an
    exception to raise; `calls` records (url, json-or-form, headers)."""
    state = SimpleNamespace(replies={}, calls=[])

    def post(url, data=None, json=None, headers=None, timeout=None, stream=False, **_):
        state.calls.append((url, json if json is not None else data, headers))
        response = state.replies[url].pop(0)
        if isinstance(response, Exception):
            raise response
        return response

    monkeypatch.setattr(tiktok_sync.requests, "post", post)
    return state


@pytest.fixture
def archives(tmp_path, monkeypatch):
    """Every temp file the sync creates lands here, so a test can prove none survived."""
    directory = tmp_path / "archives"
    directory.mkdir()
    monkeypatch.setattr(tempfile, "tempdir", str(directory))
    return directory


def seed_row(table, **fields):
    now = int(time.time())
    table.put_item(Item={**stash_auth._tiktok_key(USER), "openID": "oid-1", "displayName": "Ana",
                         "scope": PORTABILITY, "accessToken": "at-1",
                         "accessExpiresAt": now + 86_400, "refreshToken": "rt-1",
                         "refreshExpiresAt": now + 31_536_000, "connectedAt": now, **fields})


def sync(client, headers):
    return client.post("/v1/tiktok/sync", headers=headers)


def urls(tiktok):
    return [call[0] for call in tiktok.calls]


def ready(tiktok, raw):
    tiktok.replies[tiktok_sync.TIKTOK_DATA_CHECK_URL] = [ok(request_id=REQUEST_ID, status="downloading")]
    tiktok.replies[tiktok_sync.TIKTOK_DATA_DOWNLOAD_URL] = [reply(raw=raw)]


# ------------------------------------------------------------------ 1. nothing to sync


def test_no_connection_is_not_connected_and_calls_nobody(client, headers, tiktok):
    response = sync(client, headers)

    assert response.status_code == 200
    assert response.json() == {"state": "not_connected"}
    assert tiktok.calls == []


def test_a_sandbox_connection_is_not_enabled_and_calls_nobody(client, headers, table, tiktok):
    seed_row(table, scope="user.info.basic", accessExpiresAt=0)  # not even a refresh

    assert sync(client, headers).json() == {"state": "not_enabled"}
    assert tiktok.calls == []
    assert ROW_KEY in table.items


def test_sync_refuses_a_caller_with_no_bearer_token(client, table, tiktok):
    seed_row(table)

    assert client.post("/v1/tiktok/sync").status_code == 401
    assert tiktok.calls == []


# ------------------------------------------------------------------ 2-4. the daily request


def test_the_first_sync_sends_add_for_activity_and_stores_the_request(client, headers, table,
                                                                       tiktok):
    seed_row(table)
    tiktok.replies[tiktok_sync.TIKTOK_DATA_ADD_URL] = [ok(request_id=REQUEST_ID)]
    before = int(time.time())

    response = sync(client, headers)

    assert response.json() == {"state": "requested"}
    assert tiktok.calls == [(
        "https://open.tiktokapis.com/v2/user/data/add/?fields=request_id",
        {"data_format": "json", "category_selection_list": ["activity"]},
        {"Authorization": "Bearer at-1", "Content-Type": "application/json"},
    )]
    row = table.items[ROW_KEY]
    assert row["syncRequestID"] == REQUEST_ID
    assert before <= row["syncRequestedAt"] <= int(time.time())


def test_a_second_sync_inside_the_day_is_idle_and_calls_nobody(client, headers, table, tiktok):
    requested_at = int(time.time()) - 3600
    seed_row(table, syncRequestID=0, syncRequestedAt=requested_at)

    assert sync(client, headers).json() == {"state": "idle", "nextSyncAt": requested_at + DAY}
    assert tiktok.calls == []


def test_two_concurrent_first_syncs_send_exactly_one_add(table, tiktok, monkeypatch):
    seed_row(table)
    tiktok.replies[tiktok_sync.TIKTOK_DATA_ADD_URL] = [ok(request_id=REQUEST_ID)]
    # Both calls read the row before either claims, the window a real race opens.
    both_read = threading.Barrier(2, timeout=5)
    read = table.get_item

    def get_item(*, Key, **kwargs):
        item = read(Key=Key, **kwargs)
        if Key["SK"] == "TIKTOK":
            both_read.wait()
        return item

    # Dynamo applies a conditional write atomically; across threads the fake needs a lock to.
    atomic = threading.Lock()
    update = table.update_item

    def update_item(**kwargs):
        with atomic:
            return update(**kwargs)

    monkeypatch.setattr(table, "get_item", get_item)
    monkeypatch.setattr(table, "update_item", update_item)
    states = []

    def run():
        states.append(tiktok_sync.sync(user_id=USER)["state"])

    threads = [threading.Thread(target=run) for _ in range(2)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(10)

    assert sorted(states) == ["pending", "requested"]
    assert urls(tiktok) == [tiktok_sync.TIKTOK_DATA_ADD_URL]
    assert table.items[ROW_KEY]["syncRequestID"] == REQUEST_ID


# ------------------------------------------------------------------ 5-9. check and download


def test_a_pending_request_is_checked_and_stays_pending(client, headers, table, tiktok):
    seed_row(table, syncRequestID=REQUEST_ID, syncRequestedAt=int(time.time()) - 600)
    tiktok.replies[tiktok_sync.TIKTOK_DATA_CHECK_URL] = [ok(request_id=REQUEST_ID, status="pending")]

    assert sync(client, headers).json() == {"state": "pending"}
    assert tiktok.calls == [(
        "https://open.tiktokapis.com/v2/user/data/check/?fields=request_id,status",
        {"request_id": REQUEST_ID},
        {"Authorization": "Bearer at-1", "Content-Type": "application/json"},
    )]
    assert table.items[ROW_KEY]["syncRequestID"] == REQUEST_ID


@pytest.mark.parametrize("layout", [ACTIVITY_LAYOUT, LIKES_LAYOUT], ids=["activity", "likes"])
def test_a_ready_archive_returns_only_the_favourites(client, headers, table, tiktok, tmp_path,
                                                     archives, layout):
    requested_at = int(time.time()) - 7200
    seed_row(table, syncRequestID=REQUEST_ID, syncRequestedAt=requested_at)
    ready(tiktok, archive(tmp_path, layout))

    response = sync(client, headers)

    assert response.json() == {"state": "ready", "favorites": EXPECTED}
    # Watch history, searches, likes and favourite sounds share the shape and never leak.
    assert "9999" not in response.text and "secret" not in response.text
    assert urls(tiktok) == [tiktok_sync.TIKTOK_DATA_CHECK_URL, tiktok_sync.TIKTOK_DATA_DOWNLOAD_URL]
    assert tiktok.calls[1][1] == {"request_id": REQUEST_ID}
    row = table.items[ROW_KEY]
    assert row["syncRequestID"] == 0
    assert row["lastSyncCount"] == 2
    assert abs(row["lastSyncAt"] - time.time()) < 5
    assert row["syncRequestedAt"] == requested_at  # the day's slot still counts from the Add
    assert os.listdir(archives) == []
    # The next call inside the day asks TikTok for nothing.
    assert sync(client, headers).json() == {"state": "idle", "nextSyncAt": requested_at + DAY}
    assert len(tiktok.calls) == 2


def test_the_temp_archive_is_deleted_when_the_extractor_raises(client, headers, table, tiktok,
                                                               tmp_path, archives, monkeypatch):
    seed_row(table, syncRequestID=REQUEST_ID, syncRequestedAt=int(time.time()) - 600)
    ready(tiktok, archive(tmp_path, ACTIVITY_LAYOUT))
    seen = []

    def explode(path):
        seen.append(os.path.exists(path))
        raise RuntimeError("extractor bug")

    monkeypatch.setattr(tiktok_sync, "extract_favorites", explode)

    with pytest.raises(RuntimeError):
        sync(client, headers)

    assert seen == [True]
    assert os.listdir(archives) == []
    assert table.items[ROW_KEY]["syncRequestID"] == REQUEST_ID  # retried on the next call


@pytest.mark.parametrize("problem", ["over the cap", "not a zip", "broken json"])
def test_an_unusable_archive_is_deleted_and_the_request_let_go(client, headers, table, tiktok,
                                                               tmp_path, archives, monkeypatch,
                                                               problem):
    requested_at = int(time.time()) - 600
    seed_row(table, syncRequestID=REQUEST_ID, syncRequestedAt=requested_at)
    raw = archive(tmp_path, ACTIVITY_LAYOUT)
    if problem == "over the cap":
        monkeypatch.setattr(tiktok_sync, "MAX_ARCHIVE_BYTES", len(raw) - 1)
    elif problem == "not a zip":
        raw = b'{"error": {"code": "ok"}}'
    else:
        path = tmp_path / "broken.zip"
        with zipfile.ZipFile(path, "w") as zipped:
            zipped.writestr("user_data_tiktok.json", '{"Activity": {"Favorite Videos": ')
        raw = path.read_bytes()
    ready(tiktok, raw)

    assert sync(client, headers).json() == {"state": "idle", "nextSyncAt": requested_at + DAY}
    assert os.listdir(archives) == []
    row = table.items[ROW_KEY]
    assert row["syncRequestID"] == 0
    assert "lastSyncAt" not in row


# ------------------------------------------------------------------ 10. expired


@pytest.mark.parametrize("status", ["expired", "cancelled"])
def test_an_expired_request_is_let_go_and_a_new_add_sent_once_the_day_has_passed(
        client, headers, table, tiktok, status):
    seed_row(table, syncRequestID=REQUEST_ID, syncRequestedAt=int(time.time()) - 5 * DAY)
    tiktok.replies[tiktok_sync.TIKTOK_DATA_CHECK_URL] = [ok(request_id=REQUEST_ID, status=status)]
    tiktok.replies[tiktok_sync.TIKTOK_DATA_ADD_URL] = [ok(request_id=REQUEST_ID + 1)]

    assert sync(client, headers).json() == {"state": "requested"}
    assert urls(tiktok) == [tiktok_sync.TIKTOK_DATA_CHECK_URL, tiktok_sync.TIKTOK_DATA_ADD_URL]
    row = table.items[ROW_KEY]
    assert row["syncRequestID"] == REQUEST_ID + 1
    assert abs(row["syncRequestedAt"] - time.time()) < 5


def test_an_expired_request_inside_the_day_is_let_go_without_a_new_add(client, headers, table,
                                                                       tiktok):
    requested_at = int(time.time()) - 3600
    seed_row(table, syncRequestID=REQUEST_ID, syncRequestedAt=requested_at)
    tiktok.replies[tiktok_sync.TIKTOK_DATA_CHECK_URL] = [ok(request_id=REQUEST_ID, status="expired")]

    assert sync(client, headers).json() == {"state": "idle", "nextSyncAt": requested_at + DAY}
    assert urls(tiktok) == [tiktok_sync.TIKTOK_DATA_CHECK_URL]
    assert table.items[ROW_KEY]["syncRequestID"] == 0


# ------------------------------------------------------------------ 11. token refresh


def test_an_expiring_token_is_refreshed_and_the_rotated_tokens_persisted(client, headers, table,
                                                                         tiktok):
    seed_row(table, accessExpiresAt=int(time.time()) + 30)
    tiktok.replies[tiktok_connect.TIKTOK_TOKEN_URL] = [reply(body={
        "access_token": "at-2", "expires_in": 86_400, "refresh_token": "rt-2",
        "refresh_expires_in": 31_536_000, "open_id": "oid-1", "scope": PORTABILITY})]
    tiktok.replies[tiktok_sync.TIKTOK_DATA_ADD_URL] = [ok(request_id=REQUEST_ID)]

    assert sync(client, headers).json() == {"state": "requested"}

    assert tiktok.calls[0][:2] == (tiktok_connect.TIKTOK_TOKEN_URL, {
        "client_key": "ck-test", "client_secret": "cs-test",
        "grant_type": "refresh_token", "refresh_token": "rt-1"})
    assert tiktok.calls[1][2]["Authorization"] == "Bearer at-2"
    row = table.items[ROW_KEY]
    now = time.time()
    assert (row["accessToken"], row["refreshToken"]) == ("at-2", "rt-2")
    assert abs(row["accessExpiresAt"] - (now + 86_400)) < 5
    assert abs(row["refreshExpiresAt"] - (now + 31_536_000)) < 5
    assert row["displayName"] == "Ana" and row["syncRequestID"] == REQUEST_ID


@pytest.mark.parametrize("failure", [reply(503, {}), requests.ConnectionError("down")])
def test_a_refresh_tiktok_could_not_answer_is_502_and_keeps_the_row(client, headers, table,
                                                                    tiktok, failure):
    seed_row(table, accessExpiresAt=int(time.time()) + 30)
    tiktok.replies[tiktok_connect.TIKTOK_TOKEN_URL] = [failure]

    response = sync(client, headers)

    assert response.status_code == 502
    assert response.json() == {"detail": "couldn't reach TikTok"}
    assert table.items[ROW_KEY]["accessToken"] == "at-1"


# ------------------------------------------------------------------ 12. revoked in TikTok


@pytest.mark.parametrize("where", ["add", "check", "refresh"])
def test_a_revoked_grant_deletes_the_row_and_is_not_connected(client, headers, table, tiktok,
                                                              where):
    if where == "add":
        seed_row(table)
        tiktok.replies[tiktok_sync.TIKTOK_DATA_ADD_URL] = [refused(401, "access_token_invalid")]
    elif where == "check":
        seed_row(table, syncRequestID=REQUEST_ID, syncRequestedAt=int(time.time()) - 600)
        tiktok.replies[tiktok_sync.TIKTOK_DATA_CHECK_URL] = [refused(401, "access_token_invalid")]
    else:
        seed_row(table, accessExpiresAt=int(time.time()) - 10)
        tiktok.replies[tiktok_connect.TIKTOK_TOKEN_URL] = [reply(body={"error": "invalid_grant"})]

    assert sync(client, headers).json() == {"state": "not_connected"}
    assert ROW_KEY not in table.items
    assert client.get("/v1/me", headers=headers).json()["tiktok"] is None


def test_an_unticked_scope_is_not_enabled_and_keeps_the_row(client, headers, table, tiktok):
    seed_row(table)
    tiktok.replies[tiktok_sync.TIKTOK_DATA_ADD_URL] = [refused(401, "scope_not_authorized")]

    assert sync(client, headers).json() == {"state": "not_enabled"}
    row = table.items[ROW_KEY]
    assert row["accessToken"] == "at-1"
    assert "syncRequestID" not in row and row["syncRequestedAt"] == 0  # claim handed back


# ------------------------------------------------------------------ 13. TikTok failing


@pytest.mark.parametrize("failure, status, detail", [
    (reply(500, {}), 502, "couldn't reach TikTok"),
    (requests.ConnectionError("down"), 502, "couldn't reach TikTok"),
    (refused(429, "rate_limit_exceeded"), 503, "TikTok is busy, try later"),
])
def test_a_failed_add_hands_the_claim_back(client, headers, table, tiktok, failure, status,
                                           detail):
    requested_at = int(time.time()) - 2 * DAY
    seed_row(table, syncRequestID=0, syncRequestedAt=requested_at)
    tiktok.replies[tiktok_sync.TIKTOK_DATA_ADD_URL] = [failure, ok(request_id=REQUEST_ID)]

    response = sync(client, headers)

    assert response.status_code == status
    assert response.json() == {"detail": detail}
    row = table.items[ROW_KEY]
    assert (row["syncRequestID"], row["syncRequestedAt"]) == (0, requested_at)
    # Released, so the very next call tries again instead of idling for a day.
    assert sync(client, headers).json() == {"state": "requested"}
    assert table.items[ROW_KEY]["syncRequestID"] == REQUEST_ID


# ------------------------------------------------------------------ 14. /v1/me and the export


def test_me_shows_the_last_sync_and_the_export_still_has_no_tokens(client, headers, table, tiktok,
                                                                    tmp_path, archives):
    seed_row(table, syncRequestID=REQUEST_ID, syncRequestedAt=int(time.time()) - 600)
    assert set(client.get("/v1/me", headers=headers).json()["tiktok"]) == {"displayName",
                                                                            "connectedAt"}
    ready(tiktok, archive(tmp_path, LIKES_LAYOUT))
    assert sync(client, headers).json()["state"] == "ready"

    me = client.get("/v1/me", headers=headers).json()["tiktok"]
    assert me["lastSyncCount"] == 2
    assert me["lastSyncAt"] == table.items[ROW_KEY]["lastSyncAt"]
    assert set(me) == {"displayName", "connectedAt", "lastSyncAt", "lastSyncCount"}

    export = client.get("/v1/me/export", headers=headers)
    row = next(item for item in export.json()["items"] if item.get("SK") == "TIKTOK")
    assert row["lastSyncCount"] == 2
    assert "accessToken" not in row and "refreshToken" not in row
    assert "at-1" not in export.text and "rt-1" not in export.text
