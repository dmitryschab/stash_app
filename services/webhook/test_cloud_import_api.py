from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient

import cloud_import_api
import stash_auth
from app import app
from cloud_import_models import (
    INITIAL_LIMIT,
    MONTH_LIMIT,
    ImportState,
    ImportStatus,
    Progress,
    Quota,
    ResultPage,
    VideoResult,
)
from cloud_import_store import SLICE, CreateImportResult

USER_ID = "user-a"


class FakeQueue:
    def __init__(self):
        self.messages = []

    def enqueue(self, user_id, import_id, video_id, url=None):
        self.messages.append({"userID": user_id, "importID": import_id, "videoID": video_id,
                              "url": url, "stage": "fast_pass"})


class FakeStore:
    def __init__(self):
        self.imports = {}
        self.staged = {}  # importID -> [(videoID, url)] still waiting on a worker
        self.calls = 0
        self.user_id = USER_ID
        self.initial = INITIAL_LIMIT
        self.month = MONTH_LIMIT
        self.failures = {}  # videoID -> failed/unavailable rows already stored
        self.release_checks = []

    # -- quota
    def get_quota(self):
        # trialRemaining mirrors the initial bucket: this fake exists to drive the 402 path,
        # and a stub that leaves a free trial behind never reaches it.
        return Quota(trialRemaining=self.initial, initialRemaining=self.initial,
                     monthRemaining=self.month, monthResetAt=0)

    def reserve_quota(self, units):
        from_initial = min(self.initial, units)
        if units - from_initial > self.month:
            return None
        self.initial -= from_initial
        self.month -= units - from_initial
        return self.get_quota()

    def refund_quota(self, units):
        self.initial = min(INITIAL_LIMIT, self.initial + units)
        return self.get_quota()

    # -- imports
    def get_client_import(self, client_import_id):
        entry = self.imports.get(str(client_import_id))
        return {"importID": entry[0]} if entry else None

    def create_import(self, request, *, deferred=0):
        # Replays the *stored* accepted/deferred split like the real store does, so a retry
        # that resubmits the whole 720-video list still reports the 500 that were taken.
        key = str(request.client_import_id)
        if key in self.imports:
            return CreateImportResult(*self.imports[key])
        self.calls += 1
        import_id = f"import-{self.calls}"
        self.imports[key] = (import_id, False, len(request.videos), 0, deferred)
        self.staged[import_id] = [(video.video_id, video.url) for video in request.videos]
        return CreateImportResult(import_id, True, len(request.videos), deferred=deferred)

    def failure_counts(self, video_ids):
        return {video_id: count for video_id, count in self.failures.items() if video_id in video_ids}

    def pending_videos(self, import_id):
        # No worker runs in these tests, so every staged row is still waiting.
        return self.staged.get(import_id, [])

    def claim_release(self, import_id):
        # Records the nudge; the real slice arithmetic is tested against the store.
        self.release_checks.append(import_id)
        return None

    def get_status(self, import_id):
        return ImportStatus(
            importID=import_id,
            state=ImportState.FAST_PASS,
            fastPass=Progress(done=1, total=2),
            unavailable=0,
            partialFailures=0,
            estimatedCostUSD=0,
            updatedAt=datetime.now(timezone.utc),
        )

    def list_results(self, import_id, cursor=None):
        return ResultPage(results=[VideoResult(videoID="1"), VideoResult(videoID="2")], nextCursor=None)


@pytest.fixture
def dependencies():
    store = FakeStore()
    queue = FakeQueue()
    app.dependency_overrides[stash_auth.current_user] = lambda: USER_ID
    app.dependency_overrides[stash_auth.user_store] = lambda: store
    # The metered routes take `entitled_store`, not `user_store` — same object,
    # plus the subscription check. Overriding only one leaves the real one calling
    # Dynamo. The paywall has its own tests in test_stash_auth.py.
    app.dependency_overrides[stash_auth.entitled_store] = lambda: store
    app.dependency_overrides[cloud_import_api.get_queue] = lambda: queue
    yield store, queue
    app.dependency_overrides.clear()


def payload(count=2):
    return {
        "clientImportID": "11111111-1111-4111-8111-111111111111",
        "videos": [
            {
                "videoID": str(index),
                "url": f"https://www.tiktok.com/@x/video/{index}",
                "bookmarkedAt": "2026-07-01T00:00:00Z",
            }
            for index in range(1, count + 1)
        ],
    }


