"""Authenticated asynchronous cloud-import API routes."""

from __future__ import annotations

import os

from fastapi import APIRouter, Depends, Header, HTTPException, Query

from cloud_import_models import CreateImportRequest, CreateImportResponse, ImportStatus, ResultPage
from cloud_import_queue import SQSImportQueue
from cloud_import_store import DynamoImportStore


router = APIRouter(prefix="/v1")
API_TOKEN = os.environ.get("STASH_API_TOKEN", "")


def require_import_auth(authorization: str | None) -> None:
    if not API_TOKEN:
        raise HTTPException(status_code=503, detail="API token not configured")
    if authorization != f"Bearer {API_TOKEN}":
        raise HTTPException(status_code=401, detail="bad token")


def get_store() -> DynamoImportStore:
    return DynamoImportStore(installation_id="test-group")


def get_queue() -> SQSImportQueue:
    return SQSImportQueue()


@router.post("/imports", response_model=CreateImportResponse, response_model_by_alias=True, status_code=202)
def create_import(
    body: CreateImportRequest,
    authorization: str | None = Header(None),
    store: DynamoImportStore = Depends(get_store),
    queue: SQSImportQueue = Depends(get_queue),
):
    require_import_auth(authorization)
    created = store.create_import(body)
    if created.created:
        for video in body.videos:
            queue.enqueue(created.import_id, video.video_id)
    return CreateImportResponse(
        importID=created.import_id,
        state="accepted",
        accepted=created.accepted,
        duplicates=created.duplicates,
    )


@router.get("/imports/{import_id}", response_model=ImportStatus, response_model_by_alias=True)
def get_import_status(
    import_id: str,
    authorization: str | None = Header(None),
    store: DynamoImportStore = Depends(get_store),
):
    require_import_auth(authorization)
    status = store.get_status(import_id)
    if status is None:
        raise HTTPException(status_code=404, detail="import not found")
    return status


@router.get("/imports/{import_id}/results", response_model=ResultPage, response_model_by_alias=True)
def get_import_results(
    import_id: str,
    cursor: str | None = Query(None),
    authorization: str | None = Header(None),
    store: DynamoImportStore = Depends(get_store),
):
    require_import_auth(authorization)
    if store.get_status(import_id) is None:
        raise HTTPException(status_code=404, detail="import not found")
    return store.list_results(import_id, cursor=cursor)
