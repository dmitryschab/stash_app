"""DynamoDB state adapter for durable, idempotent cloud imports."""

from __future__ import annotations

import json
import os
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from decimal import Decimal
from typing import Any

import boto3
from botocore.exceptions import ClientError

from cloud_import_models import (
    CreateImportRequest,
    ImportState,
    ImportStatus,
    Progress,
    ResultPage,
    VideoResult,
    VideoState,
)


@dataclass(frozen=True)
class CreateImportResult:
    import_id: str
    created: bool
    accepted: int
    duplicates: int = 0


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _dynamo_value(value: Any) -> Any:
    if isinstance(value, float):
        return Decimal(str(value))
    if isinstance(value, dict):
        return {key: _dynamo_value(item) for key, item in value.items()}
    if isinstance(value, list):
        return [_dynamo_value(item) for item in value]
    return value


def _is_conditional_failure(error: Exception) -> bool:
    if isinstance(error, ClientError):
        return error.response.get("Error", {}).get("Code") in {
            "ConditionalCheckFailedException",
            "TransactionCanceledException",
        }
    return error.__class__.__name__ in {"ConditionalCheckFailed", "ConditionalCheckFailedException"}


class DynamoImportStore:
    def __init__(
        self,
        table=None,
        *,
        table_name: str | None = None,
        installation_id: str = "test-group",
        dynamodb_resource=None,
    ):
        if table is None:
            resource = dynamodb_resource or boto3.resource(
                "dynamodb", region_name=os.environ.get("AWS_REGION", "eu-north-1")
            )
            table = resource.Table(table_name or os.environ["STASH_IMPORT_TABLE"])
        self.table = table
        self.table_name = getattr(table, "name", table_name or os.environ.get("STASH_IMPORT_TABLE", ""))
        self.installation_id = installation_id
        self._client = getattr(getattr(table, "meta", None), "client", None)

    def _key(self, import_id: str, suffix: str) -> dict[str, str]:
        return {"PK": f"IMPORT#{import_id}", "SK": suffix}

    def _get(self, key: dict[str, str]) -> dict[str, Any] | None:
        return self.table.get_item(Key=key).get("Item")

    def _transact(self, operations: list[dict[str, Any]]) -> None:
        if self._client is not None and hasattr(self._client, "transact_write_items"):
            self._client.transact_write_items(TransactItems=operations)
            return
        # Small fake-table fallback used by local contract tests. Production uses
        # the transaction path above, which keeps stage and counters atomic.
        for operation in operations:
            if "Put" in operation:
                put = operation["Put"]
                self.table.put_item(Item=put["Item"])
            elif "Update" in operation:
                update = operation["Update"]
                key = update["Key"]
                item = self._get(key) or key.copy()
                names = update.get("ExpressionAttributeNames", {})
                values = update.get("ExpressionAttributeValues", {})
                expression = update.get("UpdateExpression", "")
                if expression.startswith("SET "):
                    assignments = expression[4:].split(", ")
                    for assignment in assignments:
                        name, value = [part.strip() for part in assignment.split("=")]
                        field = names.get(name, name)
                        if "+" in value:
                            base, increment = [part.strip() for part in value.split("+")]
                            item[field] = item.get(names.get(base, base), 0) + values[increment]
                        else:
                            item[field] = values[value]
                self.table.put_item(Item=item)

    def create_import(self, request: CreateImportRequest) -> CreateImportResult:
        client_key = {"PK": f"INSTALL#{self.installation_id}", "SK": f"CLIENT#{request.client_import_id}"}
        existing = self._get(client_key)
        if existing:
            return CreateImportResult(existing["importID"], False, int(existing.get("accepted", 0)))

        import_id = str(uuid.uuid4())
        now = _now()
        meta = {
            **self._key(import_id, "META"),
            "importID": import_id,
            "state": ImportState.ACCEPTED.value,
            "total": len(request.videos),
            "fastDone": 0,
            "unavailable": 0,
            "partialFailures": 0,
            "estimatedCostUSD": Decimal("0"),
            "updatedAt": now,
        }
        client_item = {
            **client_key,
            "importID": import_id,
            "accepted": len(request.videos),
            "createdAt": now,
        }
        video_items = [
            {
                **self._key(import_id, f"VIDEO#{video.video_id}"),
                "videoID": video.video_id,
                "url": video.url,
                "bookmarkedAt": video.bookmarked_at.isoformat(),
                "state": VideoState.QUEUED.value,
                "updatedAt": now,
            }
            for video in request.videos
        ]
        operations = [
            {"Put": {"TableName": self.table_name, "Item": client_item, "ConditionExpression": "attribute_not_exists(PK)"}},
            {"Put": {"TableName": self.table_name, "Item": meta, "ConditionExpression": "attribute_not_exists(PK)"}},
            *[
                {"Put": {"TableName": self.table_name, "Item": item, "ConditionExpression": "attribute_not_exists(PK)"}}
                for item in video_items
            ],
        ]
        try:
            self._transact(operations)
        except Exception as error:
            if not _is_conditional_failure(error):
                raise
            existing = self._get(client_key)
            if not existing:
                raise
            return CreateImportResult(existing["importID"], False, int(existing.get("accepted", 0)))
        return CreateImportResult(import_id, True, len(video_items))

    def claim_video(self, import_id: str, video_id: str) -> bool:
        key = self._key(import_id, f"VIDEO#{video_id}")
        values = {":running": VideoState.RUNNING.value, ":queued": VideoState.QUEUED.value, ":retryable": VideoState.RETRYABLE.value, ":updated": _now()}
        try:
            if hasattr(self.table, "update_item"):
                self.table.update_item(
                    Key=key,
                    UpdateExpression="SET #state = :running, updatedAt = :updated",
                    ConditionExpression="#state IN (:queued, :retryable)",
                    ExpressionAttributeNames={"#state": "state"},
                    ExpressionAttributeValues=values,
                )
            else:
                item = self._get(key)
                if not item or item.get("state") not in {VideoState.QUEUED.value, VideoState.RETRYABLE.value}:
                    return False
                item.update(state=VideoState.RUNNING.value, updatedAt=values[":updated"])
                self.table.put_item(Item=item)
        except Exception as error:
            if _is_conditional_failure(error):
                return False
            raise
        self._mark_fast_pass(import_id)
        return True

    def _mark_fast_pass(self, import_id: str) -> None:
        key = self._key(import_id, "META")
        if hasattr(self.table, "update_item"):
            try:
                self.table.update_item(
                    Key=key,
                    UpdateExpression="SET #state = :fast_pass, updatedAt = :updated",
                    ConditionExpression="#state = :accepted",
                    ExpressionAttributeNames={"#state": "state"},
                    ExpressionAttributeValues={":fast_pass": ImportState.FAST_PASS.value, ":accepted": ImportState.ACCEPTED.value, ":updated": _now()},
                )
            except Exception as error:
                if not _is_conditional_failure(error):
                    raise
        else:
            item = self._get(key)
            if item and item.get("state") == ImportState.ACCEPTED.value:
                item["state"] = ImportState.FAST_PASS.value
                item["updatedAt"] = _now()
                self.table.put_item(Item=item)

    def complete_video(self, import_id: str, result: VideoResult) -> bool:
        video_key = self._key(import_id, f"VIDEO#{result.video_id}")
        meta_key = self._key(import_id, "META")
        now = _now()
        result_item = _dynamo_value(result.model_dump(by_alias=True, exclude_none=True))
        operations = [
            {
                "Update": {
                    "TableName": self.table_name,
                    "Key": video_key,
                    "UpdateExpression": "SET #state = :completed, #result = :result, updatedAt = :updated",
                    "ConditionExpression": "#state = :running",
                    "ExpressionAttributeNames": {"#state": "state", "#result": "result"},
                    "ExpressionAttributeValues": {":completed": VideoState.COMPLETED.value, ":running": VideoState.RUNNING.value, ":result": result_item, ":updated": now},
                }
            },
            {
                "Update": {
                    "TableName": self.table_name,
                    "Key": meta_key,
                    "UpdateExpression": "SET fastDone = fastDone + :one, unavailable = unavailable + :unavailable, updatedAt = :updated",
                    "ConditionExpression": "fastDone < total",
                    "ExpressionAttributeValues": {":one": 1, ":unavailable": 1 if result.unavailable else 0, ":updated": now},
                }
            },
        ]
        try:
            if self._client is not None and hasattr(self._client, "transact_write_items"):
                self._transact(operations)
            else:
                video = self._get(video_key)
                meta = self._get(meta_key)
                if not video or video.get("state") != VideoState.RUNNING.value or not meta or int(meta.get("fastDone", 0)) >= int(meta["total"]):
                    return False
                video.update(state=VideoState.COMPLETED.value, result=result_item, updatedAt=now)
                meta["fastDone"] = int(meta.get("fastDone", 0)) + 1
                meta["unavailable"] = int(meta.get("unavailable", 0)) + (1 if result.unavailable else 0)
                meta["updatedAt"] = now
                self.table.put_item(Item=video)
                self.table.put_item(Item=meta)
        except Exception as error:
            if _is_conditional_failure(error):
                return False
            raise
        self._try_finalize(import_id)
        return True

    def fail_video(self, import_id: str, video_id: str, retryable: bool, code: str) -> bool:
        key = self._key(import_id, f"VIDEO#{video_id}")
        item = self._get(key)
        if not item or item.get("state") not in {VideoState.RUNNING.value, VideoState.RETRYABLE.value}:
            return False
        if retryable:
            item.update(state=VideoState.RETRYABLE.value, errorCode=code, updatedAt=_now())
            self.table.put_item(Item=item)
            return True
        meta = self._get(self._key(import_id, "META"))
        if not meta or item.get("state") != VideoState.RUNNING.value:
            return False
        item.update(state=VideoState.FAILED.value, errorCode=code, updatedAt=_now())
        meta["fastDone"] = int(meta.get("fastDone", 0)) + 1
        meta["partialFailures"] = int(meta.get("partialFailures", 0)) + 1
        meta["updatedAt"] = _now()
        self.table.put_item(Item=item)
        self.table.put_item(Item=meta)
        self._try_finalize(import_id)
        return True

    def _try_finalize(self, import_id: str) -> None:
        key = self._key(import_id, "META")
        item = self._get(key)
        if item and int(item.get("fastDone", 0)) == int(item.get("total", 0)):
            if hasattr(self.table, "update_item"):
                try:
                    self.table.update_item(
                        Key=key,
                        UpdateExpression="SET #state = :completed, updatedAt = :updated",
                        ConditionExpression="fastDone = total AND #state <> :completed",
                        ExpressionAttributeNames={"#state": "state"},
                        ExpressionAttributeValues={":completed": ImportState.COMPLETED.value, ":updated": _now()},
                    )
                except Exception as error:
                    if not _is_conditional_failure(error):
                        raise
            elif item.get("state") != ImportState.COMPLETED.value:
                item["state"] = ImportState.COMPLETED.value
                item["updatedAt"] = _now()
                self.table.put_item(Item=item)

    def get_status(self, import_id: str) -> ImportStatus | None:
        item = self._get(self._key(import_id, "META"))
        if not item:
            return None
        return ImportStatus(
            importID=import_id,
            state=item["state"],
            fastPass=Progress(done=int(item.get("fastDone", 0)), total=int(item.get("total", 0))),
            unavailable=int(item.get("unavailable", 0)),
            partialFailures=int(item.get("partialFailures", 0)),
            estimatedCostUSD=float(item.get("estimatedCostUSD", 0)),
            updatedAt=item["updatedAt"],
        )

    def list_results(self, import_id: str, cursor: str | None = None, limit: int = 50) -> ResultPage:
        if hasattr(self.table, "meta"):
            from boto3.dynamodb.conditions import Key
            expression = Key("PK").eq(f"IMPORT#{import_id}") & Key("SK").begins_with("VIDEO#")
        else:
            expression = (f"IMPORT#{import_id}", "VIDEO#")
        items = self.table.query(KeyConditionExpression=expression).get("Items", [])
        results: list[VideoResult] = []
        for item in items:
            if item.get("state") not in {VideoState.COMPLETED.value, VideoState.UNAVAILABLE.value, VideoState.FAILED.value}:
                continue
            if cursor and item.get("videoID", "") <= cursor:
                continue
            raw_result = item.get("result") or {"videoID": item["videoID"], "unavailable": item.get("state") == VideoState.UNAVAILABLE.value, "errorCode": item.get("errorCode")}
            results.append(VideoResult.model_validate(raw_result))
            if len(results) >= limit:
                break
        next_cursor = results[-1].video_id if len(results) == limit else None
        return ResultPage(results=results, nextCursor=next_cursor)
