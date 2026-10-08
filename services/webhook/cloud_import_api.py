"""Authenticated asynchronous cloud-import API routes.

Every route here resolves the caller through `stash_auth.user_store` or its paying sibling
`entitled_store`, which are the only constructors for a `DynamoImportStore`. There is no
shared token and no unscoped store, so an import id from another account is simply absent
from the caller's partition — the old `GET /v1/imports/{id}` IDOR cannot be reconstructed by
any code path in this file.

Submitting an import spends money, so it takes `entitled_store` and 402s without a
subscription. Reading a status or a result page does not, and takes `user_store`: work
already paid for stays collectable after a subscription lapses.
"""

from __future__ import annotations

import logging
from concurrent.futures import ThreadPoolExecutor
from functools import lru_cache

from fastapi import APIRouter, Depends, HTTPException, Query

import clef
from cloud_import_models import CreateImportRequest, CreateImportResponse, ImportStatus, ResultPage
from cloud_import_pipeline import _canonical, fetch_metadata
from cloud_import_queue import SQSImportQueue, release_due
from cloud_import_store import MAX_FREE_RETRIES, SLICE, DynamoImportStore, newest_first
from stash_auth import entitled_store, quota_exhausted, user_store


router = APIRouter(prefix="/v1")

log = logging.getLogger("stash-webhook")

# How many videos of an import get a first guess from Clef. Sixty evenly spaced through a
# thousand-video library puts a category's share within about ±12 points — enough to shape
# the shelves — and finishes in ~10 s at eight wide.
MAP_SAMPLE = 60

# One pool per process, shared by every import. Eight threads is the whole budget however
# many imports arrive at once: each task is one yt-dlp run (~1.3 s) and one Clef call
# (~0.4 s), and the box is also running the fast-pass worker.
_MAP_POOL = ThreadPoolExecutor(max_workers=8, thread_name_prefix="map")


