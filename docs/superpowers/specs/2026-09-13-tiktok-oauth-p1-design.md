# TikTok OAuth — P1: connect, disconnect, revoke

**Date:** 2026-09-13 · **Status:** approved in chat, awaiting spec review

## Why

TikTok gives two separate approvals. The Data Portability application was submitted on 2026-09-13.
The second approval, Login Kit app review, needs a demo video showing TikTok sign-in working inside
the iOS app, recorded against a sandbox. Today `ConnectFlowView` is only a UI prototype. P1 builds
real sign-in, and nothing more.

## Scope

The TikTok integration is split into three parts, and this spec covers only the first.

| Part | What | Testable before TikTok approval? |
|---|---|---|
| **P1 (this spec)** | Connect, disconnect, token storage, revoke on account deletion. Scope `user.info.basic`. | Yes, in the sandbox |
| P2 | Portability archive: request, download, keep only Favorite Videos, 24h refresh | No: sandbox mode does not offer the Data Portability API |
| P3 | EEA/UK storefront gate on the connect entry point | Yes |

**Not in P1:** portability scopes, archive handling, the webhook worker, the EEA/UK gate,
application-level token encryption, a `/health` flag, more than one TikTok account per Stash
account, or reusing the `ConnectFlowView` prototype (it stays DEBUG-only and untouched).

## Decisions

1. **Use the TikTok iOS SDK, not web Login Kit.** `TikTokOpenAuthSDK` 2.5.0 (SPM,
   `https://github.com/tiktok/tiktok-opensdk-ios`, up to next major). It opens the TikTok app when
   installed and its own in-app browser when not (added in 2.3.0). TikTok requires the redirect URI
   to be an https universal link, and requires PKCE.
2. **Show the connect row only in Debug and TestFlight builds** until P2 ships. It is detected with
   `AppTransaction.shared`: `.environment == .sandbox` covers TestFlight and Xcode builds, and
   `.production` hides it. Reason: in an App Store build, a connect button that imports nothing
   risks rejection under guideline 2.2. The demo video is recorded from a TestFlight build.
3. **Start with the sandbox app credentials.** The sandbox "Stash iOS" (id `7685062954852763656`)
   was created on 2026-09-13, cloned from production. Its client key goes into the build, and its
   key and secret go onto the box. Switching to production credentials is part of P2.

## Components

### C1 — iOS app

- `App/project.yml`
  - Add the SPM package and link `TikTokOpenAuthSDK` to the `Stash` target only (not the share
    extension, not `TikTokBrainKit`).
  - Entitlement `com.apple.developer.associated-domains: [applinks:stash.dmitrijs.dev]`.
  - `Info.plist`: `TikTokClientKey` = `$(TIKTOK_CLIENT_KEY)`, `CFBundleURLTypes` with
    `$(TIKTOK_CLIENT_KEY)` as the URL scheme, and `LSApplicationQueriesSchemes`
    `[tiktokopensdk, snssdk1180, snssdk1233]`. `TIKTOK_CLIENT_KEY` is a build setting in the same
    file. The client key is public by design; the secret never reaches the app.
- `App/Sources/TikTokBrainApp.swift`: add `.onOpenURL { TikTokURLHandler.handleOpenURL($0) }` on the
  `WindowGroup` content. In SwiftUI this receives both the client-key scheme (returning from the
  TikTok app) and the https universal link (returning from the in-app browser).
- `App/Sources/TikTokConnectSection.swift` (new): a Settings `Section("TikTok")` inserted into the
  Settings list in `ImportView.swift`, above Account. It has four states:
  - not connected → **Connect TikTok**
  - connecting → "Connecting…", button disabled
  - connected → "Connected as @name" plus **Disconnect**
  - failed → one footnote line with the server's `detail`, or "Couldn't reach TikTok"
  It holds the `TikTokAuthRequest` in `@State` for the length of the request (the SDK requires a
  strong reference). It sends `scopes: ["user.info.basic"]` and redirect URI
  `https://stash.dmitrijs.dev/tiktok/callback`. On `.noError` it posts `code` and
  `request.pkce.codeVerifier` to the server. On a user cancel it shows nothing.
