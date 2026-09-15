import json
from types import SimpleNamespace

import pytest

import cloud_import_pipeline
from cloud_import_models import VideoResult
from cloud_import_worker import HandleResult, PipelineError, handle_message, run_forever


class FakeQueue:
    def __init__(self):
        self.deleted = []
        self.extended = []

    def delete(self, receipt_handle):
        self.deleted.append(receipt_handle)

    def extend_visibility(self, receipt_handle, timeout_seconds=300):
        self.extended.append((receipt_handle, timeout_seconds))


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


def message(**overrides):
    return {
        "v": 2,
        "userID": "user-a",
        "importID": "import-1",
        "videoID": "123",
        "stage": "fast_pass",
        "url": "https://www.tiktok.com/@x/video/123",
        "receiptHandle": "receipt-1",
        **overrides,
    }


def stores(store):
    """handle_message builds one store per message from the message's userID."""
    return lambda user_id: store


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


PHOTO_METADATA = {
    "id": "123",
    "description": "",
    "formats": [{"format_id": "audio", "vcodec": "none"}],
    "thumbnails": [{"id": "cover", "url": "https://cdn.test/x~tplv-photomode-image.jpeg"}],
    "track": "Age of Consent",
    "artist": "New Order",
}


def _page_html(slide_urls):
    """A TikTok post page as the box sees it: slides live only in the rehydration JSON."""
    data = {"__DEFAULT_SCOPE__": {"webapp.video-detail": {"itemInfo": {"itemStruct": {
        "imagePost": {"images": [{"imageURL": {"urlList": [url]}} for url in slide_urls]}}}}}}
    return ('<script id="__UNIVERSAL_DATA_FOR_REHYDRATION__" type="application/json">'
            + json.dumps(data) + "</script>")


def _run_photo_pass(monkeypatch, metadata, responses):
    """`responses` maps a URL (or a startswith prefix) to its faked requests.get response."""
    monkeypatch.setattr(
        cloud_import_pipeline.subprocess,
        "run",
        lambda *args, **kwargs: SimpleNamespace(returncode=0, stdout=json.dumps(metadata), stderr=""),
    )

    def fake_get(url, **_kwargs):
        for prefix, response in responses.items():
            if url.startswith(prefix):
                return response
        return SimpleNamespace(status_code=404, text="", content=b"")

    monkeypatch.setattr(cloud_import_pipeline.requests, "get", fake_get)
    seen = {}
    pipeline = cloud_import_pipeline.FastPassPipeline(
        analyzer=lambda payload: seen.update(payload) or {"category": "music", "title": "Albums"}
    )
    pipeline.process("https://www.tiktok.com/@x/video/123")
    return seen


def test_a_photo_post_url_is_rewritten_for_yt_dlp(monkeypatch):
    """TikTok shares a photo post as /photo/<id>. yt-dlp refuses that spelling outright, so
    every shared photo post failed as invalid_metadata before the analyzer ever ran."""
    seen = {}

    def run(args, **_kwargs):
        seen["url"] = args[-1]
        return SimpleNamespace(returncode=0, stdout=json.dumps(PHOTO_METADATA), stderr="")

    monkeypatch.setattr(cloud_import_pipeline.subprocess, "run", run)
    monkeypatch.setattr(cloud_import_pipeline.requests, "get",
                        lambda *a, **k: SimpleNamespace(status_code=404, text="", content=b""))
    result = cloud_import_pipeline.FastPassPipeline(
        analyzer=lambda _: {"category": "music"}
    ).process("https://www.tiktok.com/@soundhostage/photo/7678492109686476045")

    assert seen["url"] == "https://www.tiktok.com/@soundhostage/video/7678492109686476045"
    # The id has to survive the rewrite too — VIDEO_ID_RE used to miss /photo/ entirely.
    assert result.video_id == "7678492109686476045"


def test_a_photo_post_sends_every_slide_to_the_analyzer(monkeypatch):
    """An album-list slideshow keeps its list on the later slides — the cover is routinely a
    meme, and analysing it alone filed a seven-slide topster under comedy with no picks."""
    seen = _run_photo_pass(monkeypatch, PHOTO_METADATA, {
        "https://www.tiktok.com/": SimpleNamespace(
            status_code=200,
            text=_page_html(["https://cdn.test/s1.jpeg", "https://cdn.test/s2.jpeg",
                             "https://cdn.test/s3.jpeg"])),
        "https://cdn.test/s1.jpeg": SimpleNamespace(status_code=200, content=b"slide-1"),
        "https://cdn.test/s2.jpeg": SimpleNamespace(status_code=200, content=b"slide-2"),
        "https://cdn.test/s3.jpeg": SimpleNamespace(status_code=200, content=b"slide-3"),
    })
    assert seen["images"] == [b"slide-1", b"slide-2", b"slide-3"]


