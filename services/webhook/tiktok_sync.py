"""Stash /v1 TikTok sync — the user's Favorite Videos from the Data Portability archive.

  POST /v1/tiktok/sync -> {"state": ...}

The app calls this on foreground and from its background refresh: no webhook, no timer, no push.
Each call moves the connection one step along TikTok's Add -> Check -> Download, with at most one
data request per connection per 24 h. A ready archive is streamed to a temp file, its Favorite
Videos are pulled out and returned, and the file is deleted before the response leaves. Nothing
else in the archive is kept or logged, and no favourite is stored here: the phone feeds the list
into its own cloud import, which dedupes by video ID and charges the quota. Hence no entitlement
check. See docs/superpowers/specs/2026-10-07-tiktok-portability-p2-design.md.

States: not_connected · not_enabled (the grant lacks portability.activity.ongoing, as every
sandbox one does) · pending · requested · idle {nextSyncAt} · ready {favorites: [{date, link}]}.

Sync state rides on the TIKTOK row: syncRequestID (0 when none), syncRequestedAt, lastSyncAt and
lastSyncCount. The ID is cleared to 0 rather than REMOVEd: a TikTok request ID is never 0, and
every write stays a SET, the one update shape conftest's fake table applies.
"""
import json
import logging
import re
import tempfile
import time
import zipfile

import requests
from fastapi import APIRouter, Depends, HTTPException

import stash_secrets
from cloud_import_store import _is_conditional_failure, shared_table
from stash_auth import _tiktok_key, current_user
from tiktok_connect import TIKTOK_TIMEOUT, _json, live_access_token

log = logging.getLogger("stash-webhook")

router = APIRouter(prefix="/v1")

TIKTOK_DATA_ADD_URL = "https://open.tiktokapis.com/v2/user/data/add/?fields=request_id"
TIKTOK_DATA_CHECK_URL = "https://open.tiktokapis.com/v2/user/data/check/?fields=request_id,status"
TIKTOK_DATA_DOWNLOAD_URL = "https://open.tiktokapis.com/v2/user/data/download/"
DOWNLOAD_TIMEOUT = 120

ONGOING_SCOPE = "portability.activity.ongoing"
# The approved application promises at most one data request per connected user per day.
SYNC_INTERVAL = 86_400
# Only the activity category. The extractor searches every member, so all_data is a one-line move.
ADD_BODY = {"data_format": "json", "category_selection_list": ["activity"]}

MAX_ARCHIVE_BYTES = 512 << 20
MAX_MEMBER_BYTES = 256 << 20  # the Kit's ZipReader cap
FAVORITES_KEY = re.compile(r"favou?rite.*video", re.IGNORECASE)


class _Refused(Exception):
    """TikTok said no for a reason the app shows as a state: "not_connected" or "not_enabled"."""


@router.post("/tiktok/sync")
def sync(user_id: str = Depends(current_user)):
    table = shared_table()
    row = table.get_item(Key=_tiktok_key(user_id)).get("Item")
    if not row:
        return {"state": "not_connected"}
    if ONGOING_SCOPE not in [scope.strip() for scope in str(row.get("scope") or "").split(",")]:
        return {"state": "not_enabled"}
    client_key = stash_secrets.secret("TIKTOK_CLIENT_KEY")
    client_secret = stash_secrets.secret("TIKTOK_CLIENT_SECRET")
    if not (client_key and client_secret):
        # Checked before anything else: without them every refresh fails, and a failed refresh
        # reads as a revoke that would drop the user's connection.
        log.warning("tiktok sync refused: TIKTOK_CLIENT_KEY / TIKTOK_CLIENT_SECRET not configured")
        raise HTTPException(status_code=503, detail="TikTok sign-in is not configured")
    try:
        try:
            token = live_access_token(table, user_id, row, client_key, client_secret)
        except requests.RequestException as error:
            log.warning("tiktok refresh before sync failed: %s", error)
            raise HTTPException(status_code=502, detail="couldn't reach TikTok") from error
        if token is None:
            raise _Refused("not_connected")
        return _step(table, user_id, row, token)
    except _Refused as refusal:
        state = refusal.args[0]
        if state == "not_connected":
            # Revoked from TikTok's own settings, or the year-long refresh token ran out.
            log.info("tiktok access for %s is gone, connection removed", user_id)
            table.delete_item(Key=_tiktok_key(user_id))
        return {"state": state}


