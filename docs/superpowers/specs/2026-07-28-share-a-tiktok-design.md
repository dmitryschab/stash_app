# Share a TikTok into Stash

**Date:** 2026-07-28
**Status:** approved, not implemented

## The problem

Today the only way into the library is a whole TikTok data export: Library → Import → pick the
JSON, and the box processes 500 videos. There is no way to save *one* video, and the moment you
actually want to save one is the moment you are watching it.

The motivating case: a TikTok naming five jazz albums. The albums are spoken and burned into the
frames — they are not in the caption. Saving that video is worthless unless the transcript and
the on-screen text come with it.

## What ships

Tap Share in TikTok, pick **Stash**, the sheet dismisses. Next time the app is opened the video
is in the Library with caption, transcript, on-screen text and a summary written from all three.
Sharing several in a row queues all of them.

Nothing happens between the share and the next app launch. That is deliberate — see
"Why the extension does nothing" below.

## Architecture

```
TikTok share sheet
  └─ StashShare (new app-extension target)
       extract URL → write <group>/pending/<uuid>.txt → completeRequest
       no network, no credentials, no UI beyond the dismissal
             │
             ▼  (app group container)
     Stash app — PipelineCenter.appBecameActive
       1. drainSharedInbox()
            read + delete each pending file
            resolve vm.tiktok.com/ZM… → https://www.tiktok.com/@user/video/<id>
       2. runner.ingest([Bookmark])          → local Video row, bookmarkedAt = now
       3. client.submit(videos: [one])       → cloud fast pass
       4. backfillTranscripts(only: [id])    → audio → transcript → re-analyze
       5. backfillVisualText(only: [id])     → box download → Vision OCR → re-analyze
```

Steps 3–5 are existing, shipped code paths. **The backend needs no changes**:
`POST /v1/imports` already accepts a one-element `videos` list
(`services/webhook/cloud_import_api.py`), and steps 4–5 are the transcript and visual-text
backfills that Settings exposes today.

### Units and their boundaries

**`SharedInbox`** (`App/Sources/SharedInbox.swift`, compiled into both targets)
The only thing the two processes share. Three functions: `write(_ url: URL)`,
`drain() -> [URL]` (reads and deletes), `containerURL`. One file per shared link named by
UUID, so the extension writing and the app draining never touch the same file and no locking
is needed. A file that fails to parse is deleted, not retried forever.

**`ShareViewController`** (`App/ShareExtension/`)
A plain `UIViewController`, not `SLComposeServiceViewController` — there is nothing to compose.
`viewDidLoad` pulls the URL from `extensionContext`, calls `SharedInbox.write`, calls
`completeRequest`. Handles both `public.url` and `public.plain-text` attachments, because
TikTok's sheet sometimes hands over `"caption… https://vm.tiktok.com/ZM…"` as text. First
`https://…tiktok.com/…` substring wins.

**`PipelineCenter.drainSharedInbox()`** (`App/Sources/PipelineCenter.swift`)
Owns the whole app-side sequence. Called from `appBecameActive()` alongside
`syncCloudImportIfNeeded()`, guarded on `StashSession.shared.isSignedIn` like every other
entry point in that file.

**Short-link resolution** (private to `PipelineCenter`)
`URLSession` follows redirects by default; issue a `GET` with the desktop User-Agent that
`Enricher` already uses, read `response.url`, extract `/video/(\d+)`. Returns `nil` if no
numeric id can be found — the caller reports it rather than submitting a request the server
will reject.

**`PipelineRunner.backfillTranscripts` / `backfillVisualText`** — one new parameter
`only: Set<String>? = nil`, applied in the existing `targets` filter. Without it, a share
would trigger a full-library backfill and spend the entire month's budget on the first share.
Two lines per method; no behaviour change when `nil`.

### Tracking the extra import

`PipelineCenter` currently persists a single `CloudImportSyncState` under
`cloudImport.syncState` — one active import at a time. A shared video creates a second import
that must be polled without disturbing an in-flight library import.