def test_slides_are_capped(monkeypatch):
    """Every slide is another ~250 KB into the vision call; a photo dump must not buy 35."""
    urls = [f"https://cdn.test/s{i}.jpeg" for i in range(20)]
    responses = {url: SimpleNamespace(status_code=200, content=f"slide-{i}".encode())
                 for i, url in enumerate(urls)}
    responses["https://www.tiktok.com/"] = SimpleNamespace(status_code=200, text=_page_html(urls))
    seen = _run_photo_pass(monkeypatch, PHOTO_METADATA, responses)
    assert len(seen["images"]) == cloud_import_pipeline.PHOTO_SLIDES_MAX


def test_a_shell_page_falls_back_to_the_cover(monkeypatch):
    """TikTok serves the box a shell page for some posts; the yt-dlp cover is still one
    real slide, which beats a text-only analysis."""
    seen = _run_photo_pass(monkeypatch, PHOTO_METADATA, {
        "https://www.tiktok.com/": SimpleNamespace(status_code=200, text="<html>login</html>"),
        "https://cdn.test/x~tplv-photomode-image.jpeg":
            SimpleNamespace(status_code=200, content=b"cover-bytes"),
    })
    assert seen["images"] == [b"cover-bytes"]


def test_an_unreachable_photo_image_still_analyses(monkeypatch):
    """TikTok's signed photomode URLs 404 often; a miss falls back to caption-only rather
    than failing the video."""
    seen = _run_photo_pass(monkeypatch, PHOTO_METADATA, {})
    assert "images" not in seen


def test_a_real_video_fetches_no_image(monkeypatch):
    metadata = dict(PHOTO_METADATA, formats=[{"format_id": "0", "vcodec": "h264"}])
    seen = _run_photo_pass(monkeypatch, metadata, {
        "https://www.tiktok.com/": SimpleNamespace(
            status_code=200, text=_page_html(["https://cdn.test/s1.jpeg"])),
        "https://cdn.test/s1.jpeg": SimpleNamespace(status_code=200, content=b"slide-1"),
    })
    assert "images" not in seen


def test_duplicate_delivery_does_not_call_provider():
    store = FakeStore(claimed=False)
    queue = FakeQueue()
    pipeline = SimpleNamespace(process=lambda *_args: pytest.fail("provider called"))

    result = handle_message(message(), stores(store), pipeline, queue)

    assert result == HandleResult(deleted=True, retryable=False)
    assert queue.deleted == ["receipt-1"]


def test_running_duplicate_is_left_for_redelivery():
    store = FakeStore(claimed=False)
    store.get_video = lambda *_args: {"state": "running", "url": "https://www.tiktok.com/@x/video/123"}
    queue = FakeQueue()
    pipeline = SimpleNamespace(process=lambda *_args: pytest.fail("provider called"))

    result = handle_message(message(), stores(store), pipeline, queue)

    assert result == HandleResult(deleted=False, retryable=True)
    assert queue.deleted == []


def test_transient_failure_keeps_message_for_retry():
    store = FakeStore()
    queue = FakeQueue()
    pipeline = SimpleNamespace(process=lambda *_args: (_ for _ in ()).throw(PipelineError("429", True, "provider_429")))

    result = handle_message(message(), stores(store), pipeline, queue)

    assert result == HandleResult(deleted=False, retryable=True)
    assert store.failed == [(True, "provider_429")]
    assert queue.deleted == []


def test_hard_failure_is_recorded_and_deleted():
    store = FakeStore()
    queue = FakeQueue()
    pipeline = SimpleNamespace(process=lambda *_args: (_ for _ in ()).throw(PipelineError("bad", False, "invalid_output")))

    result = handle_message(message(), stores(store), pipeline, queue)

    assert result == HandleResult(deleted=True, retryable=False)
    assert store.failed == [(False, "invalid_output")]
    assert queue.deleted == ["receipt-1"]


def test_success_deletes_only_after_store_completion():
    store = FakeStore()
    queue = FakeQueue()
    pipeline = SimpleNamespace(process=lambda *_args: VideoResult(videoID="123", title="Saved"))

    result = handle_message(message(), stores(store), pipeline, queue)

    assert result == HandleResult(deleted=True, retryable=False)
    assert len(store.completed_results) == 1
    assert queue.deleted == ["receipt-1"]
    assert queue.extended == [("receipt-1", 300)]


