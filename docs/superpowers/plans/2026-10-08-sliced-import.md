# Sliced Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The box sorts an import newest-first in slices of 100, and the phone says so — a card line once the newest 100 are in, and a timed local ping when the app is in the background.

**Architecture:** Every VIDEO row gets an `order` (0 = newest). `create_import` enqueues only the first slice; `release_due` hands the queue the next slice when `fastDone` is within 20 of `released`, under a 60 s lease on META. The worker calls it after every settled video; the status route calls it as stall recovery. The phone infers the first slice from `fastPass.done` — no wire change.

**Tech Stack:** Python 3.11, FastAPI, DynamoDB (boto3), SQS; Swift 6 / SwiftUI, UserNotifications.

**Spec:** `docs/superpowers/specs/2026-10-07-sliced-import-design.md`

## Global Constraints

- Work on branch `feat/sliced-import` in its own worktree, based on the current HEAD of `feat/clef-onboarding` (must contain `c364133`, the map hero line). Another session commits to `feat/clef-onboarding`; never edit that checkout.
- Server constants, exact: `SLICE = 100`, `REFILL_AT = 20`, `RELEASE_LEASE_SECONDS = 60`, `LEASE_FREE = "1970-01-01T00:00:00+00:00"`. Phone: `CloudImportLimits.firstSlice = 100`.
- Copy, exact. Card: `"Your newest saves are ready — browse while the rest sorts · Sorted N of M"`. Ping title: `"Your newest saves are sorted"`. Ping body: `"Open Stash to browse — the rest keeps sorting."`. Ping id: `"first-slice-<importID>"`.
- Ping delay: default rate 0.5 videos/s, clamped to 60…900 s.
- No wire change to `ImportStatus`; `ANALYSIS_REVISION` unchanged.
- DynamoDB expressions must be ones the test double evaluates: `SET` only (no `REMOVE`), conditions joined by ` AND ` (no `OR`, no parentheses).
- Python tests: `cd services/webhook && uv run --with-requirements requirements.txt --with pytest --with cryptography python -m pytest -q <args>` (no venv exists). Below, `$PYTEST` means that command.
- Commit messages: conventional prefix, no co-author or "Generated with" footer.
- Do not deploy. `services/webhook/deploy.sh` is manual and needs the owner's go-ahead.

## Review Focus

1. **An import of exactly 100 videos** → one slice is the whole library: nothing is ever released again, no card line, no ping. Test: Task 1 `test_an_import_of_exactly_one_slice_never_releases_again`; Task 5 self-test `total: 100 → nil`.
2. **A free retry of an old save inside a fresh import** → it must not take a first-slice place, even though the API puts free retries first in `body.videos`. Test: Task 2 `test_a_free_retry_of_an_old_save_does_not_jump_the_newest_slice`.
3. **An import created before this deploy** (no `released`, no `order`) → `release_due` does nothing and a client retry re-drives every pending row, as today. Test: Task 1 `test_an_import_from_before_slicing_is_left_alone`.
4. **The release throws during a status poll** (SQS throttling) → the poll still answers 200 with the status. Test: Task 2 `test_a_failing_release_does_not_break_the_status_poll`.
5. **A second import after the first one's ping already fired** → the new import still gets its own ping. Test: Task 5 self-test on `shouldSchedulePing`.

---

### Task 1: Store slices and `release_due`

**Files:**
- Modify: `services/webhook/cloud_import_store.py` (constants after `MAX_FREE_RETRIES`; `create_import`; `_ensure_videos`; `pending_videos`; new methods after `skip_map_video`)
- Modify: `services/webhook/cloud_import_queue.py` (new function at the end)
- Test: `services/webhook/test_cloud_import_store.py` (append at the end)

**Interfaces:**
- Produces: `cloud_import_store.SLICE`, `REFILL_AT`, `RELEASE_LEASE_SECONDS`, `LEASE_FREE`; `newest_first(videos) -> list`; `DynamoImportStore.claim_release(import_id: str) -> tuple[int, int] | None`; `DynamoImportStore.slice_videos(import_id: str, lo: int, hi: int) -> list[tuple[str, str | None]]`; `DynamoImportStore.finish_release(import_id: str, lo: int, hi: int) -> None`; `cloud_import_queue.release_due(store, queue, import_id: str) -> int`.

- [ ] **Step 1: Write the failing tests**

Append to `services/webhook/test_cloud_import_store.py` (`ConditionalTable` is already imported above the map tests):

