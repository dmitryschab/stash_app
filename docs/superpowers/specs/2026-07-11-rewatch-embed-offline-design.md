# Rewatch: embedded playback + per-video "Keep offline" — design

Date: 2026-07-11. Status: approved scope (user: embed only + small per-video keep-offline
button; no bulk download).

## Problem

Saves can't be rewatched inside Stash — the detail screen links out to TikTok. Users
want to rewatch in place, and optionally keep a video playable after TikTok deletes it
(9% of the user's 941 favorites are already gone).

Measured storage facts (12-video sample, duration-stratified, as-downloaded H.264
mostly 1080×1920): **4.8 MB/min average, ~5 MB/video, ~4.4 GB for the full 855-video
library** — why bulk download is opt-in per video, not default. (The earlier 1.8 GB
`media/` directory was uncompressed 16 kHz mono WAV audio for Whisper, not video.)

## Design

### Watch section (top of `VideoDetailView`)

Playback resolution order:
1. **Offline file exists** → native SwiftUI `VideoPlayer` (AVPlayer), 9:16 frame,
   small `OFFLINE` badge. Works with no network and after TikTok deletion.
2. **Else** → TikTok's official embed `https://www.tiktok.com/embed/v2/<videoID>` in a
   `WKWebView` (`allowsInlineMediaPlayback`). Needs network; unavailable videos show
   TikTok's own unavailable card. The existing "Open in TikTok" link stays.

No TikTok API approval involved; the embed uses only the public video ID.

### Keep offline (small button in the Watch section)

States: `arrow.down.circle` "Keep offline" → spinner "Saving…" → checkmark
"Offline · <size>". Tapping when kept **removes** the file (label flips back).

Download flow (all in-app, mirrors what production sync will do):
1. `URLSession` GET the video's TikTok page (`video.url`) with a Safari user agent.
2. `Enricher.parse(html:)` (existing Kit code) → fresh `streamURL` (`playAddr` —
   these are signed and expire, which is why the fetch happens at tap time).
3. Download the mp4 to `Application Support/OfflineVideos/<videoID>.mp4`.
4. Set `video.offlineVideoFilename = "<videoID>.mp4"`, save; player switches to local.

**Known risk:** TikTok may 403 direct `playAddr` downloads from a plain URLSession.
The simulator run is the test. If blocked: the button surfaces the error state and the
feature ships embed-only while we find a better source (e.g. production box download).

**OUTCOME (implemented 2026-07-11): the risk materialized in full — every pure in-app
path is blocked.** Verified empirically: (1) pages serve a blank `playAddr` to clients
without TikTok's JS handshake (cookies don't help); (2) the embed's `<video>` src is a
direct CDN mp4 but replaying it from URLSession 403s even with the webview's cookies
and exact UA; (3) CORS blocks even the embed page `fetch()`ing its own stream. The
shipped download path is therefore the **model box**: `GET
{boxBaseURL}/tiktok/download/<id>` → yt-dlp server-side → mp4 bytes. Demo shim:
`pipeline-lab/box-shim.py` (stdlib http.server, 127.0.0.1:8765); the simulator app is
pointed at it via the `-boxBaseURL http://127.0.0.1:8765/v1` launch arg. ATS: the app
now ships an Info.plist with `NSAllowsLocalNetworking` (project.yml `info:` block) so
plain-http box endpoints work. Verified end-to-end on the simulator: download (41 MB
test video), OFFLINE badge + AVPlayer local playback, persistence across relaunch
(bare launch, no `-seedFile`), removal toggle deletes the file and restores the embed.

### Data model

`Video.offlineVideoFilename: String?` (additive SwiftData migration). A **relative
filename** resolved against Application Support at read time — absolute container URLs
break across reinstalls. Removal deletes the file and nils the field.

### Files

- `TikTokBrainKit/Core/Entities.swift`: + `offlineVideoFilename`.
- New `App/Sources/WatchSection.swift`: `TikTokEmbedView` (WKWebView representable),
  `OfflineVideoStore` (dir + fileURL(for:) + download/remove), the section view with
  button states. Keeps `VideoDetailView` from growing past its job.
- `App/Sources/VideoDetailView.swift`: insert the section.

## Error handling

- Page fetch / parse / download failure → transient "Couldn't save" state, button
  returns to idle; embed unaffected.
- Offline file missing at read (manual deletion, migration) → treat as not kept;
  fall back to embed.
- No network + not kept → WKWebView shows its error page; "Open in TikTok" remains.

## Out of scope

Bulk/pipeline video download, settings/storage-management UI, per-category rules,
HEVC re-encode, production sync integration (spec note: production keeps the mp4
`MediaFetcher` already downloads instead of deleting it — zero extra bandwidth).

## Verification

- Build; relaunch seeded app; open a video → embed plays (screenshot).
- Tap Keep offline on one video → file appears under Application Support, size shown,
  player switches to AVPlayer with OFFLINE badge (screenshot); relaunch → still offline.
- Tap again → file removed, back to embed.
- Kit tests unaffected (model field additive; Enricher untouched).