def test_the_message_decides_which_users_store_is_written():
    seen = []
    queue = FakeQueue()
    pipeline = SimpleNamespace(process=lambda *_args: VideoResult(videoID="123"))

    def store_for(user_id):
        seen.append(user_id)
        return FakeStore()

    handle_message(message(userID="user-b"), store_for, pipeline, queue)
    assert seen == ["user-b"]


@pytest.mark.parametrize("bad", [
    {"v": 1},                 # pre-cutover message, no owning user
    {"userID": None},         # v2 shape but unusable
    {"stage": "slow_pass"},
    {"importID": None},
])
def test_unusable_messages_are_dropped_not_retried(bad):
    # Raising here would burn all five redeliveries into the dead-letter queue for every
    # message still in flight at cutover.
    queue = FakeQueue()
    pipeline = SimpleNamespace(process=lambda *_args: pytest.fail("provider called"))

    def store_for(_user_id):
        pytest.fail("store built for an unusable message")

    result = handle_message(message(**bad), store_for, pipeline, queue)

    assert result == HandleResult(deleted=True, retryable=False)
    assert queue.deleted == ["receipt-1"]


def test_a_job_for_a_deleted_account_is_dropped():
    # The partition is gone, so the claim fails and there is no video row to look at.
    store = FakeStore(claimed=False)
    store.get_video = lambda *_args: None
    queue = FakeQueue()
    pipeline = SimpleNamespace(process=lambda *_args: pytest.fail("provider called"))

    result = handle_message(message(), stores(store), pipeline, queue)

    assert result == HandleResult(deleted=True, retryable=False)
    assert queue.deleted == ["receipt-1"]


def test_unexpected_exception_is_retried_not_buried():
    """A stray exception (no HTTP status) must stay in the queue for redelivery — the
    attempt budget in fail_video bounds it. Marking it terminally failed created rows
    that no retry and no re-import could ever repair."""
    store = FakeStore()
    queue = FakeQueue()
    pipeline = SimpleNamespace(process=lambda *_args: (_ for _ in ()).throw(RuntimeError("boom")))

    result = handle_message(message(), stores(store), pipeline, queue)

    assert result == HandleResult(deleted=False, retryable=True)
    assert store.failed == [(True, "worker_error")]
    assert queue.deleted == []


def test_provider_4xx_is_still_terminal():
    """A definite client-side provider error (e.g. 403) keeps failing the same way on
    every retry — it must settle immediately, not burn the attempt budget."""
    store = FakeStore()
    queue = FakeQueue()
    error = RuntimeError("denied")
    error.response = SimpleNamespace(status_code=403)
    pipeline = SimpleNamespace(process=lambda *_args: (_ for _ in ()).throw(error))

    result = handle_message(message(), stores(store), pipeline, queue)

    assert result == HandleResult(deleted=True, retryable=False)
    assert store.failed == [(False, "provider_403")]
    assert queue.deleted == ["receipt-1"]


def test_run_forever_processes_a_batch_concurrently():
    import threading, time
    from threading import Event

    class BatchQueue(FakeQueue):
        def __init__(self):
            super().__init__()
            self.stop = Event()
        def receive(self, max_messages=1, wait_time_seconds=20):
            if self.stop.is_set():
                return []
            self.stop.set()
            assert max_messages == 4
            return [message(videoID=str(i), receiptHandle=f"r{i}") for i in range(4)]

    seen, lock = set(), threading.Lock()
    class SlowPipeline:
        def process(self, url):
            with lock:
                seen.add(threading.get_ident())
            time.sleep(0.2)
            return VideoResult(videoID="1")

    queue = BatchQueue()
    started = time.monotonic()
    run_forever(queue=queue, store_for=lambda _uid: FakeStore(), pipeline=SlowPipeline(),
                stop_event=queue.stop, concurrency=4)
    assert time.monotonic() - started < 0.6      # 4 × 0.2 s serially would be 0.8 s
    assert len(seen) > 1
    assert len(queue.deleted) == 4

def test_an_instagram_reel_keeps_its_shortcode_and_caption_hashtags(monkeypatch):
    """Instagram ids are shortcodes, not digits, and its metadata carries no `tags`."""
    metadata = {"id": "DBL2NCuMkAo", "description": "pasta night #recipe #dinner",
                "uploader": "cook", "formats": [{"vcodec": "h264"}]}
    monkeypatch.setattr(cloud_import_pipeline.subprocess, "run",
                        lambda *a, **k: SimpleNamespace(returncode=0, stdout=json.dumps(metadata), stderr=""))
    result = cloud_import_pipeline.FastPassPipeline(
        analyzer=lambda _: {"category": "recipe"}
    ).process("https://www.instagram.com/reel/DBL2NCuMkAo/")
    assert result.video_id == "DBL2NCuMkAo"
    assert result.hashtags == ["recipe", "dinner"]