def test_submit_returns_before_processing(dependencies):
    _, fake_queue = dependencies
    with TestClient(app) as client:
        response = client.post("/v1/imports", json=payload())

    assert response.status_code == 202
    assert response.json()["state"] == "accepted"
    import_id = response.json()["importID"]
    assert fake_queue.messages == [
        {"userID": USER_ID, "importID": import_id, "videoID": "1",
         "url": "https://www.tiktok.com/@x/video/1", "stage": "fast_pass"},
        {"userID": USER_ID, "importID": import_id, "videoID": "2",
         "url": "https://www.tiktok.com/@x/video/2", "stage": "fast_pass"},
    ]


def test_submit_is_idempotent(dependencies):
    _, fake_queue = dependencies
    with TestClient(app) as client:
        first = client.post("/v1/imports", json=payload())
        second = client.post("/v1/imports", json=payload())

    assert second.status_code == 202
    assert second.json()["importID"] == first.json()["importID"]
    # One import, one charge — but the queue is driven again, because the retry is the only
    # thing that ever revisits a row the first call failed to enqueue.
    assert len(fake_queue.messages) == 4
    assert {message["videoID"] for message in fake_queue.messages} == {"1", "2"}


def test_validation_is_enforced(dependencies):
    with TestClient(app) as client:
        invalid = payload()
        invalid["videos"][0]["url"] = "https://evil.test/video/1"
        assert client.post("/v1/imports", json=invalid).status_code == 422


def test_status_and_results_routes(dependencies):
    with TestClient(app) as client:
        created = client.post("/v1/imports", json=payload()).json()
        status = client.get(f"/v1/imports/{created['importID']}")
        results = client.get(f"/v1/imports/{created['importID']}/results")

    assert status.status_code == 200
    assert status.json()["fastPass"] == {"done": 1, "total": 2}
    assert results.status_code == 200
    assert [item["videoID"] for item in results.json()["results"]] == ["1", "2"]


def test_one_unit_is_charged_per_video_and_echoed_back(dependencies):
    store, _ = dependencies
    with TestClient(app) as client:
        response = client.post("/v1/imports", json=payload(3))

    assert response.json()["quota"]["initialRemaining"] == INITIAL_LIMIT - 3
    assert store.initial == INITIAL_LIMIT - 3


def test_a_retry_is_not_charged_again(dependencies):
    store, _ = dependencies
    with TestClient(app) as client:
        client.post("/v1/imports", json=payload(3))
        retry = client.post("/v1/imports", json=payload(3))

    assert store.initial == INITIAL_LIMIT - 3
    assert retry.json()["quota"]["initialRemaining"] == INITIAL_LIMIT - 3


def test_only_an_empty_budget_returns_402_with_the_current_quota(dependencies):
    store, queue = dependencies
    store.initial = 0
    store.month = 0
    with TestClient(app) as client:
        response = client.post("/v1/imports", json=payload(2))

    assert response.status_code == 402
    # "detail" and "quota" are siblings at the top level, not nested under "detail".
    assert response.json() == {
        "detail": "quota exhausted",
        "quota": {"trialRemaining": 0, "trialLimit": 50,
                  "initialRemaining": 0, "monthRemaining": 0, "monthResetAt": 0,
                  "initialLimit": INITIAL_LIMIT, "monthLimit": MONTH_LIMIT},
    }
    assert queue.messages == []  # nothing was enqueued, so nothing gets processed


def test_an_oversized_first_import_is_partly_accepted_not_refused(dependencies):
    """The 720-video favourites library this product exists for. Refusing it whole left that
    user with no path in at all; now the newest 500 land and the rest come back as deferred."""
    store, queue = dependencies
    store.initial = 500
    store.month = 0
    with TestClient(app) as client:
        response = client.post("/v1/imports", json=payload(720))

    assert response.status_code == 202
    body = response.json()
    assert (body["accepted"], body["deferred"]) == (500, 220)
    assert body["quota"]["initialRemaining"] == 0
    # Charged for exactly what was taken; the newest slice of it is queued now, the rest as
    # that slice settles.
    assert store.initial == 0
    assert len(queue.messages) == SLICE
    assert [message["videoID"] for message in queue.messages[:3]] == ["1", "2", "3"]