def _step(table, user_id: str, row: dict, token: str) -> dict:
    request_id = int(row.get("syncRequestID") or 0)
    if request_id:
        status = _data(TIKTOK_DATA_CHECK_URL, token, {"request_id": request_id}).get("status")
        if status not in ("downloading", "expired", "cancelled"):
            return {"state": "pending"}
        # "downloading" is TikTok's word for an archive that is ready to download.
        favorites = _download(token, request_id) if status == "downloading" else None
        done = {":none": 0, ":id": request_id}
        if favorites is not None:
            _update(table, user_id,
                    "SET syncRequestID = :none, lastSyncAt = :now, lastSyncCount = :count",
                    "syncRequestID = :id",
                    {**done, ":now": int(time.time()), ":count": len(favorites)})
            return {"state": "ready", "favorites": favorites}
        # Expired, cancelled, or an archive too big or broken to read: let it go.
        _update(table, user_id, "SET syncRequestID = :none", "syncRequestID = :id", done)

    requested_at = int(row.get("syncRequestedAt") or 0)
    now = int(time.time())
    if now - requested_at < SYNC_INTERVAL:
        return {"state": "idle", "nextSyncAt": requested_at + SYNC_INTERVAL}
    # Compare-and-set on the syncRequestedAt this call read: of two phones syncing at once,
    # exactly one takes the day's slot and sends Add.
    if "syncRequestedAt" in row:
        seen, values = "syncRequestedAt = :seen", {":now": now, ":seen": row["syncRequestedAt"]}
    else:
        seen, values = "attribute_not_exists(syncRequestedAt)", {":now": now}
    if not _update(table, user_id, "SET syncRequestedAt = :now",
                   f"attribute_exists(PK) AND {seen}", values):
        return {"state": "pending"}  # the other call is sending Add
    try:
        request_id = int(_data(TIKTOK_DATA_ADD_URL, token, ADD_BODY)["request_id"])
    except Exception:
        # Hand the slot back, so the next call retries instead of waiting out a day for nothing.
        _update(table, user_id, "SET syncRequestedAt = :previous", "syncRequestedAt = :mine",
                {":previous": requested_at, ":mine": now})
        raise
    _update(table, user_id, "SET syncRequestID = :id", "syncRequestedAt = :mine",
            {":id": request_id, ":mine": now})
    return {"state": "requested"}


def _update(table, user_id: str, expression: str, condition: str, values: dict) -> bool:
    """A conditional write to the TIKTOK row; False when the condition no longer held."""
    try:
        table.update_item(Key=_tiktok_key(user_id), UpdateExpression=expression,
                          ConditionExpression=condition, ExpressionAttributeValues=values)
    except Exception as error:
        if not _is_conditional_failure(error):
            raise
        return False
    return True


def _post(url: str, token: str, body: dict, *, timeout=TIKTOK_TIMEOUT, stream=False):
    """POST to a Data Portability endpoint. Returns the response when TikTok accepted the call
    and turns every refusal into the state or the status the app sees."""
    try:
        response = requests.post(
            url, json=body, timeout=timeout, stream=stream,
            headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        )
    except requests.RequestException as error:
        log.warning("tiktok %s failed: %s", url, error)
        raise HTTPException(status_code=502, detail="couldn't reach TikTok") from error
    if response.status_code == 200 and stream:
        return response  # the archive itself; a JSON error in its place fails as "not a zip"
    code = (_json(response).get("error") or {}).get("code")
    if response.status_code == 200 and code in (None, "ok"):
        return response
    if code == "access_token_invalid":
        raise _Refused("not_connected")
    if code == "scope_not_authorized":
        raise _Refused("not_enabled")
    log.warning("tiktok %s returned %s %s", url, response.status_code, code)
    if response.status_code == 429 or code == "rate_limit_exceeded":
        raise HTTPException(status_code=503, detail="TikTok is busy, try later")
    raise HTTPException(status_code=502, detail="couldn't reach TikTok")


