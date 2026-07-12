from datetime import datetime, timezone

import pytest
from fastapi.testclient import TestClient

import cloud_import_api
from app import app
from cloud_import_models import (
    CreateImportResponse,
    ImportState,
    ImportStatus,
    Progress,
    ResultPage,
    VideoResult,
)
from cloud_import_store import CreateImportResult


class FakeQueue:
    def __init__(self):
        self.messages = []

    def enqueue(self, import_id, video_id):
        self.messages.append({"importID": import_id, "videoID": video_id, "stage": "fast_pass"})


class FakeStore:
    def __init__(self):
        self.imports = {}
        self.calls = 0

    def create_import(self, request):
        key = str(request.client_import_id)
        if key in self.imports:
            return CreateImportResult(self.imports[key][0], False, len(request.videos))
        self.calls += 1
        import_id = f"import-{self.calls}"
        self.imports[key] = (import_id, request)
        return CreateImportResult(import_id, True, len(request.videos))

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
    app.dependency_overrides[cloud_import_api.get_store] = lambda: store
    app.dependency_overrides[cloud_import_api.get_queue] = lambda: queue
    cloud_import_api.API_TOKEN = "test-token"
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
        response = client.post("/v1/imports", headers={"Authorization": "Bearer test-token"}, json=payload())

    assert response.status_code == 202
    assert response.json()["state"] == "accepted"
    assert fake_queue.messages == [
        {"importID": response.json()["importID"], "videoID": "1", "stage": "fast_pass"},
        {"importID": response.json()["importID"], "videoID": "2", "stage": "fast_pass"},
    ]


def test_submit_is_idempotent(dependencies):
    _, fake_queue = dependencies
    with TestClient(app) as client:
        first = client.post("/v1/imports", headers={"Authorization": "Bearer test-token"}, json=payload())
        second = client.post("/v1/imports", headers={"Authorization": "Bearer test-token"}, json=payload())

    assert second.status_code == 202
    assert second.json()["importID"] == first.json()["importID"]
    assert len(fake_queue.messages) == 2


def test_auth_and_validation_are_enforced(dependencies):
    with TestClient(app) as client:
        assert client.post("/v1/imports", json=payload()).status_code == 401
        invalid = payload()
        invalid["videos"][0]["url"] = "https://evil.test/video/1"
        assert client.post("/v1/imports", headers={"Authorization": "Bearer test-token"}, json=invalid).status_code == 422


def test_status_and_results_routes(dependencies):
    store, _ = dependencies
    with TestClient(app) as client:
        created = client.post("/v1/imports", headers={"Authorization": "Bearer test-token"}, json=payload()).json()
        status = client.get(f"/v1/imports/{created['importID']}", headers={"Authorization": "Bearer test-token"})
        results = client.get(f"/v1/imports/{created['importID']}/results", headers={"Authorization": "Bearer test-token"})

    assert status.status_code == 200
    assert status.json()["fastPass"] == {"done": 1, "total": 2}
    assert results.status_code == 200
    assert [item["videoID"] for item in results.json()["results"]] == ["1", "2"]
