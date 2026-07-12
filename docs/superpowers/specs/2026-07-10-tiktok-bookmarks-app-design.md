# TikTok Brain — Design Spec

**Date:** 2026-07-10
**Status:** Approved design, pre-implementation
**Working title:** TikTok Brain

## What & Why

A personal iOS app that turns TikTok bookmarks ("Favorites") into an organized, searchable knowledge base — automatically. The user's only action is bookmarking a video inside TikTok. The app ingests the user's TikTok data export, understands each saved video (metadata + audio transcription + on-screen text), classifies it, and routes it:

- **Recipe** → structured recipe (ingredients, steps) in a Recipe library
- **Music** → track entry (title, artist, artwork) with a universal open-in-any-service link
- **Coding/tech** → summary note with extracted links
- **Everything else** → auto-grouped by topic

All content is browsable as libraries and as an interactive **mind map**.

### Decisions already made

| Decision | Choice | Rationale |
|---|---|---|
| Audience (v1) | Personal tool for the owner | No wait on TikTok API approval; validates the pipeline with real data |
| Ingestion (v1) | Manual TikTok "Download your data" export zip, shared into the app | Only official way to get Favorites without Data Portability API approval |
| Platform | Native iOS (SwiftUI), iOS 17+ | Owner preference; OCR stays on-device (Vision), heavy ML moves to the box |
| Processing | On-device pipeline + self-hosted models on the owner's gaming PC over Tailscale (AtlasFlow pattern) | Hardware already runs these models; no cloud APIs; the tailnet is the auth boundary |
| Music target | In-app collection + song.link universal links | Spotify API is closed to small apps; universal links work with any service |
| Pipeline depth (v1) | Full: metadata + audio transcription + keyframe OCR | Owner choice — best extraction quality from day one |
| Phase 2 | TikTok Data Portability API (`portability.all.ongoing`) for automatic sync, EEA/UK users | Application is free; approval ~3–4 weeks; swaps the ingest stage only |

## Architecture

Single SwiftUI app. SwiftData for persistence. Heavy ML (transcription, classification/extraction) runs on the owner's gaming PC — the "**model box**" — reached over Tailscale, following the proven AtlasFlow pattern (`atlasflow/server/src/diffusiongemma/`): OpenAI-compatible HTTP API on the box, no auth (tailnet-only exposure), base URL and model ids configured in the app's Settings (never hardcoded), placeholder API key. The iPhone joins the tailnet via the Tailscale iOS app. A persisted, resumable **job queue** drives a per-video pipeline. Each stage is best-effort: a stage failure marks that stage failed and later stages run with whatever earlier stages produced (e.g., stream fetch fails → classify from caption alone).

```
TikTok export zip (share sheet / file importer)
  → ExportParser    zip → [(date, videoURL)]; diff vs. already-imported
  → Enricher        videoURL → caption, hashtags, author, thumbnail,
                    sound title/artist, stream URL   (public video page, embedded JSON)
  → MediaFetcher    stream URL → local audio file + ~6 keyframes (URLSession + AVFoundation)
  → Transcriber     audio → text, English only in v1
                    (Whisper on the box: /v1/audio/transcriptions, multipart upload)
  → FrameReader     keyframes → on-screen text (Vision OCR, on-device)
  → Analyzer        all of the above → {category, topics, title, summary}
                    + category payload (Recipe | Track | CodeNote)
                    (chat completions on the box, JSON-schema structured output)
  → Store           SwiftData; UI reacts
```

Music link resolution: track title + artist → iTunes Search API (free, keyless) → track URL → song.link (Odesli) universal URL.

**Model box prerequisites** (setup on the PC, not app code): an OpenAI-compatible chat endpoint (already running per AtlasFlow) and a Whisper-compatible `/v1/audio/transcriptions` endpoint (e.g., speaches/faster-whisper-server) — add the latter if not yet served.

### Components

Each unit has one purpose, a protocol interface, and is testable with fixtures:

