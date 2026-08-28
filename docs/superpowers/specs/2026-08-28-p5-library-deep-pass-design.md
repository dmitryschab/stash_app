# P5 — Deep pass for the whole library, not just shared videos

Depends on: P2 (Shazam rides the same backfill). Coordinate edits — same files.

## Problem

`backfillTranscripts(only:)` / `backfillVisualText(only:)` run only for shared
videos (`App/Sources/PipelineCenter.swift` `startDeepPassIfReady`, ~:423). A
bulk-imported library stays caption-only forever — and captions are all the
fast pass sees.

## Client changes (`PipelineCenter.swift`, `Pipeline.swift`)

1. Add a library deep-pass drain that calls the existing backfills with no
   `only:` scope (verify the actual signatures; extend if the unscoped variant
   doesn't exist). Transcripts first, then visual text. Reuse the existing
   serial behavior and `throttleAbortThreshold = 5`.
2. Gate: runs only when ALL hold — user signed in, `cloudImportEnabled`, not
   `deepPassBlocked`, device charging (`UIDevice.batteryState` charging/full),
   and on an unmetered path (`NWPathMonitor`, `isExpensive == false`).
3. Background: a second `BGProcessingTaskRequest` (new identifier, registered in
   Info.plist/project.yml) with `requiresExternalPower = true` and network
   required, scheduling the same drain. The existing task id and behavior stay
   untouched.
4. Quota-exhausted (402) and `.awaitingBox` handling already exist — do not
   duplicate; the drain must stop on the same conditions the shared pass does.

## Server changes (`services/webhook/`)

5. Verify whether `/v1/videos/transcript` and `/v1/tiktok/download/{id}` charge
   monthly quota units. Deep-pass work on already-imported videos must NOT
   consume quota (the video was paid for at import). Remove the charge if
   present.
6. Bound spend instead with a per-user daily cap on those two endpoints
   (default 300/day, one DynamoDB counter item next to QUOTA, UTC day key).
   Over cap → 429; the client's existing 429 → `.awaitingBox` path resumes
   tomorrow. Env-var override `DEEP_PASS_DAILY_CAP`.

## Non-goals

- No UI/settings toggle (default-on behind the charging+Wi-Fi gate).
- No change to fast-pass quota accounting.

## Verification

```
cd /Users/dmitryschab/Documents/projects/stash_app/services/webhook && python3 -m pytest -q
cd /Users/dmitryschab/Documents/projects/stash_app/TikTokBrainKit && swift test
```

New server tests: daily cap 429s at the limit; transcript/download paths charge
no quota. No git commits.
