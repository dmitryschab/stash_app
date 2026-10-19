"""Build the search scorecard's cache: every save's about-text and both vectors, once.

The scorecard (TikTokBrainKit/Tests/TikTokBrainKitTests/SearchScorecardTests.swift) ranks a real
library two ways — today's title-and-hashtag scorer and the about-text ranker — and model calls
have no place inside a unit test. So this writes everything the models answer to one JSON file,
and the test reads only that:

  {"saves":   [{"videoID", "bookmarkedAt", "about", "aboutVector", "aboutVersion",
                "legacy": {"title", "topics", "caption", "summary", "transcript"},
                "legacyVector", "aboutMeta"}],
   "queries": [{"query", "vector", "mustAppear", "top3"}]}

Run from services/webhook so its modules import:

  uv run --with-requirements requirements.txt python ../../scripts/search_scorecard/build_cache.py \
      --seed SEED --thumbs THUMBS --queries QUERIES --out CACHE \
      [--vision gemma|gemini] [--only-silent] [--limit N] [--queries-only]

Each save is told to the box's own `about_api.write_about` exactly as the app's `AboutItem` tells
it (music never sends its transcript; the cover goes only with a save that has no transcript and
only when it is at most 400 KB), then both texts are embedded by `embeddings_api._embed`. The
legacy text is the old `Video.embeddingText` — title, topics, summary, caption, transcript[:1000]
— minus the on-screen text the seed does not have.

Resumable: a save already in --out is skipped, so a run that dies is rerun as is. Each about-text
is stamped with a hash of about_api.py's source and the vision model, so changing the prompt
rebuilds every about-text and its vector on the next run, and nothing else: the legacy text and
vector never change and are kept. The query vectors are rebuilt on every run given --queries,
and `--queries-only` rebuilds nothing else, so editing the queries costs twenty embeddings.

Credentials: Bedrock (Gemma, Titan) through the default AWS credentials; the vision model on
OpenRouter through `clef.openrouter_key()`, i.e. OPENROUTER_API_KEY in the environment.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import inspect
import json
import os
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

import requests

# The box's own modules, wherever this is run from.
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "services" / "webhook"))

import about_api  # noqa: E402
import api_v1  # noqa: E402
from embeddings_api import _embed  # noqa: E402

# At most this many model calls in flight: each worker makes its calls one after another.
WORKERS = 8
# The app sends no cover bigger than the server accepts (PipelineCenter.maxCoverBytes).
MAX_COVER_BYTES = about_api.MAX_IMAGE_BYTES
# A bookmark date for the few seed rows that have none: older than every real one.
NO_DATE = "2023-01-01T00:00:00Z"
VISION_MODELS = {"gemma": api_v1.BEDROCK_MODEL, "gemini": api_v1.OPENROUTER_VISION_MODEL}


class _RecordingRequests:
    """Stands in for the `requests` module inside about_api, so the real `write_about` runs
    unchanged and its last response (usage, finish reason) can still be read afterwards. On
    OpenRouter it also asks for the cost to be put in `usage`."""

    HTTPError = requests.HTTPError

    def __init__(self) -> None:
        self.local = threading.local()

    def post(self, url, **kwargs):
        if url == api_v1.OPENROUTER_URL:
            kwargs["json"] = {**kwargs["json"], "usage": {"include": True}}
        self.local.last = None
        response = requests.post(url, **kwargs)
        self.local.last = (kwargs["json"]["model"], response)
        return response

    def last_meta(self) -> dict:
        last = getattr(self.local, "last", None)
        if last is None:
            return {}
        model, response = last
        meta = {"model": model, "status": response.status_code}
        try:
            body = response.json()
        except ValueError:
            return meta
        choice = (body.get("choices") or [{}])[0]
        meta["answer"] = (choice.get("message") or {}).get("content")
        usage = body.get("usage") or {}
        details = usage.get("completion_tokens_details") or {}
        meta.update({
            "finish": choice.get("finish_reason"),
            "promptTokens": usage.get("prompt_tokens"),
            "completionTokens": usage.get("completion_tokens"),
            "reasoningTokens": details.get("reasoning_tokens"),
            "cost": usage.get("cost"),
        })
        return meta


RECORDER = _RecordingRequests()
about_api.requests = RECORDER


def is_silent(save: dict) -> bool:
    return not (save.get("transcript") or "").strip()


def bookmarked_at(save: dict) -> str:
    date = save.get("date")
    return date.replace(" ", "T") + "Z" if date else NO_DATE


def music_lines(save: dict) -> list[str]:
    track = save.get("track") or {}
    title, artist = track.get("title") or "", track.get("artist") or ""
    if not title:
        return []
    return [f"{title} by {artist}" if artist else title]


def row_title(save: dict) -> str:
    """`Video.rowTitle`: the title field today's lexical scorer weighs double."""
    recipe = save.get("recipe") or {}
    if recipe.get("name"):
        return recipe["name"]
    track = save.get("track") or {}
    if track.get("title"):
        return track["title"]
    if save.get("title"):
        return save["title"]
    if save.get("caption"):
        return save["caption"]
    return "@" + save["author"] if save.get("author") else save["videoID"]


def legacy_text(save: dict) -> str:
    """The old `Video.embeddingText`, minus the on-screen text the seed lacks."""
    parts = [
        save.get("title") or "",
        " ".join(save.get("topics") or []),
        save.get("summary") or "",
        save.get("caption") or "",
        (save.get("transcript") or "")[:1000],
    ]
    return "\n".join(part for part in parts if part)