```python
from cloud_import_queue import release_due  # noqa: E402
from cloud_import_store import LEASE_FREE, REFILL_AT, SLICE  # noqa: E402


class SliceQueue:
    def __init__(self):
        self.sent = []

    def enqueue(self, user_id, import_id, video_id, url=None):
        self.sent.append(video_id)


def dated_request(count, client_import_id="22222222-2222-4222-8222-222222222222"):
    """Video "n" was saved n hours ago, and the list is submitted oldest-first on purpose:
    the box, not the client, decides what "newest" means."""
    now = datetime.now(timezone.utc)
    return CreateImportRequest(
        clientImportID=client_import_id,
        videos=[
            BookmarkInput(videoID=str(n), url=f"https://www.tiktok.com/@x/video/{n}",
                          bookmarkedAt=now - timedelta(hours=n))
            for n in range(count, 0, -1)
        ],
    )


def sliced(count):
    table = ConditionalTable()
    store = DynamoImportStore(table=table, user_id=USER)
    import_id = store.create_import(dated_request(count)).import_id
    return table, store, import_id


def meta_row(table, store, import_id):
    return table.items[(store.partition, f"IMPORT#{import_id}#META")]


def settle(table, store, import_id, count):
    meta_row(table, store, import_id)["fastDone"] += count


def test_create_orders_rows_newest_first_and_releases_one_slice():
    table, store, import_id = sliced(250)
    rows = {item["videoID"]: item for (_pk, sk), item in table.items.items() if "#VIDEO#" in sk}

    assert rows["1"]["order"] == 0 and rows["250"]["order"] == 249
    assert meta_row(table, store, import_id)["released"] == SLICE
    assert store.slice_videos(import_id, 0, 3) == [
        (str(n), f"https://www.tiktok.com/@x/video/{n}") for n in (1, 2, 3)]


def test_the_next_slice_goes_out_only_when_the_current_one_is_nearly_settled():
    table, store, import_id = sliced(250)
    queue = SliceQueue()

    settle(table, store, import_id, SLICE - REFILL_AT - 1)            # 79 settled
    assert release_due(store, queue, import_id) == 0
    settle(table, store, import_id, 1)                                 # 80
    assert release_due(store, queue, import_id) == 100
    assert queue.sent == [str(n) for n in range(101, 201)]
    assert meta_row(table, store, import_id)["released"] == 200
    assert meta_row(table, store, import_id)["releaseLeaseUntil"] == LEASE_FREE

    settle(table, store, import_id, 100)                               # 180
    assert release_due(store, queue, import_id) == 50                  # the tail
    assert meta_row(table, store, import_id)["released"] == 250
    settle(table, store, import_id, 70)                                # all 250
    assert release_due(store, queue, import_id) == 0


def test_two_releases_racing_send_the_slice_once():
    table, store, import_id = sliced(250)
    settle(table, store, import_id, 80)

    assert store.claim_release(import_id) == (100, 200)
    assert store.claim_release(import_id) is None                      # the lease is held


def test_a_release_that_died_is_retaken_after_the_lease():
    table, store, import_id = sliced(250)
    settle(table, store, import_id, 80)
    assert store.claim_release(import_id) == (100, 200)                # …and then the caller died
    meta_row(table, store, import_id)["releaseLeaseUntil"] = (
        datetime.now(timezone.utc) - timedelta(seconds=1)).isoformat()
    queue = SliceQueue()

    assert release_due(store, queue, import_id) == 100
    assert queue.sent == [str(n) for n in range(101, 201)]
    assert meta_row(table, store, import_id)["released"] == 200


def test_an_import_of_exactly_one_slice_never_releases_again():
    table, store, import_id = sliced(SLICE)
    assert meta_row(table, store, import_id)["released"] == SLICE
    settle(table, store, import_id, SLICE)

    assert store.claim_release(import_id) is None


def test_the_retry_redrive_sends_only_released_rows():
    _table, store, import_id = sliced(250)

    assert {video_id for video_id, _url in store.pending_videos(import_id)} == {
        str(n) for n in range(1, 101)}


def test_an_import_from_before_slicing_is_left_alone():
    table, store, import_id = sliced(3)
    del meta_row(table, store, import_id)["released"]
    for (_pk, sk), item in table.items.items():
        if "#VIDEO#" in sk:
            del item["order"]

    assert store.claim_release(import_id) is None
    assert len(store.pending_videos(import_id)) == 3


def test_draining_an_import_sends_every_video_once_newest_first():
    table, store, import_id = sliced(250)
    queue = SliceQueue()
    queue.sent = [video_id for video_id, _url in store.slice_videos(import_id, 0, SLICE)]  # what create_import sends
    settled = 0
    while settled < len(queue.sent):
        settle(table, store, import_id, 1)
        settled += 1
        before = len(queue.sent)
        release_due(store, queue, import_id)
        if len(queue.sent) > before:
            assert before - settled <= REFILL_AT    # a slice only goes out once the last is nearly done

    assert queue.sent == [str(n) for n in range(1, 251)]
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `$PYTEST test_cloud_import_store.py`
Expected: collection error, `ImportError: cannot import name 'release_due' from 'cloud_import_queue'`.

- [ ] **Step 3: Implement the store side**

In `services/webhook/cloud_import_store.py`, after the `MAX_FREE_RETRIES = 3` block:

```python
# The import goes to the queue in slices, newest first, so the saves a person reaches for
# first are sorted in the first few minutes. The next slice goes out while REFILL_AT of the
# current one are still in flight, so the workers never wait at a slice boundary.
SLICE = 100
REFILL_AT = 20
# A release that dies between sending a slice and recording it is retaken after this long.
RELEASE_LEASE_SECONDS = 60
# "Nobody holds the lease": older than any real timestamp, so one `<` compares it.
LEASE_FREE = "1970-01-01T00:00:00+00:00"


