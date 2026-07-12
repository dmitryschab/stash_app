from datetime import datetime, timezone

import pytest
from pydantic import ValidationError

from cloud_import_models import BookmarkInput, CreateImportRequest


def test_accepts_canonical_tiktok_url():
    item = BookmarkInput(
        videoID="7651237687638101270",
        url="https://www.tiktok.com/@x/video/7651237687638101270",
        bookmarkedAt=datetime.now(timezone.utc),
    )
    assert item.videoID in item.url


@pytest.mark.parametrize(
    "url",
    [
        "http://www.tiktok.com/@x/video/1",
        "https://evil.test/video/1",
        "file:///etc/passwd",
    ],
)
def test_rejects_non_allowlisted_url(url):
    with pytest.raises(ValidationError):
        BookmarkInput(videoID="1", url=url, bookmarkedAt=datetime.now(timezone.utc))


def test_rejects_canonical_url_with_different_video_id():
    with pytest.raises(ValidationError):
        BookmarkInput(
            videoID="1",
            url="https://www.tiktok.com/@x/video/2",
            bookmarkedAt=datetime.now(timezone.utc),
        )


def test_rejects_non_numeric_video_id():
    with pytest.raises(ValidationError):
        BookmarkInput(
            videoID="not-a-video",
            url="https://vm.tiktok.com/ZM123/",
            bookmarkedAt=datetime.now(timezone.utc),
        )


def test_rejects_more_than_50_items():
    item = {
        "videoID": "1",
        "url": "https://www.tiktok.com/@x/video/1",
        "bookmarkedAt": "2026-07-01T00:00:00Z",
    }
    with pytest.raises(ValidationError):
        CreateImportRequest(
            clientImportID="11111111-1111-4111-8111-111111111111",
            videos=[item] * 51,
        )


def test_rejects_duplicate_video_ids():
    item = {
        "videoID": "1",
        "url": "https://www.tiktok.com/@x/video/1",
        "bookmarkedAt": "2026-07-01T00:00:00Z",
    }
    with pytest.raises(ValidationError):
        CreateImportRequest(
            clientImportID="11111111-1111-4111-8111-111111111111",
            videos=[item, item],
        )
