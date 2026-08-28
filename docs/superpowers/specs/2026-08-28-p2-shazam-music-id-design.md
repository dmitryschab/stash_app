# P2 — ShazamKit music ID on the deep-pass audio

## Problem

~71 music videos have `artist=""` and the prompt begs Gemma "NEVER invent an
artist" (`pipeline-lab/PROMPT.md:80-84` names the fix: a real music-ID service).
ShazamKit is that service: on-device, free, no mic needed for file input.

## Design

New `ShazamResolver` in `TikTokBrainKit/Sources/TikTokBrainKit/`:

- Input: the local mp4 the OCR backfill already downloads
  (`Pipeline.swift` `backfillVisualText`, download at `GET /v1/tiktok/download/{id}`).
- Read the audio track with `AVAssetReader` → PCM buffers →
  `SHSignatureGenerator` → `SHSession` match. Sample two windows (~15 s from the
  start, ~15 s from the middle); first match wins.
- Run after keyframe/OCR extraction, before the temp mp4 is deleted — same
  statement group so cleanup still always happens.
- Best-effort: no match or any error → no change, no retry, no stage failure.

## Merge rules (the testable core)

Given a match `(title, artist, appleMusicURL?)` and the video's existing music
payload (`MusicPick`, `Types.swift`):

1. A pick whose title Jaccard-matches the matched title (reuse
   `MatchConfidence`) and has an empty artist → fill the artist.
2. Never overwrite a non-empty LLM artist (the playing sound is not the
   recommended albums — a DJ-list video's match is one track of twelve).
3. `category == .music` and zero picks → add one pick from the match.
4. Respect `MusicPick.maxPerVideo` (12). After any change, re-run
   `MusicPickResolver` for the affected picks so store links/art refresh.

## Plumbing

- Protocol-wrap the matcher (`protocol AudioMatching`) so unit tests inject fake
  matches without ShazamKit; the ShazamKit-backed implementation lives behind it.
- App capability: add ShazamKit to the App ID / `App/project.yml`
  entitlements. iOS 15+ API only. No microphone permission (file-based).
- No server changes.

## Verification

```
cd /Users/dmitryschab/Documents/projects/stash_app/TikTokBrainKit && swift test
```

New tests must cover merge rules 1–4 with fakes. No git commits.