- `TikTokBrainKit/Sources/TikTokBrainKit/TikTokConnect.swift` (new): `TikTokConnectClient` with
  `connect(code:codeVerifier:) -> TikTokConnection` and `disconnect()`. Both go through
  `StashHTTP.send`. `TikTokConnection { displayName: String, connectedAt: Int }`. The Kit does not
  import the TikTok SDK.
- `App/Sources/StashSession.swift`: `MeResponse` gains an optional `tiktok: TikTokConnection?`
  (decode-if-present, so an older server still decodes), exposed as `session.tiktok`.

### C2 — site

- `services/webhook/site/.well-known/apple-app-site-association` (new, no extension):
  `{"applinks":{"details":[{"appIDs":["S76KJ8Y6C3.dev.dmitryschab.Stash"],"components":[{"/":"/tiktok/callback*"}]}]}}`
- `services/webhook/site/tiktok/callback.html` (new): one short line, "Open Stash to finish
  connecting TikTok." This is what a browser shows if the universal link is not intercepted (for
  example before iOS has fetched the association file).
- `services/webhook/Caddyfile`: a `handle /.well-known/apple-app-site-association` block that
  serves the file with `Content-Type: application/json` and no redirect.
- Deploy note: `deploy.sh` copies neither `site/` nor the Caddyfile. Both are copied by hand, as
  documented in `docs/api-application/data-portability-application.md`.

### C3 — backend

New module `services/webhook/tiktok_connect.py`, mounted in `app.py` as `APIRouter(prefix="/v1")`.

- Constants: `TIKTOK_TOKEN_URL = https://open.tiktokapis.com/v2/oauth/token/`,
  `TIKTOK_REVOKE_URL = https://open.tiktokapis.com/v2/oauth/revoke/`,
  `TIKTOK_USER_INFO_URL = https://open.tiktokapis.com/v2/user/info/`,
  `TIKTOK_REDIRECT_URI = https://stash.dmitrijs.dev/tiktok/callback`, and a 15 s timeout (the same
  as the Apple calls).
- `POST /v1/tiktok/connect` (`current_user`, no entitlement check, because connecting spends nothing)
  - Body `{code: 1..1024 chars, codeVerifier: 43..128 chars}`.
  - Posts form-encoded `client_key, client_secret, code, grant_type=authorization_code,
    redirect_uri, code_verifier` to the token URL.
  - A response without `access_token` → **400** `"TikTok didn't accept that sign-in"`.
  - Transport error or 5xx → **502** `"couldn't reach TikTok"`.
  - `TIKTOK_CLIENT_KEY` or `TIKTOK_CLIENT_SECRET` missing → **503**
    `"TikTok sign-in is not configured"`, and no outbound call is made.
  - Then `GET user/info?fields=open_id,display_name` with the new token. If that call fails, the
    connection still succeeds and `displayName` is `""`.
  - Puts the D1 row, which replaces any earlier connection. Returns `{displayName, connectedAt}`.
- `DELETE /v1/tiktok/connect` → `revoke_tiktok(table, user_id)`, then delete the row → **204**.
  Idempotent: returns 204 with no row.
- `revoke_tiktok(table, user_id)` — never raises.
  - When the access token expires within 60 s and the refresh token is still valid, it first
    runs the refresh grant (`client_key, client_secret, grant_type=refresh_token, refresh_token`)
    to get a live access token.
  - Then it posts `client_key, client_secret, token` to the revoke URL.
  - Every failure is a `log.warning`.
- `stash_auth.py`
  - `delete_me` calls `revoke_tiktok` before `delete_user_items`, next to `revoke_apple_token`.
    This is how account deletion ends TikTok access, as the DP application promises.
  - `get_me` adds `"tiktok": {displayName, connectedAt} | null`.
  - `_export_items` removes `accessToken` and `refreshToken` from the `SK="TIKTOK"` row.

