"""Contracts and validation for the first asynchronous cloud-import slice."""

from __future__ import annotations

import re
from datetime import datetime
from enum import StrEnum
from urllib.parse import urlsplit
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator


ALLOWED_TIKTOK_HOSTS = {
    "www.tiktok.com",
    "tiktok.com",
    "vm.tiktok.com",
    "vt.tiktok.com",
    # "Download your data" writes every favourite as https://www.tiktokv.com/share/video/<id>/,
    # never the canonical @user/video form. Leaving these off the allowlist 422'd whole-library
    # imports at the first row — a real export is 100% tiktokv.com.
    "www.tiktokv.com",
    "tiktokv.com",
}
CANONICAL_VIDEO_PATH = re.compile(r"^(?:/@[^/]+)?/(?:share/)?video/(\d+)(?:/)?$")


def validate_tiktok_url(url: str) -> str:
    """Validate a TikTok URL before it is handed to a network-facing worker."""
    parsed = urlsplit(url)
    hostname = (parsed.hostname or "").lower().rstrip(".")
    if parsed.scheme != "https" or hostname not in ALLOWED_TIKTOK_HOSTS:
        raise ValueError("URL must use an allowlisted TikTok HTTPS host")
    if parsed.username or parsed.password or parsed.port:
        raise ValueError("TikTok URL must not contain credentials or a custom port")
    if not parsed.path or parsed.path == "/":
        raise ValueError("TikTok URL must contain a video path")
    return url


class ImportState(StrEnum):
    ACCEPTED = "accepted"
    FAST_PASS = "fast_pass"
    COMPLETED = "completed"
    CANCELLED = "cancelled"


class VideoState(StrEnum):
    QUEUED = "queued"
    RUNNING = "running"
    COMPLETED = "completed"
    RETRYABLE = "retryable"
    UNAVAILABLE = "unavailable"
    FAILED = "failed"


class ContractModel(BaseModel):
    model_config = ConfigDict(extra="forbid", populate_by_name=True)


class BookmarkInput(ContractModel):
    video_id: str = Field(alias="videoID", min_length=1)
    url: str
    bookmarked_at: datetime = Field(alias="bookmarkedAt")

    @property
    def videoID(self) -> str:  # noqa: N802 - public wire-contract spelling
        return self.video_id

    @field_validator("video_id")
    @classmethod
    def numeric_video_id(cls, value: str) -> str:
        if not value.isdigit():
            raise ValueError("videoID must be numeric")
        return value

    @field_validator("url")
    @classmethod
    def allowlisted_url(cls, value: str) -> str:
        return validate_tiktok_url(value)

    @model_validator(mode="after")
    def matching_canonical_id(self) -> BookmarkInput:
        parsed = urlsplit(self.url)
        match = CANONICAL_VIDEO_PATH.fullmatch(parsed.path)
        if match and match.group(1) != self.video_id:
            raise ValueError("videoID does not match the canonical TikTok URL")
        return self


class CreateImportRequest(ContractModel):
    client_import_id: UUID = Field(alias="clientImportID")
    # Whole-library imports: the spec allows up to 1200 videos per import. Larger
    # libraries need client-side chunking (not built yet — YAGNI until someone hits it).
    videos: list[BookmarkInput] = Field(min_length=1, max_length=1200)

    @model_validator(mode="after")
    def unique_video_ids(self) -> CreateImportRequest:
        ids = [video.video_id for video in self.videos]
        if len(ids) != len(set(ids)):
            raise ValueError("videos must not contain duplicate videoID values")
        return self


# Hard per-user budget. The initial import allowance is spent first; only once it is gone
# does the monthly allowance drain. Enforced server-side — the in-app counter mirrors this
# state, it is never the source of it.
INITIAL_LIMIT = 500
MONTH_LIMIT = 100


class Quota(ContractModel):
    """The per-user import budget, echoed on every quota-consuming response so the
    in-app counter stays fresh without a second round trip."""

    initial_remaining: int = Field(alias="initialRemaining")
    month_remaining: int = Field(alias="monthRemaining")
    month_reset_at: int = Field(alias="monthResetAt")
    initial_limit: int = Field(alias="initialLimit", default=INITIAL_LIMIT)
    month_limit: int = Field(alias="monthLimit", default=MONTH_LIMIT)


