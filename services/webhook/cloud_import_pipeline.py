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


VIDEO_ID_RE = re.compile(r"/video/(\d+)(?:/|$)")


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
            )
        except (ValidationError, TypeError, ValueError) as error:
            raise PipelineError("analysis output failed validation", False, "invalid_output") from error
