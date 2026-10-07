# TikTok Data Portability — P2: sync Favorite Videos

**Date:** 2026-10-07 · **Status:** approved in chat · **Builds on:** `2026-09-13-tiktok-oauth-p1-design.md`

## Why

The Data Portability application was approved on 2026-10-07 for `portability.activity.single` and
`portability.activity.ongoing`. P2 turns a connected TikTok account into automatic imports: the user
bookmarks a video in TikTok, and it appears in Stash within about a day, with no export.

**Known risk.** TikTok's Data Types page lists Favourite Videos under "Likes and Favourites" in the
full archive, not under Activity, and the owner's own exports put them at
`Likes and Favorites > Favorite Videos`. The approved Activity scope may return no favourites. P2 is
built to find favourites wherever they sit, so the first live request settles it. That request can
only run after Login Kit app review passes, because the sandbox has no Data Portability API.

## Commitments this must honour (from the approved application)

- Read only Favorite Videos from the archive; discard every other category in memory; delete the
  archive right after extraction.
- At most one data request per connected user per 24 h; diff against the library, create nothing twice.
- Ongoing access ends on disconnect, account deletion (P1 already revokes), or a TikTok-side revoke.
- EEA/UK only — that gate is P3, not this spec.

## Decisions

1. **App-driven polling, no webhook, no timer, no push.** The library lives in SwiftData on the
   phone, so new items only appear when the app runs. The app calls one sync endpoint on foreground
   and from the existing `dev.dmitryschab.Stash.refresh` background task. TikTok explicitly allows
   polling Check instead of the `portability.download.ready` webhook.
2. **The server extracts, the phone imports.** The server returns the raw favourites list; the phone
   feeds it into the existing cloud-import path, which already dedupes by video ID and spends the
   import budget exactly like a manual import.
3. **Request category `["activity"]`, format `json`.** The extractor searches every JSON member for
   the favourites list, so a later move to `all_data` changes one constant.
4. **Scopes follow the credentials.** The sandbox has no portability scopes, so the app keeps asking
   for `user.info.basic` only until a build setting switches to production credentials.

## Components

### C1 — backend: `services/webhook/tiktok_sync.py` (new), mounted in `app.py` under `/v1`

