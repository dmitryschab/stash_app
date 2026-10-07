# Sliced import — the newest 100 first

**Date:** 2026-10-07 · **Status:** approved in chat, sections 1–3 ·
**Branch:** off `feat/clef-onboarding`

## Why

After the first TikTok sync (or an export pick) a whole library lands as one import. Results
already stream into the app every 8 s, so the library is usable mid-import — but the queue is
standard SQS (no `MessageGroupId`), so the first 100 videos to finish are scattered across the
whole date range. People care most about their freshest saves. The owner wants the newest 100
sorted first, then the next 100, and so on, and the user told when the first slice is ready.

Total time does not change: the box still runs 4 workers at ~8 s per video. The newest 100
take ~3–4 minutes.

## Decisions

1. **The box releases the import in slices.** Every row is staged as today; only the newest
   `SLICE = 100` are enqueued at submission. The next slice goes out when `fastDone` is within
   `REFILL_AT = 20` of what has been released, so workers never idle at a slice boundary.
   Rejected: a priority queue (new infra, only the first 100 ordered) and a FIFO queue (one
   retryable failure blocks the import for the 300 s visibility timeout; queue migration).
   Rejected: phone-side slicing (the import would only advance while the app runs).
2. **The server owns "newest".** It sorts accepted videos by `bookmarkedAt`, newest first,
   instead of trusting the client's submission order.
3. **No wire change.** The phone infers the first slice from `fastPass.done`.
4. **The ping is a timed local notification.** The phone cannot learn when the slice finishes
   while backgrounded: BGAppRefresh runs 15+ minutes later, and APNs is a separate project.
   So on backgrounding it schedules a ping at the estimated finish time.

## Components

### C1 — server (`services/webhook/`)

**`cloud_import_store.py`**

Constants: `SLICE = 100`, `REFILL_AT = 20`, `RELEASE_LEASE_SECONDS = 60`.

- `newest_first(videos) -> list` — `sorted(videos, key=lambda v: v.bookmarked_at, reverse=True)`.
  Stable, so ties keep submission order. Used by `create_import` and the API.
- `create_import` stages `newest_first(request.videos)`; `_ensure_videos` stamps
  `order` (0-based position) on each VIDEO row. META gets `released = min(SLICE, total)`.
- `claim_release(import_id) -> tuple[int, int] | None` — reads META. `None` when `released` is
  absent (an import from before this change), `released >= total`, or
  `fastDone < released - REFILL_AT`. Otherwise one conditional update
  `SET releasing = :now` where `released = :seen AND (attribute_not_exists(releasing) OR releasing < :stale)`;
  on success returns `(released, min(released + SLICE, total))`, on a conditional failure `None`.
- `slice_videos(import_id, lo, hi) -> list[tuple[str, str | None]]` — `(videoID, url)` for the
  VIDEO rows with `lo <= order < hi`, sorted by `order`. One paged query over the import's rows.
- `finish_release(import_id, lo, hi)` — `SET released = :hi REMOVE releasing` where `released = :lo`.
- `pending_videos` (the client-retry re-drive) returns only rows with no `order` or
  `order < released`, so a retry does not release the whole library at once.

**`cloud_import_queue.py`** — one free function, shared by the worker and the API:

```python
def release_due(store, queue, import_id: str) -> int:
    """Hand the queue the next slice if it is due. Returns how many were sent."""
    span = store.claim_release(import_id)
    if span is None:
        return 0
    videos = store.slice_videos(import_id, *span)
    for video_id, url in videos:
        queue.enqueue(store.user_id, import_id, video_id, url=url)
    store.finish_release(import_id, *span)
    return len(videos)
```

Messages go out before the counter moves. A crash between the two leaves the lease to go stale,
and the next caller re-sends the same slice; `claim_video` already drops a message for a row
that is running or settled.

**`cloud_import_api.py`**
- `create_import`, first submission: enqueue `newest_first(body.videos)[:SLICE]` instead of every
  video. The map pass still samples the whole submission.
- `get_import_status` takes `queue = Depends(get_queue)` and calls `release_due` before reading
  the status, inside `try/except` that logs. This is stall recovery for a release that died with
  nothing left in flight; the phone polls every 8 s while open and from background refresh.

**`cloud_import_worker.py`** — `handle_message` calls `release_due(store, queue, import_id)` after
every `complete_video` or `fail_video`, inside `try/except` that logs. It never changes the
`HandleResult`. When nothing is due it costs one META read.

