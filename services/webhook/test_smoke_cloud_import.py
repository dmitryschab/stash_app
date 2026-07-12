import pytest

from smoke_cloud_import import validate_bookmarks, validate_release_gate


def bookmark(video_id):
    return {
        "videoID": str(video_id),
        "url": f"https://www.tiktok.com/@x/video/{video_id}",
        "bookmarkedAt": "2026-07-01T00:00:00Z",
    }


def test_smoke_requires_exactly_50_unique_bookmarks():
    with pytest.raises(ValueError):
        validate_bookmarks([bookmark(index) for index in range(49)])
    with pytest.raises(ValueError):
        validate_bookmarks([bookmark(index) for index in range(50)] + [bookmark(1)])


def test_release_gate_requires_50_unique_results():
    status = {"state": "completed", "fastPass": {"done": 50, "total": 50}}
    assert validate_release_gate(status, [{"videoID": str(index)} for index in range(50)]) is True
    with pytest.raises(RuntimeError):
        validate_release_gate(status, [{"videoID": "1"}] * 50)