def newest_first(videos) -> list:
    """Submission order is the client's business; slice order is ours. `timestamp()` so a
    naive date cannot raise against an aware one. Stable: equal dates keep their order."""
    return sorted(videos, key=lambda video: video.bookmarked_at.timestamp(), reverse=True)
```

In `create_import`, replace `self._ensure_videos(import_id, request.videos)` with:

```python
        self._ensure_videos(import_id, newest_first(request.videos))
```

and add two keys to the `meta` dict, after `"deferred": deferred,`:

```python
            "released": min(SLICE, len(request.videos)),
            "releaseLeaseUntil": LEASE_FREE,
```

In `_ensure_videos`, change the loop header and stamp the position:

```python
        for order, video in enumerate(videos):
            item = {
                **self._key(import_id, f"VIDEO#{video.video_id}"),
                "videoID": video.video_id,
                "url": video.url,
                "bookmarkedAt": video.bookmarked_at.isoformat(),
                "order": order,
                "state": VideoState.QUEUED.value,
                "attempts": 0,
                "updatedAt": now,
            }
```

Replace the body of `pending_videos` (keep its docstring) with:

```python
        waiting = {VideoState.QUEUED.value, VideoState.RETRYABLE.value}
        released = (self._get(self._key(import_id, "META")) or {}).get("released")
        return [
            (item["videoID"], item.get("url"))
            for page in self._pages(f"IMPORT#{import_id}#VIDEO#")
            for item in page.get("Items", [])
            if item.get("state") in waiting
            # A row past the released slices waits for release_due, not for a client retry.
            and (released is None or item.get("order") is None or int(item["order"]) < int(released))
        ]
```

After `skip_map_video`, add:

```python
    # ------------------------------------------------------------------ slices

    def claim_release(self, import_id: str) -> tuple[int, int] | None:
        """If the next slice is due, take the lease and return its `order` span [lo, hi).
        None when nothing is due, the lease is held, or the import predates slicing."""
        meta = self._get(self._key(import_id, "META"))
        if not meta or "released" not in meta:
            return None
        released, total = int(meta["released"]), int(meta["total"])
        if released >= total or int(meta.get("fastDone", 0)) < released - REFILL_AT:
            return None
        now = datetime.now(timezone.utc)
        try:
            self.table.update_item(
                Key=self._key(import_id, "META"),
                UpdateExpression="SET releaseLeaseUntil = :until",
                # Aliased like #total: cheaper than finding out in production which words
                # DynamoDB reserves.
                ConditionExpression="#released = :seen AND releaseLeaseUntil < :now",
                ExpressionAttributeNames={"#released": "released"},
                ExpressionAttributeValues={
                    ":until": (now + timedelta(seconds=RELEASE_LEASE_SECONDS)).isoformat(),
                    ":seen": released,
                    ":now": now.isoformat(),
                },
            )
        except Exception as error:
            if _is_conditional_failure(error):
                return None
            raise
        return released, min(released + SLICE, total)

    def slice_videos(self, import_id: str, lo: int, hi: int) -> list[tuple[str, str | None]]:
        """(videoID, url) for the rows with lo <= order < hi, newest first."""
        rows = [
            item
            for page in self._pages(f"IMPORT#{import_id}#VIDEO#")
            for item in page.get("Items", [])
            if item.get("order") is not None and lo <= int(item["order"]) < hi
        ]
        return [(item["videoID"], item.get("url")) for item in sorted(rows, key=lambda item: int(item["order"]))]

    def finish_release(self, import_id: str, lo: int, hi: int) -> None:
        """Record a sent slice and free the lease. A conditional miss means a caller that took
        over a stale lease already recorded it — nothing left to do."""
        try:
            self.table.update_item(
                Key=self._key(import_id, "META"),
                UpdateExpression="SET #released = :hi, releaseLeaseUntil = :free",
                ConditionExpression="#released = :lo",
                ExpressionAttributeNames={"#released": "released"},
                ExpressionAttributeValues={":hi": hi, ":free": LEASE_FREE, ":lo": lo},
            )
        except Exception as error:
            if not _is_conditional_failure(error):
                raise