def sample_for_map(videos: list, size: int = MAP_SAMPLE) -> list:
    """Evenly spaced through the submission. The phone sends newest-first, so a stride walks
    the whole date range rather than the newest week — the picker is about the library, not
    about last Tuesday."""
    stride = max(1, len(videos) // size)
    return videos[::stride][:size]


def _map_one(store: DynamoImportStore, import_id: str, video_id: str, url: str) -> None:
    try:
        # The same rewrite the fast pass applies: yt-dlp refuses a photo post's `/photo/` path
        # and serves the post under `/video/`, so without it every sampled photo post is a skip.
        metadata = fetch_metadata(_canonical(url))
        guess = clef.classify(clef.state_from_metadata(metadata)) if metadata else None
    except Exception:
        # The journal is the only place this lands; the map just has one fewer answer.
        log.exception("map pass failed video=%s import=%s", video_id, import_id)
        guess = None
    # The pool never reads these futures, so an exception here would vanish without a line
    # in the journal — and a map that never reaches `sampled` is the one failure the phone
    # cannot tell from a slow one.
    try:
        if guess is None:
            store.skip_map_video(import_id)
            return
        category, probability = guess
        log.info("map guess import=%s video=%s category=%s p=%.2f", import_id, video_id, category, probability)
        store.guess_video(import_id, video_id, category)
    except Exception:
        log.exception("map write failed video=%s import=%s", video_id, import_id)


def start_map_pass(store: DynamoImportStore, import_id: str, videos: list, pool=None) -> int:
    """Open the map and hand a sample of the import to the pool. Returns how many were sampled.
    Never raises: the import is already accepted and charged by the time this runs."""
    sample = sample_for_map(videos)
    try:
        store.start_map(import_id, sampled=len(sample))
    except Exception:
        log.exception("could not start the map for import=%s", import_id)
        return 0
    pool = pool or _MAP_POOL
    for video in sample:
        pool.submit(_map_one, store, import_id, video.video_id, video.url)
    return len(sample)


# One client per process: the status poll takes the queue too now, and building a client
# is an instance-metadata round trip. The credentials inside it refresh themselves.
@lru_cache(maxsize=1)
def get_queue() -> SQSImportQueue:
    return SQSImportQueue()


@router.post("/imports", response_model=CreateImportResponse, response_model_by_alias=True, status_code=202)
def create_import(
    body: CreateImportRequest,
    store: DynamoImportStore = Depends(entitled_store),
    queue: SQSImportQueue = Depends(get_queue),
):
    # Charge one unit per accepted video, but only on a genuine first submission — the
    # client retries this call, and a retry that re-charged would eat the budget alive.
    # `duplicates` in the response has always been 0 (nothing ever sets it), so the charge
    # is based on the submitted list, not on that field.
    if store.get_client_import(body.client_import_id):
        # A retry. The units were taken by the first call and `create_import` replays the
        # stored row, so this charges nothing. It does re-drive the queue: the charge and the
        # video rows land before the messages do, so a first call that died in the enqueue
        # loop below left videos paid for and invisible, and nothing else ever looks at a
        # QUEUED row again. A message for a row a worker already holds is dropped by
        # `claim_video`, which only accepts QUEUED/RETRYABLE — so a retry that was not needed
        # costs a few wasted messages, not duplicated work.
        created, quota = store.create_import(body), store.get_quota()
        for video_id, url in store.pending_videos(created.import_id):
            queue.enqueue(store.user_id, created.import_id, video_id, url=url)
    else:
        requested = len(body.videos)
        quota = store.get_quota()
        # A save that already failed is retried free (see MAX_FREE_RETRIES) and is never the
        # part a short budget cuts.
        counts = store.failure_counts({video.video_id for video in body.videos})
        is_free = [1 <= counts.get(video.video_id, 0) <= MAX_FREE_RETRIES for video in body.videos]
        free = [video for video, gratis in zip(body.videos, is_free) if gratis]
        paid = [video for video, gratis in zip(body.videos, is_free) if not gratis]
        # Partial acceptance. A 720-video favourites library against a 500-unit budget takes
        # the newest 500 and defers the rest; refusing the whole import left exactly the user
        # this product is for with no way in at all. Newest-first is the client's submission
        # order — ExportParser.bookmarks sorts `$0.date > $1.date` and CloudImportClient.submit
        # maps that list straight into the payload — so the slice keeps the freshest saves.
        charged = min(len(paid), quota.initial_remaining + quota.month_remaining)
        if charged == 0 and not free:
            raise quota_exhausted(quota)
        if charged:
            quota = store.reserve_quota(charged)
            if quota is None:  # lost a race for the last units
                raise quota_exhausted(store.get_quota())
        if charged < len(paid):
            body = body.model_copy(update={"videos": free + paid[:charged]})
        try:
            created = store.create_import(body, deferred=requested - len(body.videos))
        except Exception:
            if charged:
                store.refund_quota(charged)
            raise
        if not created.created and charged:
            # Lost a race with a concurrent identical retry; hand the units back.
            quota = store.refund_quota(charged)
        else:
            # The newest slice only; the worker releases the rest as this one settles.
            for video in newest_first(body.videos)[:SLICE]:
                queue.enqueue(store.user_id, created.import_id, video.video_id, url=video.url)
            # After the queue, never before: the fast pass is what the user paid for, and a
            # first guess that delayed it would be a worse deal than no guess. Only for the
            # import this call actually created — a lost race with nothing charged lands here
            # too, and a second `start_map` would reset a map the first pass is still writing.
            if created.created:
                start_map_pass(store, created.import_id, body.videos)
    return CreateImportResponse(
        importID=created.import_id,
        state="accepted",
        accepted=created.accepted,
        deferred=created.deferred,
        duplicates=created.duplicates,
        quota=quota,
    )


@router.get("/imports/{import_id}", response_model=ImportStatus, response_model_by_alias=True)
def get_import_status(
    import_id: str,
    store: DynamoImportStore = Depends(user_store),
    queue: SQSImportQueue = Depends(get_queue),
):
    # Stall recovery: a release that died with nothing left in flight has no worker to
    # retake it, and the phone polls here every 8 s while open and from background refresh.
    try:
        release_due(store, queue, import_id)
    except Exception:
        log.exception("slice release from the status poll failed import=%s", import_id)
    status = store.get_status(import_id)
    if status is None:
        raise HTTPException(status_code=404, detail="import not found")
    return status


@router.get("/imports/{import_id}/results", response_model=ResultPage, response_model_by_alias=True)
def get_import_results(
    import_id: str,
    cursor: str | None = Query(None),
    store: DynamoImportStore = Depends(user_store),
):
    if store.get_status(import_id) is None:
        raise HTTPException(status_code=404, detail="import not found")
    return store.list_results(import_id, cursor=cursor)