Constants: `TIKTOK_DATA_ADD_URL = https://open.tiktokapis.com/v2/user/data/add/?fields=request_id`,
`TIKTOK_DATA_CHECK_URL = https://open.tiktokapis.com/v2/user/data/check/?fields=request_id,status`,
`TIKTOK_DATA_DOWNLOAD_URL = https://open.tiktokapis.com/v2/user/data/download/`, `SYNC_INTERVAL = 86400`,
`MAX_ARCHIVE_BYTES = 512 MB`, `MAX_MEMBER_BYTES = 256 MB` (the Kit's cap), 15 s timeout for Add and
Check, 120 s for Download. All three are `POST` with `Authorization: Bearer <access token>` and a JSON
body; Check and Download take `{"request_id": <int>}`.

`POST /v1/tiktok/sync` (`current_user`, no entitlement check — the phone's import path charges):

1. No TIKTOK row → `{"state": "not_connected"}`. Row whose `scope` lacks
   `portability.activity.ongoing` (every sandbox connection) → `{"state": "not_enabled"}`, no outbound call.
2. **Live token.** If the access token expires within 60 s, run the refresh grant and **persist** the
   new access token, refresh token and both expiries on the row (TikTok may rotate the refresh
   token). Factor this out of P1's `revoke_tiktok` so both use one helper.
3. **Pending request** (`syncRequestID` on the row) → Check:
   - `pending` → `{"state": "pending"}`
   - `downloading` (ready) → Download, streamed to a `tempfile` with the size cap → extract → delete
     the file in a `finally` → clear `syncRequestID`, set `lastSyncAt` and `lastSyncCount` →
     `{"state": "ready", "favorites": [{"date": str, "link": str}, ...]}`
   - `expired` / `cancelled` → clear `syncRequestID`, continue to step 4.
4. **No pending request**, and `syncRequestedAt` is absent or ≥ `SYNC_INTERVAL` ago → claim the slot
   with a conditional update on `syncRequestedAt` (two phones calling at once must not both send Add),
   then Add `{"data_format": "json", "category_selection_list": ["activity"]}`, store `syncRequestID`
   → `{"state": "requested"}`. If Add fails, release the claim so the next call retries.
5. Otherwise → `{"state": "idle", "nextSyncAt": syncRequestedAt + SYNC_INTERVAL}`.

Errors:
- TikTok returns 401 `access_token_invalid`, or the refresh grant is rejected → the user revoked in
  TikTok: delete the TIKTOK row → `{"state": "not_connected"}`.
- `scope_not_authorized` → `{"state": "not_enabled"}`; the row stays (the user un-ticked the scope).
- Transport error or 5xx → **502** `"couldn't reach TikTok"`; the row is unchanged except a released claim.
- 429 → **503** `"TikTok is busy, try later"`.
- Archive over the cap or not a zip → clear `syncRequestID`, log a warning, `{"state": "idle", ...}`.

**Extractor** `extract_favorites(path) -> list[dict]`: open the zip, read each `.json` member under the
member cap, walk the tree for any key matching `favou?rite.*video` (case-insensitive), and keep objects
that have `Date`/`date` and `Link`/`link`. Same rule as `ExportParser.collectFavoriteItems`. Nothing
else from the archive is kept or logged.

`get_me` adds `lastSyncAt` and `lastSyncCount` to the `tiktok` object (null until the first sync).
`_export_items` keeps stripping tokens; the new fields are not secret.

### C2 — app

- `TikTokBrainKit/.../TikTokConnect.swift`: `TikTokConnectClient.sync() -> TikTokSyncResult`, an enum
  `notConnected | notEnabled | pending | requested | idle(nextSyncAt) | ready([Bookmark])`. Converting the server's
  `{date, link}` to `Bookmark` reuses `ExportParser`'s mapping (ID from the link, newest wins on
  duplicates); expose that mapping rather than copying it. Through `StashHTTP.send`.
- `App/Sources/PipelineCenter.swift`: one entry point `syncTikTok()`, called on foreground and from the
  existing background refresh, only when `session.tiktok != nil`. `ready` bookmarks go into the same
  ingest-then-submit path `runCloudImport` uses after parsing (split that function at the parse
  boundary instead of duplicating it). `notConnected` clears `session.tiktok`. Errors are silent
  (logged); the next foreground retries.
- `App/Sources/TikTokConnectSection.swift`: one footnote under the connected row — "Synced 3 h ago"
  from `lastSyncAt`, "Waiting for TikTok…" while pending or requested. Match the section's existing
  copy tone.
- `App/project.yml`: build setting `TIKTOK_SCOPES` (sandbox: `user.info.basic`), passed through
  Info.plist and read by the connect section instead of the hard-coded scope list.

### C3 — site: `services/webhook/site/privacy.html`

Replace "Stash cannot connect to your TikTok account…" with the truth, in the page's existing voice:
the optional connection, what is stored (TikTok user ID, display name, access and refresh tokens),
that Stash requests the data archive at most once a day, reads only Favourite Videos, deletes the
archive immediately, and that disconnecting or deleting the Stash account revokes access.

## Testing

`services/webhook/test_tiktok_sync.py` (pytest, `requests` monkeypatched, `ConditionalTable` for the claim):

1. Not connected → `not_connected`; sandbox-scoped row → `not_enabled`; neither makes an outbound call.
2. First sync → Add with category `activity`, row gets `syncRequestID` and `syncRequestedAt`, `requested`.
3. Second call within 24 h with no pending request → `idle` with `nextSyncAt`, no outbound call.
4. Two concurrent first syncs → exactly one Add.
5. Pending → Check `pending` → `pending`.
6. Ready → Download → favourites extracted from an **Activity** layout zip.
7. Same from a **Likes and Favorites** layout zip.
8. Every other category in the fixture zip is absent from the response.
9. The temp archive file no longer exists after success, after an extractor error, and over the cap.
10. Expired → claim cleared, a new Add is sent when 24 h have passed.
11. Access token near expiry → refresh grant, new tokens persisted on the row.
12. TikTok 401 `access_token_invalid` → row deleted, `not_connected`; `scope_not_authorized` → row kept, `not_enabled`.
13. Add 5xx → 502, claim released.
14. `/v1/me` shows `lastSyncAt` and `lastSyncCount`; the export still has no tokens.

Kit: a test that the server's `{date, link}` list maps to the same `Bookmark`s `ExportParser` produces
from an export. App: `xcodegen` + simulator build.

## Not in P2

The EEA/UK gate (P3), the webhook, APNs, a server timer, switching to production credentials (done
when Login Kit app review passes: set the production key and secret with `set-tiktok-secret.sh`, flip
`TIKTOK_SCOPES` to include `portability.activity.single,portability.activity.ongoing`), and asking
TikTok whether Activity contains favourites.
