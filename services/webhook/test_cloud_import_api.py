from datetime import datetime, timezone

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
from cloud_import_store import CreateImportResult

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

    # -- quota
    def get_quota(self):
        return Quota(initialRemaining=self.initial, monthRemaining=self.month, monthResetAt=0)

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

    def pending_videos(self, import_id):
        # No worker runs in these tests, so every staged row is still waiting.
        return self.staged.get(import_id, [])

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
        "quota": {"initialRemaining": 0, "monthRemaining": 0, "monthResetAt": 0,
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
    # Charged for exactly what was taken, and only those videos are queued for processing.
    assert store.initial == 0
    assert len(queue.messages) == 500
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
    # enqueue loop to have finished. Here nothing has been claimed yet, so all 500 go again;
    # the worker drops the duplicates.
    assert len(queue.messages) == 1000
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