Solution: a separate persisted `[String]` of share import ids. `syncCloudImport()` polls each
one after the main state, upserts results through the existing `CloudImportResultUpserter`, and
drops an id once its status reaches `completed` or `cancelled`. The upserter is already
idempotent and keyed by `videoID`, so nothing special is needed for overlap.

*ponytail: a flat array, not a second state machine. If share imports ever need progress UI of
their own, promote it to `[CloudImportSyncState]` then.*

### Target and entitlement setup

`App/project.yml` gains a `StashShare` target of type `app-extension`, bundle id
`dev.dmitryschab.Stash.Share`, same deployment target and team as the app, listed as a
dependency of `Stash` so it is embedded. Its `Info.plist` sets
`NSExtensionPointIdentifier: com.apple.share-services`, a principal class of
`$(PRODUCT_MODULE_NAME).ShareViewController`, and an activation rule accepting one web URL
**and** plain text (`NSExtensionActivationSupportsWebURLWithMaxCount: 1`,
`NSExtensionActivationSupportsText: true`).

Both targets carry `com.apple.security.application-groups: [group.dev.dmitryschab.Stash]`.
The group has to exist in the developer portal; automatic signing on the paid team registers
it on first build, but if it does not, it is a one-time manual add. `CURRENT_PROJECT_VERSION`
and `MARKETING_VERSION` must match between the two targets or App Store Connect rejects the
upload.

## Why the extension does nothing

The deep pass has to run in the main app regardless: `backfillVisualText` downloads the video
through the box and runs Vision OCR on twelve keyframes, which is well past what an extension's
memory budget survives. Given the app has to wake up anyway, having the extension also submit
the fast pass would buy one round trip in exchange for:

- sharing the session JWT and refresh token with a second process via a Keychain access group,
- reimplementing token refresh inside the extension,
- a second place credentials can leak from.

Not worth it. The extension writes a file and quits.

## Cost

Three quota units per shared video: one for the import, one for the transcript, one for the
download that feeds OCR. Against the 100-a-month allowance that is ~33 shares per month. The
Import screen's budget card already reads from the same counter, so it stays accurate without
new code; its copy gains a sentence naming the per-share cost.

An exhausted budget surfaces the same way it does everywhere else — `StashError.quotaExhausted`
carries the numbers and the reset date, and the drain stops. Pending files stay on disk, so the
shares are still there when the month turns over.

## Failure handling

| Failure | Behaviour |
|---|---|
| Short link will not resolve / no numeric id | File deleted, error on the Import screen naming the link |
| Video private, deleted or region-locked | Server returns `unavailable`; the row lands flagged, as with any import |
| Transcript throttled (Groq hourly cap) | Stage parks `awaitingBox`; the existing backfill picks it up on a later run |
| Signed out when the app opens | Drain skipped entirely; files stay pending until the next signed-in foreground |
| Budget exhausted | Drain stops, files stay pending, existing quota message shown |
| Malformed pending file | Deleted, logged, drain continues |

## Testing

- `SharedInbox` round trip: write → drain returns the URL → directory is empty. Real
  `FileManager`, temp directory injected.
- URL extraction from a `public.plain-text` payload with the URL mid-sentence, and from a bare
  `public.url`.
- Short-link resolver against a canonical URL, a short URL, and a non-TikTok URL (expects `nil`).
- `backfillTranscripts(only:)` and `backfillVisualText(only:)` touch only the named ids, against
  the existing in-memory container and fakes.
- Manual: share a TikTok URL from Safari in the simulator, confirm the file lands and the video
  appears with a transcript.

Existing `PipelineRunner` tests must keep passing unchanged — that is the check that `only: nil`
changed nothing.

## Explicitly out of scope

- Sharing anything that is not a TikTok video (Instagram, YouTube). One platform, one parser.
- Sharing several links at once from another app's multi-select.
- A UI for the pending queue. The videos appearing in the Library is the feedback.
- Notifying the user when a share finishes processing while the app is closed.
- Progress UI specific to share imports; the Import screen's existing status line covers it.