```

- [ ] **Step 4: Implement `release_due`**

Append to `services/webhook/cloud_import_queue.py`:

```python
def release_due(store, queue, import_id: str) -> int:
    """Hand the queue the next slice if it is due. Returns how many were sent.

    Messages go out before the counter moves: a crash in between leaves the lease to go
    stale and the next caller re-sends the slice. `claim_video` already drops a message for
    a row that is running or settled, so a re-send costs messages, not work."""
    span = store.claim_release(import_id)
    if span is None:
        return 0
    videos = store.slice_videos(import_id, *span)
    for video_id, url in videos:
        queue.enqueue(store.user_id, import_id, video_id, url=url)
    store.finish_release(import_id, *span)
    return len(videos)
```

- [ ] **Step 5: Run the store tests, then the whole suite**

Run: `$PYTEST test_cloud_import_store.py` → Expected: all pass.
Run: `$PYTEST` → Expected: all pass (no existing test asserts the exact META dict or `pending_videos` order).

- [ ] **Step 6: Commit**

```bash
git add services/webhook/cloud_import_store.py services/webhook/cloud_import_queue.py services/webhook/test_cloud_import_store.py
git commit -m "feat(import): rows carry their newest-first order and the box releases them a slice at a time"
```

---

### Task 2: The API sends the first slice and the status poll nudges the rest

**Files:**
- Modify: `services/webhook/cloud_import_api.py` (imports; `get_queue`; first-submission enqueue loop in `create_import`; `get_import_status`)
- Test: `services/webhook/test_cloud_import_api.py` (`FakeStore`; new tests at the end)

**Interfaces:**
- Consumes: `cloud_import_store.SLICE`, `newest_first(videos)`; `cloud_import_queue.release_due(store, queue, import_id)` (Task 1).
- Produces: `GET /v1/imports/{id}` calls `release_due` before reading the status.

- [ ] **Step 1: Write the failing tests**

In `services/webhook/test_cloud_import_api.py`, change the `from datetime import …` line to:

```python
from datetime import datetime, timedelta, timezone
```

In `FakeStore.__init__`, add `self.release_checks = []`, and add this method to `FakeStore`:

```python
    def claim_release(self, import_id):
        # Records the nudge; the real slice arithmetic is tested against the store.
        self.release_checks.append(import_id)
        return None
```

Append at the end of the file:

```python
def dated_payload(count):
    """Video "n" was saved n hours before a fixed instant; submitted oldest-first on purpose."""
    base = datetime(2026, 10, 1, tzinfo=timezone.utc)
    return {
        "clientImportID": "33333333-3333-4333-8333-333333333333",
        "videos": [
            {"videoID": str(n), "url": f"https://www.tiktok.com/@x/video/{n}",
             "bookmarkedAt": (base - timedelta(hours=n)).isoformat()}
            for n in range(count, 0, -1)
        ],
    }


def test_a_first_submission_enqueues_only_the_newest_slice(dependencies):
    _, queue = dependencies
    with TestClient(app) as client:
        assert client.post("/v1/imports", json=dated_payload(250)).status_code == 202

    assert [message["videoID"] for message in queue.messages] == [str(n) for n in range(1, 101)]


def test_a_free_retry_of_an_old_save_does_not_jump_the_newest_slice(dependencies):
    store, queue = dependencies
    store.failures = {"150": 1}     # the oldest save failed once before: free, and placed first in body
    with TestClient(app) as client:
        assert client.post("/v1/imports", json=dated_payload(150)).status_code == 202

    assert [message["videoID"] for message in queue.messages] == [str(n) for n in range(1, 101)]


def test_the_status_poll_nudges_a_stalled_release(dependencies):
    store, _ = dependencies
    with TestClient(app) as client:
        created = client.post("/v1/imports", json=payload()).json()
        client.get(f"/v1/imports/{created['importID']}")

    assert store.release_checks == [created["importID"]]


def test_a_failing_release_does_not_break_the_status_poll(dependencies):
    store, _ = dependencies

    def throttled(import_id):
        raise RuntimeError("sqs is throttling")

    store.claim_release = throttled
    with TestClient(app) as client:
        created = client.post("/v1/imports", json=payload()).json()
        status = client.get(f"/v1/imports/{created['importID']}")

    assert status.status_code == 200
    assert status.json()["fastPass"] == {"done": 1, "total": 2}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `$PYTEST test_cloud_import_api.py`
