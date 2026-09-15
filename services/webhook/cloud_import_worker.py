"""SQS worker for durable one-video fast-pass jobs.

There is no process-wide store any more: each message carries the owning userID and the
worker builds a store scoped to that user, so a job can only ever write into its own
account's partition.
"""

from __future__ import annotations

import logging
import os
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from threading import Event

import requests

from cloud_import_pipeline import FastPassPipeline, PipelineError
from cloud_import_queue import MESSAGE_SCHEMA, SQSImportQueue
from cloud_import_store import DynamoImportStore, shared_table
from cloud_import_models import VideoState

log = logging.getLogger("stash-import-worker")


@dataclass(frozen=True)
class HandleResult:
    deleted: bool
    retryable: bool


def _delete(queue, message) -> None:
    receipt = message.get("receiptHandle")
    if receipt:
        queue.delete(receipt)


def _classify(error: Exception) -> PipelineError:
    response = getattr(error, "response", None)
    status = getattr(response, "status_code", None)
    # An exception nobody anticipated is treated as transient, not terminal: the only
    # bounded cost is MAX_FAST_PASS_ATTEMPTS redeliveries, while the old default of
    # "permanently failed" turned every stray blip into a dead video row that no retry,
    # and no re-import, would ever repair (40 of a 941-video library died this way).
    # A genuinely deterministic crash still settles: the attempt budget runs out and
    # fail_video records a terminal failure.
    retryable = status is None or status == 429 or status >= 500
    return PipelineError(str(error), retryable, f"provider_{status}" if status else "worker_error")


def handle_message(message: dict, store_for, pipeline, queue) -> HandleResult:
    """`store_for` maps a userID to a store scoped to that user."""
    import_id = message.get("importID")
    video_id = message.get("videoID")
    user_id = message.get("userID")
    # Drop, do not raise, on an unusable message. Raising would let every pre-cutover
    # message in flight burn its five redeliveries into the dead-letter queue.
    if message.get("stage") != "fast_pass" or message.get("v") != MESSAGE_SCHEMA or not user_id \
            or not import_id or not video_id:
        log.warning("discarding unusable message %s", message.get("messageID"))
        _delete(queue, message)
        return HandleResult(deleted=True, retryable=False)
    store = store_for(user_id)
    if not store.claim_video(import_id, video_id):
        item = store.get_video(import_id, video_id) if hasattr(store, "get_video") else None
        if item and item.get("state") == VideoState.RUNNING.value:
            return HandleResult(deleted=False, retryable=True)
        _delete(queue, message)
        return HandleResult(deleted=True, retryable=False)
    receipt = message.get("receiptHandle")
    if receipt and hasattr(queue, "extend_visibility"):
        queue.extend_visibility(receipt, timeout_seconds=300)

    url = message.get("url")
    if not url and hasattr(store, "get_video"):
        item = store.get_video(import_id, video_id)
        url = item.get("url") if item else None
    try:
        if not url:
            raise PipelineError("video URL missing", False, "invalid_metadata")
        result = pipeline.process(url)
    except PipelineError as error:
        log.warning("fast pass failed video=%s code=%s retryable=%s: %s",
                    video_id, error.code, error.retryable, error)
        store.fail_video(import_id, video_id, error.retryable, error.code)
        if error.retryable:
            return HandleResult(deleted=False, retryable=True)
        _delete(queue, message)
        return HandleResult(deleted=True, retryable=False)
    except Exception as error:
        # The journal is the only place this error exists — fail_video keeps just a code.
        log.exception("unexpected error processing video=%s import=%s", video_id, import_id)
        classified = _classify(error)
        store.fail_video(import_id, video_id, classified.retryable, classified.code)
        if classified.retryable:
            return HandleResult(deleted=False, retryable=True)
        _delete(queue, message)
        return HandleResult(deleted=True, retryable=False)

    if store.complete_video(import_id, result):
        _delete(queue, message)
        return HandleResult(deleted=True, retryable=False)
    return HandleResult(deleted=False, retryable=True)


def run_forever(queue=None, store_for=None, pipeline=None, stop_event: Event | None = None,
                concurrency: int | None = None) -> None:
    queue = queue or SQSImportQueue()
    # One table handle for the process, one store per message. Building a single store at
    # startup is what used to pin every job to one shared partition.
    if store_for is None:
        table = shared_table()   # built once here, before any thread can race the lazy init
        store_for = lambda user_id: DynamoImportStore(table=table, user_id=user_id)
    pipeline = pipeline or FastPassPipeline()
    stop_event = stop_event or Event()
    # Each video is ~5-10 s of yt-dlp and one Bedrock call, all of it waiting on the network,
    # so a handful of threads is a near-linear speedup. SQS hands out at most 10 per receive.
    concurrency = max(1, min(concurrency or int(os.environ.get("IMPORT_WORKER_CONCURRENCY") or 4), 10))
    # ponytail: the batch is a barrier — a slow video holds its siblings' slots until it lands.
    # Refill per-slot with futures if that ever shows in the journal.
    with ThreadPoolExecutor(max_workers=concurrency) as pool:
        while not stop_event.is_set():
            messages = queue.receive(max_messages=concurrency, wait_time_seconds=20)
            list(pool.map(lambda message: handle_message(message, store_for, pipeline, queue), messages))


if __name__ == "__main__":
    import stash_logging

    stash_logging.configure()
    run_forever()
