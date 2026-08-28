# P1 — Embedding search (the one the UI already promises)

Depends on: P5 (transcripts across the library make embeddings worth it).
Run after P2–P5 land — this touches `PipelineCenter.swift` and `SearchView.swift`.

## Problem

`SearchView.swift:97-127` is weighted substring matching over the whole library
per keystroke; the UI claims "Meaning, not just keywords". The blend was already
specced in `docs/superpowers/plans/2026-07-11-preserve-and-rediscover.md:126-164`
(`0.65 semantic + 0.30 lexical + 0.05 recency`). Read that plan first; follow it
unless it contradicts this spec — this spec wins.

## Server — NEW file `services/webhook/embeddings_api.py`

- `POST /v1/embeddings` `{texts: [string]}` → `{vectors: [[float]], model, dims}`.
- Mount as a router in `app.py` (one line — keeps `api_v1.py` untouched).
- Backing model: whatever the Bedrock Mantle OpenAI-compatible endpoint exposes
  for embeddings — verify with a real call before choosing; prefer a small
  multilingual model (~256–512 dims), e.g. Titan v2 with `dimensions: 256` if
  reachable. If Mantle has no embeddings route, use plain Bedrock
  `bedrock-runtime` in eu-central-1 (boto3 is already a dependency).
- Auth: same JWT funnel + entitlement check as other v1 routes
  (`stash_auth.py`). NO monthly quota charge. Caps: ≤32 texts/request,
  ≤8 KB/text, else 422.

## Client

- `BoxEmbeddingClient.swift` in the Kit, shaped like the other `BoxClients`.
- `Core/Entities.swift`: add `embedding: Data?` (packed little-endian Float32)
  and `embeddingRevision: Int` (0 default) to `Video`. SwiftData lightweight
  migration only — optional fields with defaults.
- Embed text: title + topics + summary + caption + first 1000 chars of
  transcript + first 500 of ocrText.
- Compute: after any analysis apply/upsert, and a backfill drain (batches of
  32, serial, same gating style as other drains) for videos with
  `embeddingRevision < 1`.

## Search blend (`SearchView.swift`)

- Keystroke path stays exactly the current lexical scorer (offline fallback).
- On submit (or 400 ms debounce), embed the query once via the box; then score
  `0.65 * cosine + 0.30 * normalizedLexical + 0.05 * recency` over videos that
  have embeddings; videos without embeddings keep their lexical-only score.
- Cosine in pure Swift or Accelerate; 1200 × 256 floats is trivial in memory.
- No embedding available (offline, error) → silently stay lexical.

## Verification

```
cd /Users/dmitryschab/Documents/projects/stash_app/services/webhook && python3 -m pytest -q
cd /Users/dmitryschab/Documents/projects/stash_app/TikTokBrainKit && swift test
```

New tests: endpoint validation/auth/caps (fake the upstream like existing
tests); Swift unit tests for cosine + blend math + Float32 pack/unpack
round-trip. No git commits.