Expected: `test_a_first_submission_enqueues_only_the_newest_slice` fails (250 messages, oldest first), `test_a_free_retry…` fails, `test_the_status_poll_nudges…` fails (`[] != ['import-1']`).

- [ ] **Step 3: Implement**

In `services/webhook/cloud_import_api.py`, change the imports:

```python
from concurrent.futures import ThreadPoolExecutor
from functools import lru_cache
```

```python
from cloud_import_queue import SQSImportQueue, release_due
from cloud_import_store import MAX_FREE_RETRIES, SLICE, DynamoImportStore, newest_first
```

Replace `get_queue`:

```python
# One client per process: the status poll takes the queue too now, and building a client
# is an instance-metadata round trip. The credentials inside it refresh themselves.
@lru_cache(maxsize=1)
def get_queue() -> SQSImportQueue:
    return SQSImportQueue()
```

In `create_import`, first-submission branch, replace

```python
            for video in body.videos:
                queue.enqueue(store.user_id, created.import_id, video.video_id, url=video.url)
```

with

```python
            # The newest slice only; the worker releases the rest as this one settles.
            for video in newest_first(body.videos)[:SLICE]:
                queue.enqueue(store.user_id, created.import_id, video.video_id, url=video.url)
```

Replace `get_import_status`:

```python
@router.get("/imports/{import_id}", response_model=ImportStatus, response_model_by_alias=True)
def get_import_status(
    import_id: str,
    store: DynamoImportStore = Depends(user_store),
    queue: SQSImportQueue = Depends(get_queue),
):
    # Stall recovery: a release that died with nothing left in flight has no worker to
    # retake it, and the phone polls here every 8 s while open and from background refresh.
    try:
        release_due(store, queue, import_id)
    except Exception:
        log.exception("slice release from the status poll failed import=%s", import_id)
    status = store.get_status(import_id)
    if status is None:
        raise HTTPException(status_code=404, detail="import not found")
    return status
```

- [ ] **Step 4: Run the tests**

Run: `$PYTEST test_cloud_import_api.py` → Expected: all pass.
Run: `$PYTEST` → Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add services/webhook/cloud_import_api.py services/webhook/test_cloud_import_api.py
git commit -m "feat(import): a new import sends its newest hundred first; the status poll restarts a stalled release"
```

---

### Task 3: The worker releases the next slice as videos settle

**Files:**
- Modify: `services/webhook/cloud_import_worker.py` (import; new `_release`; three call sites in `handle_message`)
- Test: `services/webhook/test_cloud_import_worker.py` (`FakeStore`; new tests at the end)

**Interfaces:**
- Consumes: `cloud_import_queue.release_due(store, queue, import_id)` (Task 1).

- [ ] **Step 1: Write the failing tests**

In `test_cloud_import_worker.py`, add to `FakeStore.__init__` `self.release_checks = []`, and this method to `FakeStore`:

```python
    def claim_release(self, import_id):
        self.release_checks.append(import_id)
        return None
```

Append:

```python
@pytest.mark.parametrize("process", [
    lambda *_args: VideoResult(videoID="123", title="Saved"),
    lambda *_args: (_ for _ in ()).throw(PipelineError("bad", False, "invalid_output")),
    lambda *_args: (_ for _ in ()).throw(RuntimeError("boom")),
], ids=["completed", "pipeline-error", "unexpected-error"])
def test_every_settled_video_checks_for_the_next_slice(process):
    store = FakeStore()
    handle_message(message(), stores(store), SimpleNamespace(process=process), FakeQueue())

    assert store.release_checks == ["import-1"]


def test_a_failing_release_does_not_change_the_videos_outcome():
    store = FakeStore()

    def throttled(import_id):
        raise RuntimeError("dynamo is throttling")

    store.claim_release = throttled
    queue = FakeQueue()
    pipeline = SimpleNamespace(process=lambda *_args: VideoResult(videoID="123", title="Saved"))

    result = handle_message(message(), stores(store), pipeline, queue)

    assert result == HandleResult(deleted=True, retryable=False)
    assert queue.deleted == ["receipt-1"]
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `$PYTEST test_cloud_import_worker.py -k "slice or release"`
Expected: 3 failures, `assert [] == ['import-1']`.

- [ ] **Step 3: Implement**

In `services/webhook/cloud_import_worker.py`, change the queue import:

```python
from cloud_import_queue import MESSAGE_SCHEMA, SQSImportQueue, release_due
```

Add after `_classify`:

```python
def _release(store, queue, import_id: str) -> None:
    """A settled video may make the next slice due. Never raises: the video's outcome is
    already recorded, and a release that fails here is retaken by the next settle or poll."""
    try:
        release_due(store, queue, import_id)
    except Exception:
        log.exception("slice release failed import=%s", import_id)
```