class CreateImportResponse(ContractModel):
    import_id: str = Field(alias="importID")
    state: ImportState
    accepted: int
    # Submitted videos that did not fit in the remaining budget. Non-zero means truncated,
    # not failed: the client says "500 of 720 imported, 220 waiting until <monthResetAt>"
    # and re-submits the rest as a fresh import once the month rolls over.
    deferred: int = 0
    duplicates: int
    quota: Quota


class Progress(ContractModel):
    done: int
    total: int


class ImportStatus(ContractModel):
    import_id: str = Field(alias="importID")
    state: ImportState
    fast_pass: Progress = Field(alias="fastPass")
    unavailable: int
    partial_failures: int = Field(alias="partialFailures")
    # Repeated here, not only on the create response: a client that was killed mid-import
    # comes back polling status, and "done 500 of 500" with no deferred count would look
    # like the whole library landed.
    deferred: int = 0
    estimated_cost_usd: float = Field(alias="estimatedCostUSD")
    updated_at: datetime = Field(alias="updatedAt")


class RecipeData(ContractModel):
    name: str = ""
    ingredients: list[str] = Field(default_factory=list)
    steps: list[str] = Field(default_factory=list)


class MusicPick(ContractModel):
    """One release a video recommends. `artist` is empty rather than guessed — a guessed
    artist is how the wrong release gets linked on the client."""

    kind: str = "track"
    title: str
    artist: str = ""


# No real recommendation video lists more than this, and an unbounded array is an unbounded
# number of iTunes lookups on the client. Mirrors MusicPick.maxPerVideo in the Kit.
MAX_MUSIC_PICKS = 12


class VideoResult(ContractModel):
    video_id: str = Field(alias="videoID")
    # Bumped 1 -> 2 when the stale-yt-dlp bug was fixed. The client upserter only applies a
    # result whose revision is strictly greater than the one already stored, so every library
    # that imported against the broken extractor holds revision-1 rows reading "Unavailable".
    # Leaving this at 1 would make re-importing a no-op for exactly those users. Bump this
    # again after any change that makes previously-stored results wrong.
    # 3: results now carry recipe and music, so rows analysed before that must be superseded.
    # 4: photo posts are read from their image. Every one imported before this holds a row
    # analysed from an empty caption and a backing track — usually the wrong single "release".
    # 5: revision 4 landed correct picks, and then the app's transcript pass overwrote them
    # with an analysis of the backing track's lyrics. Those saves sit at revision 4 with their
    # music gone and their category flipped, and the upserter only applies a strictly greater
    # revision — so without this bump a re-share is a no-op for exactly the people who hit it.
    # 6: taxonomy v6 splits film, dining and wellness out of "other" — 85 of the 330 videos the
    # 855-video validation run left in that bucket. Every one of them is stored with category
    # "other", which is now the wrong answer, and only a greater revision re-buckets them.
    analysis_revision: int = Field(alias="analysisRevision", default=6)
    author: str | None = None
    caption: str | None = None
    hashtags: list[str] = Field(default_factory=list)
    thumbnail_url: str | None = Field(default=None, alias="thumbnailURL")
    duration: float | None = None
    category: str | None = None
    title: str | None = None
    summary: str | None = None
    topics: list[str] = Field(default_factory=list)
    # The Cook and Music screens filter on these, not on `category` — a save with category
    # "recipe" and no recipe object never reaches the wall. Before they were carried here the
    # cloud pipeline could not populate either screen at all.
    recipe: RecipeData | None = None
    music: list[MusicPick] = Field(default_factory=list)
    unavailable: bool = False
    error_code: str | None = Field(default=None, alias="errorCode")

    @field_validator("music")
    @classmethod
    def bounded_picks(cls, value: list[MusicPick]) -> list[MusicPick]:
        return [pick for pick in value if pick.title.strip()][:MAX_MUSIC_PICKS]


class ResultPage(ContractModel):
    results: list[VideoResult]
    next_cursor: str | None = Field(default=None, alias="nextCursor")
