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


def test_accepts_data_export_share_url():
    """The only URL shape a real "Download your data" export produces."""
    item = BookmarkInput(
        videoID="7642061063495748894",
        url="https://www.tiktokv.com/share/video/7642061063495748894/",
        bookmarkedAt=datetime.now(timezone.utc),
    )
    assert item.videoID == "7642061063495748894"


def test_rejects_share_url_with_different_video_id():
    with pytest.raises(ValidationError):
        BookmarkInput(
            videoID="1",
            url="https://www.tiktokv.com/share/video/2/",
            bookmarkedAt=datetime.now(timezone.utc),
        )


@pytest.mark.parametrize(
    "url",
    [
        "http://www.tiktok.com/@x/video/1",
        "https://evil.tiktokv.com.attacker.test/share/video/1/",
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


def test_accepts_whole_library_and_rejects_beyond_cap():
    def item(index):
        return {
            "videoID": str(index),
            "url": f"https://www.tiktok.com/@x/video/{index}",
            "bookmarkedAt": "2026-07-01T00:00:00Z",
        }

    # A 900-video library imports in one request.
    ok = CreateImportRequest(
        clientImportID="11111111-1111-4111-8111-111111111111",
        videos=[item(i) for i in range(1, 901)],
    )
    assert len(ok.videos) == 900

    # Beyond the 1200 cap is still rejected.
    with pytest.raises(ValidationError):
        CreateImportRequest(
            clientImportID="11111111-1111-4111-8111-111111111111",
            videos=[item(i) for i in range(1, 1202)],
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


def test_result_revision_supersedes_broken_extractor_rows():
    """Libraries imported against the stale yt-dlp hold revision-1 "unavailable" rows, and the
    client only applies a strictly greater revision — so fresh results must not be revision 1."""
    from cloud_import_models import VideoResult

    assert VideoResult(videoID="1").analysis_revision > 1


def test_result_carries_recipe_and_music():
    """Cook and Music filter on these objects, not on category — a result without them leaves
    both walls empty however many saves the category holds."""
    from cloud_import_models import VideoResult

    result = VideoResult.model_validate({
        "videoID": "1",
        "category": "recipe",
        "recipe": {"name": "Focaccia", "ingredients": ["flour"], "steps": ["bake"]},
    })
    assert result.recipe.name == "Focaccia"
    assert result.recipe.ingredients == ["flour"]

    picks = VideoResult.model_validate({
        "videoID": "2",
        "category": "music",
        "music": [{"kind": "album", "title": "Blue", "artist": "Joni Mitchell"},
                  {"kind": "track", "title": "River"}],
    })
    assert [p.title for p in picks.music] == ["Blue", "River"]
    assert picks.music[1].artist == ""  # never guessed


def test_music_picks_are_bounded_and_title_checked():
    from cloud_import_models import MAX_MUSIC_PICKS, VideoResult

    result = VideoResult.model_validate({
        "videoID": "3",
        "music": [{"title": ""}, {"title": "   "}] + [{"title": f"t{i}"} for i in range(20)],
    })
    assert len(result.music) == MAX_MUSIC_PICKS
    assert all(p.title.strip() for p in result.music)


def test_result_without_structure_omits_both_keys():
    """A non-recipe, non-music save must not carry empty scaffolding to the client."""
    from cloud_import_models import VideoResult

    result = VideoResult(videoID="4", category="comedy")
    assert result.recipe is None
    assert result.music == []


def test_buys_ride_along_with_any_category():
    """Haul is a query, not a segment: a style save carries picks just like a haul does."""
    from cloud_import_models import VideoResult

    result = VideoResult.model_validate({
        "videoID": "5",
        "category": "style",
        "buys": [{"name": "Levi's 501 '93", "kind": "jeans", "price": "€110"},
                 {"name": "Uniqlo U crew tee"}],
    })
    assert [b.name for b in result.buys] == ["Levi's 501 '93", "Uniqlo U crew tee"]
    assert result.buys[1].price == ""  # never estimated


def test_buys_are_bounded_and_name_checked():
    from cloud_import_models import MAX_BUY_PICKS, VideoResult

    result = VideoResult.model_validate({
        "videoID": "6",
        "buys": [{"name": ""}, {"name": "   "}] + [{"name": f"item {i}"} for i in range(20)],
    })
    assert len(result.buys) == MAX_BUY_PICKS
    assert all(b.name.strip() for b in result.buys)