In `handle_message`, add `_release(store, queue, import_id)` on the line right after each of the two `store.fail_video(...)` calls (the `PipelineError` branch and the `Exception` branch). Replace the success tail

```python
    if store.complete_video(import_id, result):
        _delete(queue, message)
        return HandleResult(deleted=True, retryable=False)
    return HandleResult(deleted=False, retryable=True)
```

with

```python
    completed = store.complete_video(import_id, result)
    _release(store, queue, import_id)
    if completed:
        _delete(queue, message)
        return HandleResult(deleted=True, retryable=False)
    return HandleResult(deleted=False, retryable=True)
```

- [ ] **Step 4: Run the tests**

Run: `$PYTEST test_cloud_import_worker.py` → Expected: all pass.
Run: `$PYTEST` → Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add services/webhook/cloud_import_worker.py services/webhook/test_cloud_import_worker.py
git commit -m "feat(worker): every settled video checks whether the next slice is due"
```

---

### Task 4: The card says the newest saves are in

**Files:**
- Modify: `TikTokBrainKit/Sources/TikTokBrainKit/CloudImport.swift` (`CloudImportLimits`)
- Modify: `App/Sources/ImportView.swift` (`heroSubtitle`, `.syncing`; `selfTest`)

**Interfaces:**
- Produces: `CloudImportLimits.firstSlice: Int` (= 100), used again in Task 5.

A self-test runs only when the app launches, so this task verifies once, after the change, with a build and a headless launch (~3 min).

- [ ] **Step 1: Update the self-test**

In `ImportView.selfTest()`, replace

```swift
            && heroSubtitle(.syncing, box(.fastPass, 412, 941, map: CloudImportMap(sampled: 60, done: 60)))
                == "Sorted 412 of 941 · you can close the app, Stash pings you when it is done"
```

with

```swift
            && heroSubtitle(.syncing, box(.fastPass, 412, 941, map: CloudImportMap(sampled: 60, done: 60)))
                == "Your newest saves are ready — browse while the rest sorts · Sorted 412 of 941"
            // The box sorts newest first in slices of 100: the line changes at the slice, and a
            // library that is one slice never shows it.
            && heroSubtitle(.syncing, box(.fastPass, 99, 941))
                == "Sorted 99 of 941 · you can close the app, Stash pings you when it is done"
            && heroSubtitle(.syncing, box(.fastPass, 100, 941))
                == "Your newest saves are ready — browse while the rest sorts · Sorted 100 of 941"
            && heroSubtitle(.syncing, box(.fastPass, 60, 100))
                == "Sorted 60 of 100 · you can close the app, Stash pings you when it is done"
```

- [ ] **Step 2: Add the constant**

In `CloudImport.swift`, inside `public enum CloudImportLimits`, after `maxVideosPerImport`:

```swift
    /// The box releases an import to its queue in slices of this many, newest first
    /// (services/webhook/cloud_import_store.SLICE). The phone mirrors it to know when the saves
    /// people reach for first are in.
    public static let firstSlice = 100
```

- [ ] **Step 3: Change the line**

In `ImportView.heroSubtitle`, `.syncing` case, replace

```swift
            return "Sorted \(cloud.fastPass.done) of \(cloud.fastPass.total) "
                + "· you can close the app, Stash pings you when it is done"
```

with

```swift
            let sorted = "Sorted \(cloud.fastPass.done) of \(cloud.fastPass.total)"
            if cloud.fastPass.total > CloudImportLimits.firstSlice,
               cloud.fastPass.done >= CloudImportLimits.firstSlice {
                return "Your newest saves are ready — browse while the rest sorts · " + sorted
            }
            return sorted + " · you can close the app, Stash pings you when it is done"
```

The map line above it (`if let map = cloud.map, map.done < map.sampled`) stays first.

- [ ] **Step 4: Build the Kit and the app**

```bash
cd TikTokBrainKit && swift build 2>&1 | tail -3
```
Expected: `Build complete!`

```bash
cd App && xcodegen generate && xcodebuild -project Stash.xcodeproj -scheme Stash -destination 'generic/platform=iOS Simulator' -derivedDataPath /private/tmp/claude-501/-Users-dmitryschab-Documents-projects-stash-app/137bc064-0d29-4d29-8874-54effe2bc226/scratchpad/dd build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Launch headless and confirm the self-tests hold**