def test_a_retry_of_a_truncated_import_charges_nothing_more(dependencies):
    store, queue = dependencies
    store.initial = 500
    store.month = 0
    with TestClient(app) as client:
        first = client.post("/v1/imports", json=payload(720))
        retry = client.post("/v1/imports", json=payload(720))

    assert retry.json()["importID"] == first.json()["importID"]
    assert (retry.json()["accepted"], retry.json()["deferred"]) == (500, 220)
    assert store.initial == 0  # nothing was taken the second time round
    # The retry re-drives whatever is still waiting rather than trusting the first call's
    # enqueue loop to have finished. This fake re-drives every staged row (the real store
    # keeps it to released slices — test_the_retry_redrive_sends_only_released_rows), so
    # the first slice plus all 500 go out; the worker drops the duplicates.
    assert len(queue.messages) == SLICE + 500
    assert {message["videoID"] for message in queue.messages} == {str(n) for n in range(1, 501)}


def test_a_failed_create_gives_the_units_back(dependencies):
    store, _ = dependencies

    def explode(_request, **_kwargs):
        raise RuntimeError("dynamo is down")

    store.create_import = explode
    with TestClient(app) as client, pytest.raises(RuntimeError):
        client.post("/v1/imports", json=payload(4))
    assert store.initial == INITIAL_LIMIT


def test_an_enqueue_that_dies_halfway_is_finished_by_the_retry(dependencies):
    """The units are charged and the rows staged before any message goes out, so an SQS
    failure on message 4 of 10 leaves six videos paid for and invisible — no worker will ever
    pick them up and the import can never finalize. The retry re-drives what is still waiting.
    """
    store, queue = dependencies
    live_enqueue = queue.enqueue

    def throttle_after_three(*args, **kwargs):
        if len(queue.messages) == 3:
            raise RuntimeError("sqs is throttling")
        live_enqueue(*args, **kwargs)

    queue.enqueue = throttle_after_three
    with TestClient(app) as client, pytest.raises(RuntimeError):
        client.post("/v1/imports", json=payload(10))
    assert [message["videoID"] for message in queue.messages] == ["1", "2", "3"]

    queue.enqueue = live_enqueue
    with TestClient(app) as client:
        retry = client.post("/v1/imports", json=payload(10))

    assert retry.status_code == 202
    assert store.initial == INITIAL_LIMIT - 10  # still charged exactly once
    assert {message["videoID"] for message in queue.messages} == {str(n) for n in range(1, 11)}


def test_resubmitting_a_failed_save_is_free_for_three_retries(dependencies):
    """A save the box failed on (spent provider credits, a TikTok blip) was already paid for.
    The app's Archive re-submits it; charging again would make every outage cost the user."""
    store, queue = dependencies
    store.failures = {"1": 1, "2": 3, "3": 4}   # 3 has used its free retries
    with TestClient(app) as client:
        response = client.post("/v1/imports", json=payload(4))

    assert response.status_code == 202
    assert response.json()["accepted"] == 4
    assert store.initial == INITIAL_LIMIT - 2   # only 3 (retries spent) and 4 (new) are charged
    assert len(queue.messages) == 4


def test_a_free_retry_goes_through_on_an_empty_budget(dependencies):
    store, queue = dependencies
    store.initial = 0
    store.month = 0
    store.failures = {"1": 1, "2": 1}
    with TestClient(app) as client:
        response = client.post("/v1/imports", json=payload(3))

    assert response.status_code == 202
    assert (response.json()["accepted"], response.json()["deferred"]) == (2, 1)
    assert [message["videoID"] for message in queue.messages] == ["1", "2"]


# ---------------------------------------------------------------- map pass

class InlinePool:
    """Runs each submission on the spot, so a test sees the map finished when the route returns."""
    def __init__(self):
        self.submitted = 0

    def submit(self, fn, *args):
        self.submitted += 1
        fn(*args)


class MapStore(FakeStore):
    def __init__(self):
        super().__init__()
        self.map = None

    def start_map(self, import_id, sampled):
        self.map = {"importID": import_id, "sampled": sampled, "done": 0, "counts": {}, "guesses": {}}

    def guess_video(self, import_id, video_id, category):
        self.map["done"] += 1
        self.map["counts"][category] = self.map["counts"].get(category, 0) + 1
        self.map["guesses"][video_id] = category

    def skip_map_video(self, import_id):
        self.map["done"] += 1