### C4 — secrets

- `TIKTOK_CLIENT_KEY` and `TIKTOK_CLIENT_SECRET` in the `stash-box/app` Secrets Manager blob, read
  through `stash_secrets.secret`.
- `set-tiktok-secret.sh` also sets `TIKTOK_CLIENT_KEY`, using the same merge-and-assert write, and
  the secret still comes in through `SECRET_FILE` so it never passes through a transcript.
- Known coupling: `app.py` verifies webhook signatures with the same `TIKTOK_CLIENT_SECRET`. While the
  box holds sandbox credentials, only sandbox webhooks verify. P1 uses no webhooks.

## Data

**D1 — one row per connection** in the existing imports table:

| Attribute | Value |
|---|---|
| `PK` / `SK` | `INSTALL#<userID>` / `TIKTOK` |
| `openID`, `displayName`, `scope` | from TikTok |
| `accessToken`, `accessExpiresAt` | 24 h token, unix seconds |
| `refreshToken`, `refreshExpiresAt` | 365-day token, unix seconds |
| `connectedAt` | unix seconds |

Keeping it in its own row, not as attributes on `SK=USER`, has three benefits:
- `DELETE /v1/me` already removes the whole partition.
- The fake table in `conftest.py` supports put and delete but only `SET` updates.
- P2 can add sync state to this row without touching the account record.

Tokens are protected by DynamoDB server-side encryption, the same as `appleRefreshToken` today.

**D2:** a Stash account links one TikTok account, and connecting again replaces the row. Two Stash
accounts linking the same TikTok `open_id` is allowed in P1. P2 decides whether that needs a guard.

## Testing

`services/webhook/test_tiktok_connect.py` (pytest; `requests.post` and `requests.get` in
`tiktok_connect` are monkeypatched, using the `table` fixture pattern from `test_stash_auth.py`):

1. Connect stores the D1 row, and `/v1/me` then returns `tiktok.displayName`.
2. The token exchange sends `code_verifier` and exactly `TIKTOK_REDIRECT_URI`.
3. A rejected code → 400, and no row is written.
4. TikTok unreachable → 502, and no row.
5. Missing client key or secret → 503, and no outbound call.
6. A failed user info call still connects, with `displayName == ""`.
7. Disconnect with a live access token → revoke is called and the row is deleted.
8. Disconnect with an expired access token → refresh, then revoke using the refreshed token.
9. Disconnect when revoke fails → still 204, and the row is deleted.
10. `DELETE /v1/me` revokes and removes the row.
11. The export contains no `accessToken` or `refreshToken`.
12. No bearer token → 401 on both routes.

App: `xcodegen` then `xcodebuild` build for the simulator. A real sign-in needs a device with the
target TikTok account, and is the owner's check.

## Setup outside the repo

1. **Sandbox "Stash iOS" portal config** (Claude does this in the browser, then clicks Apply
   changes): enable the iOS platform with bundle ID `dev.dmitryschab.Stash`, and add the iOS
   redirect URI `https://stash.dmitrijs.dev/tiktok/callback`.
2. **Owner:** add your own TikTok account under Sandbox settings → Target users. Only target accounts
   can authorize a sandbox app.
3. **Owner:** write the sandbox client secret to a file, then run
   `SECRET_FILE=<path> ./set-tiktok-secret.sh`. The client key is not secret and Claude can read it
   from the portal.
4. **Owner confirms the deploy** of the backend, the site files and the Caddyfile to the box.
5. Automatic signing must add Associated Domains to App ID `dev.dmitryschab.Stash`. If
   `xcodebuild -allowProvisioningUpdates` cannot, enable it by hand in the Apple developer portal.

## Before any production credentials (tracked for P2)

- `privacy.html` currently says "Stash cannot connect to your TikTok account". It must describe the
  connection, the stored tokens and display name, and revocation before the connect row reaches App
  Store users.
- Replace the old `stash-demo.mp4` and the Web platform config in the production app review with
  the new iOS recording.