```bash
UD=55BEAA32-9D81-4FE5-AF1F-2A60B51F244E
DD=/private/tmp/claude-501/-Users-dmitryschab-Documents-projects-stash-app/137bc064-0d29-4d29-8874-54effe2bc226/scratchpad/dd
xcrun simctl shutdown $UD; xcrun simctl boot $UD; xcrun simctl bootstatus $UD -b
xcrun simctl install $UD "$DD/Build/Products/Debug-iphonesimulator/Stash.app"
perl -e 'alarm 60; exec @ARGV' -- xcrun simctl launch $UD dev.dmitryschab.Stash -seedFile /nonexistent
sleep 8; xcrun simctl spawn $UD launchctl list | grep -c dev.dmitryschab.Stash
```
Expected: `1` — the app is still running. A failed self-test `assert` crashes it at launch and prints `0`; then read the crash with `xcrun simctl spawn $UD log show --last 1m --predicate 'process == "Stash"' | grep -i assert`.

- [ ] **Step 6: Commit**

```bash
git add TikTokBrainKit/Sources/TikTokBrainKit/CloudImport.swift App/Sources/ImportView.swift
git commit -m "feat(import): the card says the newest saves are in once the first slice is sorted"
```

---

### Task 5: A timed ping when the newest saves should be in

**Files:**
- Modify: `App/Sources/PipelineCenter.swift` (property next to `cloudState` ~line 97; `syncLibraryImport` after `cloudState.apply(status: status)`; new section after `notifyLibraryReady`; `appBecameActive`; `appEnteredBackground`)
- Modify: `App/Sources/TikTokBrainApp.swift` (the DEBUG self-test list, after `PipelineCenter.expectedSelfTest()`)

**Interfaces:**
- Consumes: `CloudImportLimits.firstSlice` (Task 4).
- Produces: `PipelineCenter.firstSliceDelay(done:total:rate:) -> TimeInterval?`, `parsePing(_:) -> (importID: String, fireAt: Date)?`, `shouldSchedulePing(stored:importID:now:) -> Bool`, `firstSliceSelfTest() -> Bool`.

- [ ] **Step 1: Register the self-test**

In `TikTokBrainApp.swift`, after the `PipelineCenter.expectedSelfTest()` assert:

```swift
        assert(PipelineCenter.firstSliceSelfTest(), "PipelineCenter first-slice self-test failed")
```

- [ ] **Step 2: Add the pure core and its self-test**

In `PipelineCenter.swift`, right after `static func notifyLibraryReady(…) { … }`:

```swift
    // MARK: - First-slice ping

    // ponytail: a timed guess, not a report — the box cannot reach a backgrounded phone and
    // BGAppRefresh runs 15+ minutes late. Upgrade path: an APNs push from the box.
    private static let firstSlicePingKey = "firstSlicePing"

    /// Seconds until the newest slice is likely sorted, or nil when there is nothing to wait
    /// for: a library that fits in one slice, or a first slice already done.
    static func firstSliceDelay(done: Int, total: Int, rate: Double?) -> TimeInterval? {
        let slice = CloudImportLimits.firstSlice
        guard total > slice, done < slice else { return nil }
        let perSecond = rate.flatMap { $0 > 0 ? $0 : nil } ?? 0.5   // 4 workers ÷ ~8 s a video
        return min(max(Double(slice - done) / perSecond, 60), 900)
    }

    /// The stored ping, "<importID>|<fire time in epoch seconds>".
    static func parsePing(_ stored: String?) -> (importID: String, fireAt: Date)? {
        guard let parts = stored?.split(separator: "|"), parts.count == 2,
              let epoch = TimeInterval(parts[1]) else { return nil }
        return (String(parts[0]), Date(timeIntervalSince1970: epoch))
    }

    /// One ping per import: only a ping for this same import that has already gone off stops
    /// another. A previous import's ping, or one still pending, does not.
    static func shouldSchedulePing(stored: String?, importID: String, now: Date) -> Bool {
        guard let ping = parsePing(stored), ping.importID == importID else { return true }
        return ping.fireAt > now
    }

    #if DEBUG
    static func firstSliceSelfTest() -> Bool {
        let now = Date()
        let past = "imp-1|\(now.addingTimeInterval(-5).timeIntervalSince1970)"
        let future = "imp-1|\(now.addingTimeInterval(120).timeIntervalSince1970)"
        return firstSliceDelay(done: 20, total: 941, rate: 0.5) == 160
            && firstSliceDelay(done: 20, total: 941, rate: nil) == 160     // no measurement yet
            && firstSliceDelay(done: 20, total: 941, rate: 0) == 160       // no progress yet
            && firstSliceDelay(done: 99, total: 941, rate: 0.5) == 60      // clamped up
            && firstSliceDelay(done: 0, total: 941, rate: 0.01) == 900     // clamped down
            && firstSliceDelay(done: 100, total: 941, rate: 0.5) == nil    // already sorted
            && firstSliceDelay(done: 0, total: 100, rate: 0.5) == nil      // one slice is the library
            && parsePing(past)?.importID == "imp-1"
            && parsePing("imp-1") == nil && parsePing(nil) == nil
            && !shouldSchedulePing(stored: past, importID: "imp-1", now: now)   // it went off
            && shouldSchedulePing(stored: future, importID: "imp-1", now: now)  // still pending: reschedule
            && shouldSchedulePing(stored: past, importID: "imp-2", now: now)    // a new import
            && shouldSchedulePing(stored: nil, importID: "imp-1", now: now)
    }
    #endif
```