def about_item(save: dict, thumbs: Path) -> tuple[about_api.AboutItem, str]:
    """The request the app would send for this save, and what happened to its cover."""
    category = save.get("category") or ""
    transcript = "" if category == "music" else (save.get("transcript") or "")[:4000]
    image, cover = None, "not sent (has speech)"
    if is_silent(save):
        path = thumbs / f"{save['videoID']}.jpg"
        if not path.exists():
            cover = "missing"
        elif path.stat().st_size > MAX_COVER_BYTES:
            cover = "too big"
        else:
            image, cover = base64.b64encode(path.read_bytes()).decode("ascii"), "sent"
    item = about_api.AboutItem(
        videoID=save["videoID"], category=category, transcript=transcript, ocrText="",
        caption=(save.get("caption") or "")[:1500], summary=(save.get("summary") or "")[:1000],
        music=music_lines(save), image=image)
    return item, cover


def retried(call, *args, attempts: int = 4):
    for attempt in range(attempts):
        try:
            return call(*args)
        except Exception:
            if attempt == attempts - 1:
                raise
            time.sleep(2 ** attempt * 2)


def about_version() -> str:
    """What an about-text was written by: the prompt and the code around it, and the model."""
    source = inspect.getsource(about_api) + about_api.ABOUT_VISION_MODEL
    return hashlib.sha256(source.encode()).hexdigest()[:12]


def build_save(save: dict, thumbs: Path, version: str, previous: dict | None) -> dict:
    item, cover = about_item(save, thumbs)
    meta: dict = {}
    misses: list[str] = []

    def write() -> str:
        nonlocal meta
        try:
            return about_api.write_about(item)
        except Exception as error:
            # Kept, not just retried past: an empty or cut-off answer is what the scorecard
            # run is meant to find out about.
            misses.append(f"{type(error).__name__}: {error} "
                          f"(finish {RECORDER.last_meta().get('finish')})")
            raise
        finally:
            meta = RECORDER.last_meta()

    about = retried(write)
    if (meta.get("answer") or "").strip() == about:
        del meta["answer"]  # kept only when write_about replaced it (a refusal)
    meta["misses"] = misses
    meta["cover"] = cover
    meta["category"] = item.category
    if previous:
        legacy, legacy_vector = previous["legacy"], previous["legacyVector"]
    else:
        legacy = {
            "title": row_title(save),
            "topics": save.get("topics") or [],
            "caption": save.get("caption") or "",
            "summary": save.get("summary") or "",
            "transcript": save.get("transcript") or "",
        }
        legacy_vector = retried(_embed, legacy_text(save))
    return {
        "videoID": save["videoID"],
        "bookmarkedAt": bookmarked_at(save),
        "about": about,
        "aboutVector": retried(_embed, about),
        "aboutVersion": version,
        "legacy": legacy,
        "legacyVector": legacy_vector,
        "aboutMeta": meta,
    }


def write_cache(path: Path, cache: dict) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(cache, ensure_ascii=False))
    os.replace(tmp, path)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--seed", required=True, type=Path)
    parser.add_argument("--thumbs", required=True, type=Path)
    parser.add_argument("--queries", type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--vision", choices=sorted(VISION_MODELS),
                        help="model for saves sent with a cover (default: about_api's own)")
    parser.add_argument("--only-silent", action="store_true", help="only saves with no transcript")
    parser.add_argument("--limit", type=int, help="at most this many saves")
    parser.add_argument("--queries-only", action="store_true",
                        help="rebuild only the query vectors, keep every save as it is")
    args = parser.parse_args()

    if args.vision:
        about_api.ABOUT_VISION_MODEL = VISION_MODELS[args.vision]
    cache = json.loads(args.out.read_text()) if args.out.exists() else {"saves": [], "queries": []}

    if not args.queries_only:
        seed = json.loads(args.seed.read_text())
        version = about_version()
        cached = {save["videoID"]: save for save in cache["saves"]}
        todo = [save for save in seed if not args.only_silent or is_silent(save)]
        if args.limit:
            todo = todo[:args.limit]
        todo = [save for save in todo
                if cached.get(save["videoID"], {}).get("aboutVersion") != version]
        stale = sum(1 for save in todo if save["videoID"] in cached)
        print(f"vision model {about_api.ABOUT_VISION_MODEL}, about version {version}; "
              f"{len(cached)} saves cached, {len(todo)} to build ({stale} about-texts stale)",
              flush=True)

        order = {save["videoID"]: index for index, save in enumerate(seed)}
        failed = 0
        with ThreadPoolExecutor(max_workers=WORKERS) as pool:
            futures = {
                pool.submit(build_save, save, args.thumbs, version, cached.get(save["videoID"])):
                    save["videoID"]
                for save in todo}
            for count, future in enumerate(as_completed(futures), 1):
                try:
                    built = future.result()
                    cached[built["videoID"]] = built
                except Exception as error:
                    failed += 1
                    print(f"FAILED {futures[future]}: {type(error).__name__}: {error}", flush=True)
                if count % WORKERS == 0 or count == len(futures):
                    cache["saves"] = sorted(
                        cached.values(), key=lambda save: order.get(save["videoID"], len(order)))
                    write_cache(args.out, cache)
                    print(f"{count}/{len(futures)} built, {failed} failed", flush=True)

    if args.queries:
        queries = json.loads(args.queries.read_text())
        cache["queries"] = [
            {"query": q["query"], "vector": retried(_embed, q["query"]),
             "mustAppear": q["mustAppear"], "top3": q["top3"]}
            for q in queries]
        print(f"{len(cache['queries'])} query vectors built", flush=True)
    write_cache(args.out, cache)
    return 0


if __name__ == "__main__":
    sys.exit(main())
