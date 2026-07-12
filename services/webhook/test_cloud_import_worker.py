import json
import subprocess
from types import SimpleNamespace

import pytest

import cloud_import_pipeline
from cloud_import_models import VideoResult
from cloud_import_worker import HandleResult, PipelineError, handle_message


class FakeQueue:
    def __init__(self):
        self.deleted = []

    def delete(self, receipt_handle):
        self.deleted.append(receipt_handle)


class FakeStore:
    def __init__(self, claimed=True, completed=True):
        self.claimed = claimed
        self.completed = completed
        self.failed = []
        self.completed_results = []

    def claim_video(self, import_id, video_id):
        return self.claimed

    def complete_video(self, import_id, result):
        self.completed_results.append(result)
        return self.completed

    def fail_video(self, import_id, video_id, retryable, code):
        self.failed.append((retryable, code))
        return True

    def get_video(self, import_id, video_id):
        return {"url": f"https://www.tiktok.com/@x/video/{video_id}"}


def message():
    return {
        "importID": "import-1",
        "videoID": "123",
        "stage": "fast_pass",
        "url": "https://www.tiktok.com/@x/video/123",
        "receiptHandle": "receipt-1",
    }


def test_fast_pass_maps_yt_dlp_metadata(monkeypatch):
    metadata = {
        "id": "123",
        "description": "caption",
        "tags": ["recipe", "quick"],
        "uploader": "creator",
        "thumbnail": "https://image.test/thumb.jpg",
        "duration": 42.5,
        "track": "Song",
        "artist": "Artist",
    }
    monkeypatch.setattr(
        cloud_import_pipeline.subprocess,
        "run",
        lambda *args, **kwargs: SimpleNamespace(returncode=0, stdout=json.dumps(metadata), stderr=""),
    )
    pipeline = cloud_import_pipeline.FastPassPipeline(
        analyzer=lambda payload: {"category": "recipe", "title": "Quick", "summary": "Do it", "topics": ["food"]}
    )

    result = pipeline.process("https://www.tiktok.com/@x/video/123")

    assert result.video_id == "123"
    assert result.caption == "caption"
    assert result.hashtags == ["recipe", "quick"]
    assert result.author == "creator"
    assert result.thumbnail_url == "https://image.test/thumb.jpg"
    assert result.duration == 42.5
    assert result.category == "recipe"


def test_empty_metadata_is_unavailable(monkeypatch):
    monkeypatch.setattr(
        cloud_import_pipeline.subprocess,
        "run",
        lambda *args, **kwargs: SimpleNamespace(returncode=0, stdout="{}", stderr=""),
    )
    result = cloud_import_pipeline.FastPassPipeline(analyzer=lambda _: {}).process(
        "https://www.tiktok.com/@x/video/123"
    )
    assert result.unavailable is True


def test_duplicate_delivery_does_not_call_provider():
    store = FakeStore(claimed=False)
    queue = FakeQueue()
    pipeline = SimpleNamespace(process=lambda *_args: pytest.fail("provider called"))

    result = handle_message(message(), store, pipeline, queue)

    assert result == HandleResult(deleted=True, retryable=False)
    assert queue.deleted == ["receipt-1"]


def test_transient_failure_keeps_message_for_retry():
    store = FakeStore()
    queue = FakeQueue()
    pipeline = SimpleNamespace(process=lambda *_args: (_ for _ in ()).throw(PipelineError("429", True, "provider_429")))

    result = handle_message(message(), store, pipeline, queue)

    assert result == HandleResult(deleted=False, retryable=True)
    assert store.failed == [(True, "provider_429")]
    assert queue.deleted == []


def test_hard_failure_is_recorded_and_deleted():
    store = FakeStore()
    queue = FakeQueue()
    pipeline = SimpleNamespace(process=lambda *_args: (_ for _ in ()).throw(PipelineError("bad", False, "invalid_output")))

    result = handle_message(message(), store, pipeline, queue)

    assert result == HandleResult(deleted=True, retryable=False)
    assert store.failed == [(False, "invalid_output")]
    assert queue.deleted == ["receipt-1"]


def test_success_deletes_only_after_store_completion():
    store = FakeStore()
    queue = FakeQueue()
    pipeline = SimpleNamespace(process=lambda *_args: VideoResult(videoID="123", title="Saved"))

    result = handle_message(message(), store, pipeline, queue)

    assert result == HandleResult(deleted=True, retryable=False)
    assert len(store.completed_results) == 1
    assert queue.deleted == ["receipt-1"]