- [ ] **Step 3: Measure the rate**

Next to `private var cloudState = CloudImportSyncState()`:

```swift
    /// The first status this session saw for the running import: where the ping's rate is
    /// measured from.
    private var firstPollSample: (importID: String, at: Date, done: Int)?
```

In `syncLibraryImport`, right after `cloudState.apply(status: status)`:

```swift
            if firstPollSample?.importID != status.importID {
                firstPollSample = (status.importID, Date(), status.fastPass.done)
            }
```

- [ ] **Step 4: Schedule and cancel**

After `firstSliceSelfTest()`'s `#endif`, add:

```swift
    private func scheduleFirstSlicePing() {
        guard cloudState.isActive, let status = cloudState.status else { return }
        let now = Date()
        let rate = firstPollSample.flatMap { sample -> Double? in
            let elapsed = now.timeIntervalSince(sample.at)
            guard sample.importID == status.importID, elapsed > 0 else { return nil }
            return Double(status.fastPass.done - sample.done) / elapsed
        }
        let defaults = UserDefaults.standard
        guard let delay = Self.firstSliceDelay(done: status.fastPass.done, total: status.fastPass.total, rate: rate),
              Self.shouldSchedulePing(stored: defaults.string(forKey: Self.firstSlicePingKey),
                                      importID: status.importID, now: now) else { return }
        let content = UNMutableNotificationContent()
        content.title = "Your newest saves are sorted"
        content.body = "Open Stash to browse — the rest keeps sorting."
        content.sound = .default
        // Same identifier on every background: a second schedule replaces the first.
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "first-slice-\(status.importID)", content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)))
        defaults.set("\(status.importID)|\(now.addingTimeInterval(delay).timeIntervalSince1970)",
                     forKey: Self.firstSlicePingKey)
    }

    /// Back in the app before the ping went off: the card says it now, so the ping would be noise.
    private func cancelPendingFirstSlicePing() {
        let defaults = UserDefaults.standard
        guard let ping = Self.parsePing(defaults.string(forKey: Self.firstSlicePingKey)),
              ping.fireAt > Date() else { return }
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: ["first-slice-\(ping.importID)"])
        defaults.removeObject(forKey: Self.firstSlicePingKey)
    }
```

In `appBecameActive`, right after `endExtraTime()`:

```swift
        cancelPendingFirstSlicePing()
```

In `appEnteredBackground`, inside `if Self.cloudImportEnabled {`, right before `return`:

```swift
            scheduleFirstSlicePing()
```

- [ ] **Step 5: Build and launch headless**

Run Task 4's Step 4 (app build only) and Step 5 commands again.
Expected: `** BUILD SUCCEEDED **`, then `1`.

- [ ] **Step 6: Commit**

```bash
git add App/Sources/PipelineCenter.swift App/Sources/TikTokBrainApp.swift
git commit -m "feat(import): a timed ping when the newest saves should be sorted, cancelled if Stash reopens first"
```

---

### Task 6: Whole-branch check

**Files:** none changed.

- [ ] **Step 1: Run every layer**

```bash
cd services/webhook && uv run --with-requirements requirements.txt --with pytest --with cryptography python -m pytest -q 2>&1 | tail -2
```
Expected: `N passed`, 0 failed.

```bash
cd TikTokBrainKit && swift test 2>&1 | grep -E "Executed .* tests|Test run with .* tests"
```
Expected: both lines report 0 failures.

- [ ] **Step 2: Confirm the diff is only this feature**

```bash
git diff --stat $(git merge-base HEAD feat/clef-onboarding)..HEAD
```
Expected: exactly these 11 files: `cloud_import_store.py`, `cloud_import_queue.py`, `cloud_import_api.py`, `cloud_import_worker.py`, their 3 test files, `CloudImport.swift`, `ImportView.swift`, `PipelineCenter.swift`, `TikTokBrainApp.swift` — 12 with the plan doc if it was committed here.

- [ ] **Step 3: Report, do not deploy**

Report the three outputs above. The server change needs `services/webhook/deploy.sh` (manual, owner's go-ahead); imports created before the deploy keep draining unsliced.