@pytest.fixture
def map_dependencies(monkeypatch):
    store = MapStore()
    queue = FakeQueue()
    pool = InlinePool()
    app.dependency_overrides[stash_auth.current_user] = lambda: USER_ID
    app.dependency_overrides[stash_auth.user_store] = lambda: store
    app.dependency_overrides[stash_auth.entitled_store] = lambda: store
    app.dependency_overrides[cloud_import_api.get_queue] = lambda: queue
    monkeypatch.setattr(cloud_import_api, "_MAP_POOL", pool)
    monkeypatch.setattr(cloud_import_api, "fetch_metadata",
                        lambda url: {"description": f"video {url.rsplit('/', 1)[1]} #linux", "tags": ["linux"]})
    monkeypatch.setattr(cloud_import_api.clef, "classify", lambda state: ("coding", 0.9))
    yield store, queue, pool
    app.dependency_overrides.clear()


def test_sample_is_evenly_spaced_and_capped():
    videos = list(range(300))
    sample = cloud_import_api.sample_for_map(videos)
    assert len(sample) == 60
    assert sample[:3] == [0, 5, 10]            # every fifth, from the first
    assert sample[-1] == 295
    assert cloud_import_api.sample_for_map(list(range(7))) == list(range(7))   # fewer than 60: all
    assert cloud_import_api.sample_for_map([]) == []


def test_a_new_import_starts_the_map_and_tallies_guesses(map_dependencies):
    store, queue, pool = map_dependencies
    with TestClient(app) as client:
        response = client.post("/v1/imports", json=payload(3))
    import_id = response.json()["importID"]
    assert pool.submitted == 3
    assert store.map == {"importID": import_id, "sampled": 3, "done": 3,
                         "counts": {"coding": 3}, "guesses": {"1": "coding", "2": "coding", "3": "coding"}}
    assert len(queue.messages) == 3           # the fast pass is untouched
    assert store.initial == INITIAL_LIMIT - 3  # the map charged nothing extra


def test_a_clef_failure_still_counts_as_done(map_dependencies, monkeypatch):
    store, _, _ = map_dependencies
    answers = iter([("coding", 0.9), None, ("recipe", 0.8)])
    monkeypatch.setattr(cloud_import_api.clef, "classify", lambda state: next(answers))
    with TestClient(app) as client:
        client.post("/v1/imports", json=payload(3))
    assert store.map["done"] == 3
    assert store.map["counts"] == {"coding": 1, "recipe": 1}


def test_missing_metadata_is_a_skip_not_a_crash(map_dependencies, monkeypatch):
    store, _, _ = map_dependencies
    monkeypatch.setattr(cloud_import_api, "fetch_metadata", lambda url: None)
    with TestClient(app) as client:
        client.post("/v1/imports", json=payload(2))
    assert store.map == {"importID": store.map["importID"], "sampled": 2, "done": 2, "counts": {}, "guesses": {}}


def test_a_retry_does_not_start_a_second_map(map_dependencies):
    store, _, pool = map_dependencies
    with TestClient(app) as client:
        client.post("/v1/imports", json=payload(2))
        client.post("/v1/imports", json=payload(2))
    assert pool.submitted == 2
    assert store.map["sampled"] == 2


def test_a_lost_create_race_with_free_retries_starts_no_second_map(map_dependencies, monkeypatch):
    store, _, pool = map_dependencies
    store.failures = {"1": 1, "2": 1}                                    # every video a free retry: nothing charged
    monkeypatch.setattr(store, "get_client_import", lambda cid: None)   # the race: the dedupe row is not visible yet
    with TestClient(app) as client:
        client.post("/v1/imports", json=payload(2))
        client.post("/v1/imports", json=payload(2))                     # create_import replays: created=False
    assert pool.submitted == 2
    assert store.map["sampled"] == 2


def test_the_map_fetches_the_canonical_url(map_dependencies, monkeypatch):
    seen = []
    monkeypatch.setattr(cloud_import_api, "fetch_metadata", lambda url: seen.append(url) or {"description": "x"})
    body = payload(1)
    body["videos"][0]["url"] = "https://www.tiktok.com/@x/photo/1"
    with TestClient(app) as client:
        client.post("/v1/imports", json=body)
    assert seen == ["https://www.tiktok.com/@x/video/1"]


def test_a_failing_store_write_is_logged_not_lost(map_dependencies, monkeypatch, caplog):
    store, _, _ = map_dependencies

    def boom(import_id, video_id, category):
        raise RuntimeError("dynamo down")

    monkeypatch.setattr(store, "guess_video", boom)
    with TestClient(app) as client, caplog.at_level("ERROR"):
        response = client.post("/v1/imports", json=payload(1))
    assert response.status_code == 202
    assert "map write failed" in caplog.text


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
