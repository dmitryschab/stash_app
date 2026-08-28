"""One-video caption-first enrichment pipeline."""

from __future__ import annotations

import json
import re
import subprocess
from typing import Callable

import requests
from pydantic import ValidationError

from api_v1 import YTDLP, analyze_metadata
from cloud_import_models import VideoResult


VIDEO_ID_RE = re.compile(r"/(?:video|photo)/(\d+)(?:/|$)")
_PHOTO_PATH_RE = re.compile(r"/photo/(\d+)")


def _canonical(url: str) -> str:
    """Rewrite a photo post's `/photo/<id>` path to `/video/<id>`.

    yt-dlp's TikTok extractor refuses `/photo/` outright — "Unsupported URL" — but serves the
    very same post under `/video/`. The app submits whatever TikTok's share sheet redirected
    to, and for a photo post that is always the `/photo/` spelling, so every shared photo post
    failed here as `invalid_metadata` before the analyzer ever saw it.
    """
    return _PHOTO_PATH_RE.sub(r"/video/\1", url, count=1)

# Bedrock takes the JPEG inline and a photomode image measures ~250 KB, so this is a sanity
# bound rather than a real limit — an image past it is dropped, not resized.
PHOTO_IMAGE_MAX_BYTES = 4_000_000


def _is_photo_post(metadata: dict) -> bool:
    """True for a TikTok photo post: a still (or a few) plus a backing track, no video.

    It exposes no video track, so `/tiktok/download/{id}` can never hand the app an mp4 and
    the on-device OCR pass never sees it. For the album-grid posts that fill the music side of
    TikTok, every release named in the post lives in its pixels and nowhere else — the caption
    is empty and the only sound is somebody else's song.
    """
    formats = metadata.get("formats") or []
    return bool(formats) and all(fmt.get("vcodec") == "none" for fmt in formats)


def _photo_image(metadata: dict) -> bytes | None:
    """The photo post's own picture, or None when TikTok will not serve it.

    Best-effort on purpose. TikTok's signed photomode URLs 404 for a sizeable share of posts
    — two of five measured across one account, and confirmed from the box itself, so it is the
    signature going stale rather than anything local. A miss falls through to a text-only
    analysis that at least knows it is looking at a photo post.
    """
    for thumbnail in metadata.get("thumbnails") or []:
        url = thumbnail.get("url") or ""
        if "photomode" not in url:
            continue
        try:
            response = requests.get(url, timeout=30)
        except requests.RequestException:
            continue
        if response.status_code == 200 and 0 < len(response.content) <= PHOTO_IMAGE_MAX_BYTES:
            return response.content
    return None


class PipelineError(Exception):
    def __init__(self, message: str, retryable: bool, code: str):
        super().__init__(message)
        self.retryable = retryable
        self.code = code


def _provider_error(error: Exception) -> PipelineError:
    response = getattr(error, "response", None)
    status = getattr(response, "status_code", None)
    retryable = isinstance(error, (requests.Timeout, requests.ConnectionError)) or status == 429 or (status is not None and status >= 500)
    return PipelineError(str(error), retryable, f"provider_{status}" if status else "provider_error")


class FastPassPipeline:
    def __init__(self, analyzer: Callable[[dict], dict] | None = None):
        self.analyzer = analyzer or analyze_metadata

    def _metadata(self, url: str) -> dict | None:
        try:
            completed = subprocess.run(
                [YTDLP, "--dump-single-json", "--skip-download", "--no-warnings", "--socket-timeout", "30", url],
                capture_output=True,
                text=True,
                timeout=90,
            )
        except subprocess.TimeoutExpired as error:
            raise PipelineError("yt-dlp timed out", True, "metadata_timeout") from error
        if completed.returncode != 0 or not completed.stdout.strip():
            return None
        try:
            metadata = json.loads(completed.stdout)
        except json.JSONDecodeError as error:
            raise PipelineError("yt-dlp returned invalid JSON", False, "invalid_metadata") from error
        return metadata if isinstance(metadata, dict) and metadata else None

    def process(self, url: str, video_id: str | None = None) -> VideoResult:
        url = _canonical(url)
        match = VIDEO_ID_RE.search(url)
        resolved_id = video_id or (match.group(1) if match else None)
        metadata = self._metadata(url)
        if not metadata:
            if not resolved_id:
                raise PipelineError("video ID missing from unavailable metadata", False, "invalid_metadata")
            return VideoResult(videoID=resolved_id, unavailable=True, errorCode="unavailable")
        resolved_id = resolved_id or str(metadata.get("id") or "")
        if not resolved_id.isdigit():
            raise PipelineError("video ID missing from metadata", False, "invalid_metadata")

        payload = {
            "caption": metadata.get("description") or "",
            "hashtags": metadata.get("tags") or [],
            "author": metadata.get("uploader") or metadata.get("channel") or "",
            "thumbnailURL": metadata.get("thumbnail"),
            "duration": metadata.get("duration"),
            "track": metadata.get("track") or "",
            "artist": metadata.get("artist") or "",
        }
        if _is_photo_post(metadata):
            # Flagged even when the picture cannot be fetched: without it the prompt's only
            # line is the backing track, and the model dutifully recommends somebody else's
            # song as the thing the post was about.
            payload["isPhotoPost"] = True
            image = _photo_image(metadata)
            if image:
                payload["image"] = image
        try:
            analysis = self.analyzer(payload) or {}
        except PipelineError:
            raise
        except (requests.RequestException, TimeoutError) as error:
            raise _provider_error(error) from error
        except Exception as error:
            raise PipelineError("analyzer failed", False, "analysis_failed") from error

        try:
            return VideoResult(
                videoID=resolved_id,
                author=payload["author"] or None,
                caption=payload["caption"] or None,
                hashtags=[str(tag) for tag in payload["hashtags"]],
                thumbnailURL=payload["thumbnailURL"],
                duration=payload["duration"],
                category=analysis.get("category"),
                title=analysis.get("title"),
                summary=analysis.get("summary"),
                topics=analysis.get("topics") or [],
                recipe=analysis.get("recipe") or None,
                music=analysis.get("music") or [],
            )
        except (ValidationError, TypeError, ValueError) as error:
            raise PipelineError("analysis output failed validation", False, "invalid_output") from error
