#!/usr/bin/env python3
"""Run the approved 50-video asynchronous import release gate."""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import uuid
from pathlib import Path

import requests

from cloud_import_models import BookmarkInput, CreateImportRequest


def validate_bookmarks(raw: list[dict]) -> list[BookmarkInput]:
    if not isinstance(raw, list):
        raise ValueError("bookmark input must be a JSON array")
    request = CreateImportRequest(clientImportID=uuid.uuid4(), videos=raw)
    if len(request.videos) != 50:
        raise ValueError("smoke input must contain exactly 50 videos")
    return request.videos


def validate_release_gate(status: dict, results: list[dict]) -> bool:
    fast_pass = status.get("fastPass", {})
    video_ids = [result.get("videoID") for result in results]
    if status.get("state") != "completed":
        raise RuntimeError("import did not complete")
    if fast_pass.get("done") != 50 or fast_pass.get("total") != 50:
        raise RuntimeError("import completed without 50 fast-pass videos")
    if len(results) != 50 or None in video_ids or len(set(video_ids)) != 50:
        raise RuntimeError("import did not return 50 unique results")
    return True


def _json_response(response: requests.Response, operation: str) -> dict:
    if not 200 <= response.status_code < 300:
        raise RuntimeError(f"{operation} failed with HTTP {response.status_code}")
    try:
        return response.json()
    except ValueError as error:
        raise RuntimeError(f"{operation} returned invalid JSON") from error


def fetch_results(session: requests.Session, base_url: str, token: str, import_id: str) -> list[dict]:
    results = []
    cursor = None
    seen_cursors = set()
    while True:
        params = {"cursor": cursor} if cursor else {}
        response = session.get(
            f"{base_url}/v1/imports/{import_id}/results",
            headers={"Authorization": f"Bearer {token}"},
            params=params,
            timeout=30,
        )
        page = _json_response(response, "results")
        results.extend(page.get("results", []))
        cursor = page.get("nextCursor")
        if not cursor:
            return results
        if cursor in seen_cursors:
            raise RuntimeError("results cursor did not advance")
        seen_cursors.add(cursor)


def run(base_url: str, token: str, bookmarks: list[dict], session: requests.Session | None = None) -> None:
    if not base_url or not token:
        raise ValueError("STASH_BASE_URL and STASH_API_TOKEN are required")
    videos = validate_bookmarks(bookmarks)
    session = session or requests.Session()
    base_url = base_url.rstrip("/")
    payload = {
        "clientImportID": str(uuid.uuid4()),
        "videos": [video.model_dump(by_alias=True, mode="json") for video in videos],
    }
    response = session.post(
        f"{base_url}/v1/imports",
        headers={"Authorization": f"Bearer {token}"},
        json=payload,
        timeout=30,
    )
    accepted = _json_response(response, "submission")
    import_id = accepted["importID"]
    deadline = time.monotonic() + 30 * 60
    previous = (-1, -1)
    while time.monotonic() < deadline:
        response = session.get(
            f"{base_url}/v1/imports/{import_id}",
            headers={"Authorization": f"Bearer {token}"},
            timeout=30,
        )
        status = _json_response(response, "status")
        progress = (status.get("fastPass", {}).get("done", 0), status.get("fastPass", {}).get("total", 0))
        if progress < previous:
            raise RuntimeError("status progress regressed")
        previous = progress
        print(f"state={status.get('state')} fast={progress[0]}/{progress[1]} unavailable={status.get('unavailable', 0)}", flush=True)
        if status.get("state") == "completed":
            results = fetch_results(session, base_url, token, import_id)
            validate_release_gate(status, results)
            print("release gate passed: 50 unique results", flush=True)
            return
        time.sleep(5)
    raise TimeoutError("import did not complete within 30 minutes")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Run the 50-video cloud import smoke gate")
    parser.add_argument("bookmarks", nargs="?", help="JSON array file; defaults to STASH_IMPORT_BOOKMARKS_FILE")
    args = parser.parse_args(argv)
    path = args.bookmarks or os.environ.get("STASH_IMPORT_BOOKMARKS_FILE")
    if not path:
        parser.error("provide a bookmarks JSON file or STASH_IMPORT_BOOKMARKS_FILE")
    try:
        raw = json.loads(Path(path).read_text())
        run(os.environ.get("STASH_BASE_URL", ""), os.environ.get("STASH_API_TOKEN", ""), raw)
    except (OSError, ValueError, RuntimeError, TimeoutError) as error:
        print(f"smoke failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
