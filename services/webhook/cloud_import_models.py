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
}
CANONICAL_VIDEO_PATH = re.compile(r"^/@[^/]+/video/(\d+)(?:/)?$")


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


class CreateImportResponse(ContractModel):
    import_id: str = Field(alias="importID")
    state: ImportState
    accepted: int
    duplicates: int


class Progress(ContractModel):
    done: int
    total: int


class ImportStatus(ContractModel):
    import_id: str = Field(alias="importID")
    state: ImportState
    fast_pass: Progress = Field(alias="fastPass")
    unavailable: int
    partial_failures: int = Field(alias="partialFailures")
    estimated_cost_usd: float = Field(alias="estimatedCostUSD")
    updated_at: datetime = Field(alias="updatedAt")


class VideoResult(ContractModel):
    video_id: str = Field(alias="videoID")
    analysis_revision: int = Field(alias="analysisRevision", default=1)
    author: str | None = None
    caption: str | None = None
    hashtags: list[str] = Field(default_factory=list)
    thumbnail_url: str | None = Field(default=None, alias="thumbnailURL")
    duration: float | None = None
    category: str | None = None
    title: str | None = None
    summary: str | None = None
    topics: list[str] = Field(default_factory=list)
    unavailable: bool = False
    error_code: str | None = Field(default=None, alias="errorCode")


class ResultPage(ContractModel):
    results: list[VideoResult]
    next_cursor: str | None = Field(default=None, alias="nextCursor")
