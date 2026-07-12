# Tester-ready release: cloud ML pipeline + manual import + data-download guide

Date: 2026-07-11. Status: approved (Groq chosen and empirically validated; OCR cut).

## Problem

TestFlight testers can't use the app: (1) the ML pipeline assumes a personal "model
box" over Tailscale; (2) the pipeline's media stage downloads TikTok streams
**on-device, which TikTok now blocks** (verified: blank `playAddr` without the JS
handshake, CDN 403s replayed URLs, CORS blocks in-page fetch); (3) TikTok exports
arrive as `.zip`, which the import picker (.json/folder only) can't read; (4) nothing
tells a tester how to get their export in the first place.

## Decisions

- **Backend home:** the existing AWS box (`stash.dmitrijs.dev`, FastAPI + Caddy +
  systemd, service `stash-webhook`) gains `/v1` API routes. No new infra.
- **Transcription: Groq** `whisper-large-v3-turbo`. Measured on the free tier:
  53 s Russian audio → <1 s wall, clean text. Budget 7200 audio-sec/rolling-hour +
  2000 req — a normal tester library clears in minutes; big libraries throttle
  gracefully (429 → app retry state). ~$0.67 per 15 h library if/when paid tier
  unlocks. Key lives in `/etc/stash-webhook/env` (`GROQ_API_KEY`), sourced locally
  from the gitignored `secrets` file.
- **Analysis: Bedrock Gemma 4 26B-A4B** via a thin proxy on the box (token via
  `aws_bedrock_token_generator`, scoped IAM user with `bedrock:InvokeModel` only).
  Server-side system prompt = `pipeline-lab/PROMPT.md` verbatim — testers get the
  analyzer behavior validated on the 855-video run.
- **OCR: cut for this release.** The 855-video run used zero OCR with ~0 defects;
  a frames endpoint would force a second server-side download per video. The Kit's
  Vision code stays dormant; the `ocr` stage is marked `.skipped`. Returns with
  preserve-and-rediscover keepsake frames.
- **Whisper language: auto-detect** (drop hardcoded `language=en`; libraries are
  RU/EN mixed). Server applies the mandatory repetition filter from PROMPT.md;
  <12 surviving words → transcript null.

## Backend API (box, all behind Caddy TLS + shared bearer token)

- `POST /v1/videos/transcript` `{url}` → yt-dlp bestaudio → 16 kHz wav → Groq →
  repetition filter → `{transcript: string|null, duration: number}`. 404-ish yt-dlp
  failures → `{transcript: null, unavailable: true}`. Groq 429 → 429 + Retry-After.
- `POST /v1/chat/completions` — OpenAI-shape proxy to Bedrock (model pinned
  server-side; client's `model` field ignored). Existing `AnalyzerClient` works
  with base-URL + key change only.
- `GET /v1/tiktok/download/{id}` → mp4 bytes (keep-offline; production home of
  `pipeline-lab/box-shim.py`).
- Auth: single shared bearer token for TestFlight (checked on all /v1 routes);
  per-tester keys are YAGNI until external testers. Webhook routes unchanged.
- Box needs `yt-dlp` + `ffmpeg` installed; same systemd service, same deploy.sh flow.

## App/Kit changes

- `BoxDefaults`: baseURL `https://stash.dmitrijs.dev/v1`; apiKey = the shared token
  (stored, overridable in the existing settings panel; "local" default dies).
- Pipeline: `media` + `transcribe` stages collapse into one box call
  (`POST /v1/videos/transcript` with the video's TikTok URL) — `MediaFetcher` and
  the on-device stream download drop out of the tester path. `enrich` stays
  on-device (page fetch for caption/author/cover works; only streams are blocked;
  thumbnail bytes downloaded immediately while the cover URL is fresh). `ocr`
  skipped. `analyze` unchanged shape.
- Error semantics fixes (from code survey): HTTP 401/403 must NOT report the box
  "online" in the import screen's ping; 429/5xx map to the retryable
  `awaitingBox`-style state rather than terminal `failed`; transcript request
  timeout raised from 30 s to 180 s (download + throttle headroom).
- Zip: no in-app extraction. The guide (below) tells testers to uncompress in the
  Files app (long-press → Uncompress) and pick `user_data_tiktok.json` or the
  extracted folder. Add ZipFoundation only if testers actually stumble.

## "Get your TikTok data" guide screen

New screen reachable from Import (and shown when the library is empty): numbered
steps in the Set List style — TikTok Profile → ☰ → Settings and privacy → Account →
Download your data → select **JSON** format → Request → (TikTok takes minutes–days)
→ Download the zip → open in Files → long-press → Uncompress → return to Stash →
Import → pick the JSON. Includes the "we only read your Favorite Videos" privacy
line matching the published privacy policy.

## Error handling

- Box unreachable → existing offline states; ping fixed to distinguish auth failure.
- Unavailable/deleted videos → `unavailable: true` from transcript endpoint →
  existing skip flow.
- Groq throttling on big libraries → per-video retry state; import continues on
  next app foreground/pipeline pass; progress UI already shows X of Y.
- Bedrock/Groq outage → stages park as retryable, never lose ingested bookmarks.

## Verification

- Backend: curl each endpoint (auth pass/fail, one RU + one EN video transcript,
  analyze round-trip, download bytes) from off-box network.
- App on simulator against the LIVE box: import the real export JSON → watch the
  pipeline populate the library with cloud transcripts/analysis; store row checks.
- Physical-device sanity via TestFlight build 2.
- Kit tests stay green; new/changed client contracts covered by existing
  fixture-based tests where present.

## Out of scope

Per-tester API keys, zip extraction in-app, OCR/frames, Data Portability
automated sync (separate track, in review), usage metering/quotas per tester.