1. **ExportParser** — unzip, locate the Favorite Videos section (match section names loosely — TikTok's export uses both "Favorite"/"Favourite" spellings and has changed folder layout before), emit bookmarks. Idempotent: re-importing a newer export processes only the diff.
2. **Enricher** — fetch public video page, parse embedded JSON state. Throttled (~1 req/s + jitter). The single most fragile parser; isolated so a TikTok page change is a one-file fix.
3. **MediaFetcher** — download audio track and sample keyframes. Temp files deleted after analysis; only thumbnails persist.
4. **Transcriber** — thin HTTP client for the box's Whisper endpoint (multipart audio upload); behind a protocol.
5. **FrameReader** — Vision `VNRecognizeTextRequest` over keyframes.
6. **Analyzer** — thin HTTP client for the box's OpenAI-compatible chat endpoint; structured JSON output decoded into Codable types; behind a protocol (fake in tests). Prompt includes caption + hashtags + transcript + OCR text. Mirrors AtlasFlow's `DiffusionGemmaClient`: base URL from Settings, placeholder API key, a distinct "box unreachable (is Tailscale up?)" error, ~30 s timeout with cold-load allowance.
7. **JobQueue** — SwiftData-persisted stage state per video; survives app restarts; concurrency limited; progress published to UI.
8. **MusicLinkResolver** — iTunes Search + song.link URL construction.

### Data model (SwiftData)

- `Video` — id (TikTok video id), url, bookmarkedAt, author, caption, hashtags, thumbnail, transcript?, ocrText?, category, title, summary, topics [Topic], pipeline stage states, availability flag
- `Recipe` — 1:1 with Video: name, servings?, ingredients [name, quantity?], steps [String]
- `Track` — 1:1 with Video: title, artist, artworkURL?, universalLink?
- `CodeNote` — 1:1 with Video: summary, links [URL], techTags
- `Topic` — name, videos (many:many); created/merged by Analyzer output

### UI (4 screens)

Visual language (mockups approved 2026-07-10): calm, native iOS feel — the counterpoint to TikTok's noise. Three tabs (Library / Mind map / Import); Video detail is a pushed screen. Category colors used consistently across library and mind map: coral = recipes, pink = music, teal = code, purple = auto topics. Each library segment ends with a "needs a look" pile for failed extractions. Import doubles as pipeline status/history, including model-box reachability.

1. **Import** — file importer for the zip; live progress (n of m, current stage); resumable; import history.
2. **Library** — tabs Recipes / Music / Code / Other. Recipe cards (ingredients + steps), track rows (artwork, title/artist, open-via-song.link button), code notes (summary + links), Other grouped by topic. Search across everything.
3. **Mind Map** — pan/zoom SwiftUI Canvas. Root (you) → category nodes → topic clusters → video thumbnail nodes. Tap video → detail.
4. **Video detail** — summary, structured payload, transcript, original TikTok link, per-video "re-run pipeline" action.

## Error handling

- **Video deleted/private/region-locked:** stub entry, `unavailable` flag, original link kept.
- **Stream extraction breaks (TikTok page change):** video degrades to metadata-only classification, flagged `partial`; a "re-run failed stages" action exists for after a parser fix ships.
- **Throttling/blocking:** fixed ~1 req/s + jitter on page fetches; a 2,000-bookmark import ≈ 30–40 min, in-app progress, resumes after kill/restart.
- **Model box offline / Tailscale down:** Transcribe and Analyze pause and retry with backoff; Enricher, MediaFetcher, and OCR keep running so work piles up in an `awaiting box` state and drains automatically once the box is reachable. The Import screen shows box status explicitly.
- **Analyzer/model unavailable long-term:** hashtag-heuristic fallback category (`#recipe`, sound-present → music, etc.), flagged for re-analysis.
- **Idempotency:** everything keyed by TikTok video id; re-import and re-run are safe.

## Testing

- Unit, with fixtures: sample export zip → ExportParser; saved real video-page HTML → Enricher; canned metadata+transcript+OCR → Analyzer fake → routing/goldens; MusicLinkResolver against recorded iTunes Search responses.
- One integration test: fixture-driven full pipeline run (network + model faked) → expected SwiftData state.
- Acceptance: owner's real export end-to-end on device.

## Out of scope (v1)

TikTok Login Kit / Data Portability API (phase 2), any Spotify integration, Apple Music playlist creation, Android/web, multi-user/accounts, iCloud sync, sharing/export, push notifications, non-English transcription (non-English videos are analyzed from caption/hashtags/OCR only and never blocked on transcript).

## Phase 2 (recorded, not designed)

Automatic sync via TikTok Data Portability API: submit application (free; requires use case, UX mockups, privacy/security review; EEA/UK users only), then replace manual zip import with `portability.all.ongoing` + webhook-triggered fetch. The pipeline from Enricher onward is unchanged. Requires a thin backend for the webhook receiver at that point.

## Known risks

1. **Enricher fragility** — TikTok page structure changes silently; mitigated by isolation, per-stage degradation, re-run action.
2. **Box dependency** — transcription and analysis need the gaming PC awake and on the tailnet; mitigated by the pause-and-resume queue and visible box status. Model quality is owner-controlled (whatever the 3090 serves); the Analyzer protocol keeps a cloud-LLM escape hatch trivial if ever wanted.
3. **Non-English bookmarks** — v1 transcribes English only; other-language videos rely on caption/hashtags/OCR, so their extraction quality is lower. Acceptable for v1 by owner decision.