def _data(url: str, token: str, body: dict) -> dict:
    return _json(_post(url, token, body)).get("data") or {}


def _download(token: str, request_id: int) -> list[dict] | None:
    """The favourites in a ready archive, or None when it is over the cap or unreadable. The
    archive goes to a temp file, never into memory, and the file is gone when this returns,
    however it returns.

    ponytail: synchronous, inside the app's request, so a big archive holds a worker thread for
    as long as it downloads. If the phone gives up first, this run still clears the request and
    that day's favourites never reach it; every archive carries the whole list, so the next
    day's does. A queue is the fix once real archives turn out big.
    """
    response = _post(TIKTOK_DATA_DOWNLOAD_URL, token, {"request_id": request_id},
                     timeout=DOWNLOAD_TIMEOUT, stream=True)
    with response, tempfile.NamedTemporaryFile(suffix=".zip") as archive:
        size = 0
        try:
            for chunk in response.iter_content(chunk_size=1 << 20):
                size += len(chunk)
                if size > MAX_ARCHIVE_BYTES:
                    log.warning("tiktok archive over %d bytes, dropped", MAX_ARCHIVE_BYTES)
                    return None
                archive.write(chunk)
        except requests.RequestException as error:
            log.warning("tiktok archive download failed: %s", error)
            raise HTTPException(status_code=502, detail="couldn't reach TikTok") from error
        archive.flush()
        try:
            return extract_favorites(archive.name)
        except (zipfile.BadZipFile, ValueError) as error:
            # The type only: a decode error's message can quote the archive's bytes.
            log.warning("tiktok archive unreadable: %s", type(error).__name__)
            return None


def extract_favorites(path) -> list[dict]:
    """Every Favourite Videos entry in a portability archive, as {"date", "link"}.

    Walks every JSON member for a key matching (?i)favou?rite.*video whose value is a list, and
    keeps the objects in it carrying Date/date and Link/link: ExportParser.collectFavoriteItems'
    rule, so favourites are found under Activity and under Likes and Favorites alike. A member
    over MAX_MEMBER_BYTES is skipped unread; zipfile stops at the size the header declares, so
    the header cannot lie its way past the cap.

    ponytail: json.load holds a whole member as Python objects, several times its size. The cap
    is the Kit's, and a real Activity file is a few MB.
    """
    favorites: list[dict] = []
    with zipfile.ZipFile(path) as archive:
        for member in archive.infolist():
            if not member.filename.lower().endswith(".json"):
                continue
            if member.file_size > MAX_MEMBER_BYTES:
                log.warning("tiktok archive member over %d bytes, skipped", MAX_MEMBER_BYTES)
                continue
            with archive.open(member) as handle:
                _collect(json.load(handle), favorites)
    return favorites


def _collect(node, favorites: list[dict]) -> None:
    if isinstance(node, dict):
        for key, value in node.items():
            if isinstance(value, list) and FAVORITES_KEY.search(key):
                for item in value:
                    if isinstance(item, dict):
                        date, link = _text(item, "Date"), _text(item, "Link")
                        if date is not None and link is not None:
                            favorites.append({"date": date, "link": link})
            _collect(value, favorites)
    elif isinstance(node, list):
        for element in node:
            _collect(element, favorites)


def _text(item: dict, key: str) -> str | None:
    """item[key], else item[key.lower()], whichever is a string first: ExportParser's lookup."""
    for name in (key, key.lower()):
        if isinstance(item.get(name), str):
            return item[name]
    return None
