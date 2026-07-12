"""SQS worker for durable one-video fast-pass jobs."""

from __future__ import annotations

import os
import time
from dataclasses import dataclass
from threading import Event

import requests

from cloud_import_pipeline import FastPassPipeline, PipelineError
from cloud_import_queue import SQSImportQueue
from cloud_import_store import DynamoImportStore


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
    retryable = isinstance(error, (requests.Timeout, requests.ConnectionError)) or status == 429 or (status is not None and status >= 500)
    return PipelineError(str(error), retryable, f"provider_{status}" if status else "worker_error")


def handle_message(message: dict, store, pipeline, queue) -> HandleResult:
    import_id = message["importID"]
    video_id = message["videoID"]
    if message.get("stage") != "fast_pass":
        _delete(queue, message)
        return HandleResult(deleted=True, retryable=False)
    if not store.claim_video(import_id, video_id):
        _delete(queue, message)
        return HandleResult(deleted=True, retryable=False)

    url = message.get("url")
    if not url and hasattr(store, "get_video"):
        item = store.get_video(import_id, video_id)
        url = item.get("url") if item else None
    try:
        if not url:
            raise PipelineError("video URL missing", False, "invalid_metadata")
        result = pipeline.process(url)
    except PipelineError as error:
        store.fail_video(import_id, video_id, error.retryable, error.code)
        if error.retryable:
            return HandleResult(deleted=False, retryable=True)
        _delete(queue, message)
        return HandleResult(deleted=True, retryable=False)
    except Exception as error:
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


def run_forever(queue=None, store=None, pipeline=None, stop_event: Event | None = None) -> None:
    queue = queue or SQSImportQueue()
    store = store or DynamoImportStore()
    pipeline = pipeline or FastPassPipeline()
    stop_event = stop_event or Event()
    while not stop_event.is_set():
        for message in queue.receive(max_messages=1, wait_time_seconds=20):
            if stop_event.is_set():
                break
            handle_message(message, store, pipeline, queue)


if __name__ == "__main__":
    run_forever()