### C2 — Kit (`TikTokBrainKit/Sources/TikTokBrainKit/CloudImport.swift`)

`CloudImportLimits.firstSlice = 100`, commented as mirroring `cloud_import_store.SLICE`.

### C3 — app (`App/Sources/`)

**`ImportView.swift` — `heroSubtitle`, `.syncing`.** When `done >= firstSlice` and
`total > firstSlice`: "Your newest saves are ready — browse while the rest sorts · Sorted N of M".
Below that, today's line. If the Clef map line ("Sorting 60 of 941…") has landed, it keeps
priority while the map runs.

**`PipelineCenter.swift`**
- `firstPollSample: (importID: String, at: Date, done: Int)?` — set by `syncLibraryImport` on
  the first status of an import this session (or when the import ID changes).
- `static func firstSliceDelay(done: Int, total: Int, rate: Double?) -> TimeInterval?` — `nil`
  when `total <= firstSlice` or `done >= firstSlice`; otherwise `(firstSlice - done) / rate`,
  with `rate` defaulting to 0.5 videos/s (4 workers ÷ 8 s) when unknown or ≤ 0, clamped to
  60…900 s. `rate` is `(done - sample.done) / (now - sample.at)`.
- `appEnteredBackground`: if an import is active and `firstSliceDelay` is non-nil and the ping
  has not fired for this import, add `UNNotificationRequest(identifier: "first-slice-<importID>")`
  with a `UNTimeIntervalNotificationTrigger`. Title "Your newest saves are sorted", body
  "Open Stash to browse — the rest keeps sorting." Store `"<importID>|<fireAt>"` in the
  `firstSlicePing` UserDefaults key.
- `appBecameActive`: if the stored fire time is in the future, remove the pending request.
  If it is in the past, the ping fired; the key stays and nothing is scheduled again for that
  import.

## Error handling

- `release_due` raises in the worker or the status route → logged; the message result and the
  status response are unchanged.
- The lease holder dies mid-release → the lease goes stale after 60 s; the next settle or status
  poll re-sends the slice; duplicates are dropped by `claim_video`.
- Everything in flight settles while a release is stuck → the next status poll recovers it (app
  open, or background refresh).
- 21+ retryable videos in one slice → the next slice waits, at most the 300 s visibility timeout.
  That is backpressure while TikTok is throttling, not a stall.
- An import created before this deploy has no `released` → `release_due` does nothing; it drains
  as today.
- The estimate is off → the ping lands a minute or two early or late; the copy names no number.
- Notifications denied → nothing is scheduled; the card line still shows.

## Testing

Server, pytest with the existing fakes (`test_cloud_import_api.py`, `test_cloud_import_store.py`,
`test_cloud_import_worker.py`):

1. 250 videos submitted out of date order → the 100 newest by `bookmarkedAt` are enqueued;
   META `released = 100`; every row carries `order`.
2. `release_due` with `fastDone` 79 → sends nothing; 80 → sends orders 100–199, `released = 200`;
   the 50-video tail → `released = 250`.
3. Two `release_due` calls racing on one due slice → the slice is sent once.
4. A stale `releasing` lease → the same slice is re-sent and `released` advances.
5. The worker calls `release_due` after a settle; `release_due` raising does not change the
   `HandleResult`.
6. The client-retry re-drive sends only rows with `order < released`.
7. META without `released` → `release_due` returns 0 and sends nothing.
8. `GET /v1/imports/{id}` triggers `release_due`.
9. Draining 250 videos through a fake worker loop → every video processed once, and no video
   with `order >= 100` is claimed before 80 of the first 100 have settled.

App, DEBUG self-tests asserted at launch like the others:

10. `firstSliceDelay`: done 20, rate 0.5 → 160 s; rate `nil` → the 0.5 default; done ≥ 100 or
    total ≤ 100 → `nil`; results clamp to 60 and 900 s.
11. `heroSubtitle`: `(fastPass, 120, 941)` → contains "newest saves are ready";
    `(fastPass, 99, 941)` → today's line.
12. `xcodegen` + simulator build.

## Not in scope

APNs push (the upgrade path for an exact ping), ordering the budget cut (`paid[:charged]` still
trusts the client's order), worker concurrency, a per-slice deep pass, and reporting exact
per-slice completion on the wire.
