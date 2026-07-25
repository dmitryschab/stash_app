"""Authenticated asynchronous cloud-import API routes.

Every route here resolves the caller through `stash_auth.user_store`, which is the only
constructor for a `DynamoImportStore`. There is no shared token and no unscoped store, so
an import id from another account is simply absent from the caller's partition — the old
`GET /v1/imports/{id}` IDOR cannot be reconstructed by any code path in this file.
"""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Query

from cloud_import_models import CreateImportRequest, CreateImportResponse, ImportStatus, ResultPage
from cloud_import_queue import SQSImportQueue
from cloud_import_store import DynamoImportStore
from stash_auth import quota_exhausted, user_store


router = APIRouter(prefix="/v1")


def get_queue() -> SQSImportQueue:
    return SQSImportQueue()


@router.post("/imports", response_model=CreateImportResponse, response_model_by_alias=True, status_code=202)
def create_import(
    body: CreateImportRequest,
    store: DynamoImportStore = Depends(user_store),
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
        # Partial acceptance. A 720-video favourites library against a 500-unit budget takes
        # the newest 500 and defers the rest; refusing the whole import left exactly the user
        # this product is for with no way in at all. Newest-first is the client's submission
        # order — ExportParser.bookmarks sorts `$0.date > $1.date` and CloudImportClient.submit
        # maps that list straight into the payload — so the slice keeps the freshest saves.
        charged = min(requested, quota.initial_remaining + quota.month_remaining)
        if charged == 0:
            raise quota_exhausted(quota)
        quota = store.reserve_quota(charged)
        if quota is None:  # lost a race for the last units
            raise quota_exhausted(store.get_quota())
        if charged < requested:
            body = body.model_copy(update={"videos": body.videos[:charged]})
        try:
            created = store.create_import(body, deferred=requested - charged)
        except Exception:
            store.refund_quota(charged)
            raise
        if not created.created:
            # Lost a race with a concurrent identical retry; hand the units back.
            quota = store.refund_quota(charged)
        else:
            for video in body.videos:
                queue.enqueue(store.user_id, created.import_id, video.video_id, url=video.url)
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
):
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
