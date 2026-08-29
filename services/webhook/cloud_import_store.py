"""DynamoDB state adapter for durable, idempotent cloud imports.

Every item this module writes lives under the authenticated user's partition,
`PK = "INSTALL#<userID>"`. That single key choice is what buys per-user isolation
(a foreign import id simply is not in the caller's partition, so `GET /v1/imports/{id}`
cannot be an IDOR), and it makes `DELETE /v1/me` and `GET /v1/me/export` one Query each
instead of a GSI. There is deliberately no default user id: constructing a store without
an authenticated caller is a TypeError, not a silent write to a shared partition.
"""

from __future__ import annotations

import os
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from decimal import Decimal
from typing import Any, Iterator

from botocore.exceptions import ClientError

from cloud_import_aws import instance_role_session

from cloud_import_models import (
    INITIAL_LIMIT,
    TRIAL_LIMIT,
    MONTH_LIMIT,
    CreateImportRequest,
    ImportState,
    ImportStatus,
    Progress,
    Quota,
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
    deferred: int = 0


CLAIM_LEASE_SECONDS = 300
# Give up on a perpetually-retryable video after this many attempts so the import
# can finalize instead of looping to the SQS dead-letter queue forever. Kept in
# step with the queue's redrive maxReceiveCount (infra/aws-box/main.tf).
MAX_FAST_PASS_ATTEMPTS = 5

# Compare-and-set retries on the quota row. N writers racing on one row need N attempts in
# the worst case — each round exactly one wins and the rest re-read — and the shipping app
# drains its queue at concurrency 3 on the metered transcript route. A budget of 3 was
# therefore exactly at the limit, and running out raises *after* Groq has already been paid
# for and the transcript produced. 8 leaves room for a second device on the same account
# and costs nothing when uncontended.
QUOTA_CAS_ATTEMPTS = 8


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _next_month_reset(now: datetime) -> int:
    """Unix seconds at 00:00 UTC on the 1st of the following calendar month."""
    year, month = (now.year + 1, 1) if now.month == 12 else (now.year, now.month + 1)
    return int(datetime(year, month, 1, tzinfo=timezone.utc).timestamp())


_shared_table = None


def shared_table():
    """The one boto3 Table handle for the process, built lazily.

    Lazy because importing this module must not touch AWS: pytest and `python api_v1.py`
    both import it off-box, where reaching for instance metadata would hang.
    """
    global _shared_table
    if _shared_table is None:
        resource = instance_role_session().resource("dynamodb")
        _shared_table = resource.Table(os.environ["STASH_IMPORT_TABLE"])
    return _shared_table


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


def _is_stale_claim(updated_at: str | None) -> bool:
    if not updated_at:
        return False
    try:
        claimed_at = datetime.fromisoformat(updated_at)
    except ValueError:
        return False
    return claimed_at < datetime.now(timezone.utc) - timedelta(seconds=CLAIM_LEASE_SECONDS)


class DynamoImportStore:
    def __init__(
        self,
        table=None,
        *,
        table_name: str | None = None,
        user_id: str,
        dynamodb_resource=None,
    ):
        if not user_id:
            raise ValueError("user_id is required — there is no shared partition")
        if table is None:
            resource = dynamodb_resource or instance_role_session().resource("dynamodb")
            table = resource.Table(table_name or os.environ["STASH_IMPORT_TABLE"])
        self.table = table
        self.table_name = getattr(table, "name", table_name or os.environ.get("STASH_IMPORT_TABLE", ""))
        self.user_id = user_id
        self._client = getattr(getattr(table, "meta", None), "client", None)

    @property
    def partition(self) -> str:
        return f"INSTALL#{self.user_id}"

    def _key(self, import_id: str, suffix: str) -> dict[str, str]:
        return {"PK": self.partition, "SK": f"IMPORT#{import_id}#{suffix}"}

    def _client_key(self, client_import_id) -> dict[str, str]:
        return {"PK": self.partition, "SK": f"CLIENT#{client_import_id}"}

    def _quota_key(self) -> dict[str, str]:
        return {"PK": self.partition, "SK": "QUOTA"}

    def _deep_pass_key(self) -> dict[str, str]:
        return {"PK": self.partition, "SK": "DEEPPASS"}

    def _get(self, key: dict[str, str]) -> dict[str, Any] | None:
        return self.table.get_item(Key=key).get("Item")

    def _transact(self, operations: list[dict[str, Any]]) -> None:
        if self._client is not None and hasattr(self._client, "transact_write_items"):
            self._client.transact_write_items(TransactItems=operations)
            return
        # Small fake-table fallback used by local contract tests. Production uses the
        # transaction path above, which keeps stage and counters atomic. This parser
        # understands exactly the expression shapes this module emits and raises on
        # anything else: a fallback that *guesses* would let a wrong arithmetic result
        # pass green in tests while production diverged.
        for operation in operations:
            if "Put" in operation:
                self.table.put_item(Item=operation["Put"]["Item"])
            elif "Update" in operation:
                update = operation["Update"]
                key = update["Key"]
                item = self._get(key) or key.copy()
                names = update.get("ExpressionAttributeNames", {})
                values = update.get("ExpressionAttributeValues", {})
                expression = update.get("UpdateExpression", "")
                if not expression.startswith("SET "):
                    raise NotImplementedError(f"fallback cannot apply {expression!r}")
                for assignment in expression[4:].split(", "):
                    name, value = [part.strip() for part in assignment.split("=", 1)]
                    field = names.get(name, name)
                    for operator, apply in ((" + ", int.__add__), (" - ", int.__sub__)):
                        if operator in value:
                            base, operand = [part.strip() for part in value.split(operator, 1)]
                            item[field] = apply(int(item.get(names.get(base, base), 0)), int(values[operand]))
                            break
                    else:
                        if value not in values:
                            raise NotImplementedError(f"fallback cannot evaluate {value!r}")
                        item[field] = values[value]
                self.table.put_item(Item=item)
            else:
                raise NotImplementedError(f"fallback cannot apply {sorted(operation)}")

    def get_client_import(self, client_import_id) -> dict[str, Any] | None:
        """The dedupe row for a client import id, or None when this is a first submission."""
        return self._get(self._client_key(client_import_id))

    def create_import(self, request: CreateImportRequest, *, deferred: int = 0) -> CreateImportResult:
        """Stage `request`, which the caller may already have truncated to what the budget
        covered; `deferred` is how many it dropped. Stored on both rows so a retry and a
        later status poll report the same split instead of claiming the library landed whole.
        """
        client_key = self._client_key(request.client_import_id)
        existing = self._get(client_key)
        if existing:
            return CreateImportResult(existing["importID"], False, int(existing.get("accepted", 0)),
                                      deferred=int(existing.get("deferred", 0)))

        # Derive the import id from the client id so a client retry after a partial create
        # resumes onto the same rows instead of orphaning a fresh import each time. Salted
        # with the user so one account cannot derive (or collide with) another's import id
        # by reusing its clientImportID — the id travels in URLs.
        import_id = str(uuid.uuid5(uuid.NAMESPACE_URL, f"stash-import/{self.user_id}/{request.client_import_id}"))
        now = _now()

        # Stage the video rows first, one at a time. DynamoDB transactions cap at 100
        # items, so a 900-video import cannot be one transaction; and the import only
        # counts as "created" once the client+META anchor below lands, so a crash
        # mid-stage is safely resumed by the client's retry onto these same rows.
        self._ensure_videos(import_id, request.videos)

        meta = {
            **self._key(import_id, "META"),
            "importID": import_id,
            "state": ImportState.ACCEPTED.value,
            "total": len(request.videos),
            "fastDone": 0,
            "unavailable": 0,
            "partialFailures": 0,
            "deferred": deferred,
            "estimatedCostUSD": Decimal("0"),
            "updatedAt": now,
        }
        client_item = {
            **client_key,
            "importID": import_id,
            "accepted": len(request.videos),
            "deferred": deferred,
            "createdAt": now,
        }
        operations = [
            {"Put": {"TableName": self.table_name, "Item": client_item, "ConditionExpression": "attribute_not_exists(PK)"}},
            {"Put": {"TableName": self.table_name, "Item": meta, "ConditionExpression": "attribute_not_exists(PK)"}},
        ]
        try:
            self._transact(operations)
        except Exception as error:
            if not _is_conditional_failure(error):
                raise
            existing = self._get(client_key)
            if not existing:
                raise
            return CreateImportResult(existing["importID"], False, int(existing.get("accepted", 0)),
                                      deferred=int(existing.get("deferred", 0)))
        return CreateImportResult(import_id, True, len(request.videos), deferred=deferred)

    def _ensure_videos(self, import_id: str, videos) -> None:
        """Create one QUEUED row per video if absent — idempotent across client retries."""
        now = _now()
        for video in videos:
            item = {
                **self._key(import_id, f"VIDEO#{video.video_id}"),
                "videoID": video.video_id,
                "url": video.url,
                "bookmarkedAt": video.bookmarked_at.isoformat(),
                "state": VideoState.QUEUED.value,
                "attempts": 0,
                "updatedAt": now,
            }
            try:
                self.table.put_item(Item=item, ConditionExpression="attribute_not_exists(PK)")
            except Exception as error:
                if not _is_conditional_failure(error):
                    raise

    def claim_video(self, import_id: str, video_id: str) -> bool:
        key = self._key(import_id, f"VIDEO#{video_id}")
        values = {
            ":running": VideoState.RUNNING.value,
            ":queued": VideoState.QUEUED.value,
            ":retryable": VideoState.RETRYABLE.value,
            ":updated": _now(),
            ":stale": (datetime.now(timezone.utc) - timedelta(seconds=CLAIM_LEASE_SECONDS)).isoformat(),
        }
        try:
            if hasattr(self.table, "update_item"):
                self.table.update_item(
                    Key=key,
                    UpdateExpression="SET #state = :running, updatedAt = :updated",
                    ConditionExpression="#state IN (:queued, :retryable) OR (#state = :running AND updatedAt < :stale)",
                    ExpressionAttributeNames={"#state": "state"},
                    ExpressionAttributeValues=values,
                )
            else:
                item = self._get(key)
                if not item or (
                    item.get("state") not in {VideoState.QUEUED.value, VideoState.RETRYABLE.value}
                    and not (item.get("state") == VideoState.RUNNING.value and _is_stale_claim(item.get("updatedAt")))
                ):
                    return False
                item.update(state=VideoState.RUNNING.value, updatedAt=values[":updated"])
                self.table.put_item(Item=item)
        except Exception as error:
            if _is_conditional_failure(error):
                return False
            raise
        self._mark_fast_pass(import_id)
        return True

    def get_video(self, import_id: str, video_id: str) -> dict[str, Any] | None:
        return self._get(self._key(import_id, f"VIDEO#{video_id}"))

    def pending_videos(self, import_id: str) -> list[tuple[str, str | None]]:
        """(video_id, url) for every row still waiting on a worker.

        Backs the re-drive on a client retry: the rows are staged before the messages go
        out, so an enqueue loop that dies halfway leaves paid-for videos that no worker
        will ever see. Nothing else in the system revisits a QUEUED row.
        """
        waiting = {VideoState.QUEUED.value, VideoState.RETRYABLE.value}
        return [
            (item["videoID"], item.get("url"))
            for page in self._pages(f"IMPORT#{import_id}#VIDEO#")
            for item in page.get("Items", [])
            if item.get("state") in waiting
        ]

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
                    "ConditionExpression": "fastDone < #total",
                    "ExpressionAttributeNames": {"#total": "total"},
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
        attempts = int(item.get("attempts", 0)) + 1
        # Retry a transient failure — but only until the attempt budget runs out. Past
        # that we fall through to a terminal failure so the video stops being redelivered
        # and the import can finalize instead of stalling on a dead-lettered job.
        if retryable and attempts < MAX_FAST_PASS_ATTEMPTS:
            now = _now()
            if hasattr(self.table, "update_item"):
                try:
                    self.table.update_item(
                        Key=key,
                        UpdateExpression="SET #state = :retryable, attempts = :attempts, errorCode = :code, updatedAt = :updated",
                        ConditionExpression="#state IN (:running, :retryable)",
                        ExpressionAttributeNames={"#state": "state"},
                        ExpressionAttributeValues={":retryable": VideoState.RETRYABLE.value, ":running": VideoState.RUNNING.value, ":attempts": attempts, ":code": code, ":updated": now},
                    )
                except Exception as error:
                    if _is_conditional_failure(error):
                        return False
                    raise
            else:
                item.update(state=VideoState.RETRYABLE.value, attempts=attempts, errorCode=code, updatedAt=now)
                self.table.put_item(Item=item)
            return True
        meta = self._get(self._key(import_id, "META"))
        if not meta or item.get("state") not in {VideoState.RUNNING.value, VideoState.RETRYABLE.value}:
            return False
        now = _now()
        if self._client is not None and hasattr(self._client, "transact_write_items"):
            operations = [
                {
                    "Update": {
                        "TableName": self.table_name,
                        "Key": key,
                        "UpdateExpression": "SET #state = :failed, attempts = :attempts, errorCode = :code, updatedAt = :updated",
                        "ConditionExpression": "#state IN (:running, :retryable)",
                        "ExpressionAttributeNames": {"#state": "state"},
                        "ExpressionAttributeValues": {":failed": VideoState.FAILED.value, ":running": VideoState.RUNNING.value, ":retryable": VideoState.RETRYABLE.value, ":attempts": attempts, ":code": code, ":updated": now},
                    }
                },
                {
                    "Update": {
                        "TableName": self.table_name,
                        "Key": self._key(import_id, "META"),
                        "UpdateExpression": "SET fastDone = fastDone + :one, partialFailures = partialFailures + :one, updatedAt = :updated",
                        "ConditionExpression": "fastDone < #total",
                        "ExpressionAttributeNames": {"#total": "total"},
                        "ExpressionAttributeValues": {":one": 1, ":updated": now},
                    }
                },
            ]
            try:
                self._transact(operations)
            except Exception as error:
                if _is_conditional_failure(error):
                    return False
                raise
            self._try_finalize(import_id)
            return True
        item.update(state=VideoState.FAILED.value, attempts=attempts, errorCode=code, updatedAt=_now())
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
                        ConditionExpression="fastDone = #total AND #state <> :completed",
                        ExpressionAttributeNames={"#state": "state", "#total": "total"},
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
            deferred=int(item.get("deferred", 0)),
            estimatedCostUSD=float(item.get("estimatedCostUSD", 0)),
            updatedAt=item["updatedAt"],
        )

    def _condition(self, sk_prefix: str):
        """Key condition for this user's partition, boto-shaped or fake-shaped."""
        if hasattr(self.table, "meta"):
            from boto3.dynamodb.conditions import Key
            if not sk_prefix:
                return Key("PK").eq(self.partition)
            return Key("PK").eq(self.partition) & Key("SK").begins_with(sk_prefix)
        return (self.partition, sk_prefix)

    def _pages(self, sk_prefix: str, start_key: dict[str, str] | None = None, limit: int | None = None):
        """Yield raw Query pages. Paged because a user's partition holds every import
        they ever made — the old unbounded read would pull thousands of rows per poll."""
        expression = self._condition(sk_prefix)
        while True:
            arguments: dict[str, Any] = {"KeyConditionExpression": expression}
            if limit:
                arguments["Limit"] = limit
            if start_key:
                arguments["ExclusiveStartKey"] = start_key
            page = self.table.query(**arguments)
            yield page
            start_key = page.get("LastEvaluatedKey")
            if not start_key:
                return

    def iter_user_items(self) -> Iterator[dict[str, Any]]:
        """Every item stored for this user. Backs GET /v1/me/export and DELETE /v1/me."""
        for page in self._pages(""):
            yield from page.get("Items", [])

    def delete_user_items(self) -> list[dict[str, str]]:
        """Delete the whole partition; returns the keys removed so the caller can clean
        up the refresh-token lookup rows that live outside it. Loops until a Query comes
        back empty because a worker write can land mid-delete."""
        removed: list[dict[str, str]] = []
        while True:
            keys = [{"PK": item["PK"], "SK": item["SK"]} for item in self.iter_user_items()]
            if not keys:
                return removed
            removed.extend(keys)
            if hasattr(self.table, "batch_writer"):
                with self.table.batch_writer() as batch:  # chunks into BatchWriteItem for us
                    for key in keys:
                        batch.delete_item(Key=key)
            else:
                for key in keys:
                    self.table.delete_item(Key=key)

    # ------------------------------------------------------------------ quota

    def _quota_values(self, item: dict[str, Any] | None) -> tuple[int, int, int, int, int]:
        """Effective (trial, initial, month, reset, ceiling), rolling the month window in memory.

        The roll is computed on read and persisted by the next write, so a user who does
        not call for two months still sees a correct counter without a scheduled job. Only
        the month bucket rolls: trial and initial are lifetime figures by definition.

        `ceiling` is the row's own initial allowance. It is stored rather than taken from
        INITIAL_LIMIT so an account can be topped up past the standard budget by hand
        (update-item on initialLimit + initialRemaining) without the refund path treating
        the surplus as overflow and the app rendering "1000 of 500 left". Absent on every
        row written before this, which is what the default covers.
        """
        now = datetime.now(timezone.utc)
        if not item:
            return TRIAL_LIMIT, INITIAL_LIMIT, MONTH_LIMIT, _next_month_reset(now), INITIAL_LIMIT
        trial = int(item.get("trialRemaining", TRIAL_LIMIT))
        initial = int(item.get("initialRemaining", INITIAL_LIMIT))
        month = int(item.get("monthRemaining", MONTH_LIMIT))
        reset = int(item.get("monthResetAt", 0))
        ceiling = max(int(item.get("initialLimit", INITIAL_LIMIT)), initial)
        if int(now.timestamp()) >= reset:
            return trial, initial, MONTH_LIMIT, _next_month_reset(now), ceiling
        return trial, initial, month, reset, ceiling

    @staticmethod
    def _quota(trial: int, initial: int, month: int, reset: int, ceiling: int) -> Quota:
        return Quota(trialRemaining=trial, initialRemaining=initial,
                     monthRemaining=month, monthResetAt=reset, initialLimit=ceiling)

    def get_quota(self) -> Quota:
        return self._quota(*self._quota_values(self._get(self._quota_key())))

    def _write_quota(self, units: int) -> Quota | None:
        """Compare-and-set the quota row by `units` (negative spends, positive refunds).

        The condition pins all three stored values, so two concurrent requests can never
        both spend the last unit: the loser's condition fails and it re-reads.
        """
        key = self._quota_key()
        for _ in range(QUOTA_CAS_ATTEMPTS):
            item = self._get(key)
            trial, initial, month, reset, ceiling = self._quota_values(item)
            if units < 0:
                # Trial first, then the lifetime allowance, then the month. A user is only
                # ever in one of those states, so in practice a spend touches one bucket.
                from_trial = min(trial, -units)
                from_initial = min(initial, -units - from_trial)
                from_month = -units - from_trial - from_initial
                if from_month > month:
                    return None
                new_trial = trial - from_trial
                new_initial, new_month = initial - from_initial, month - from_month
            else:
                # Refunds fill the month bucket first — the exact mirror of a trial-first
                # spend. Paying a month-bucket spend back into `initialRemaining` would look
                # right today and mint budget on the 1st, because only the month bucket is
                # reset: 100 units spent and refunded would come back as 150. The trial fills
                # last for the same reason, one step further out: it never resets at all, so
                # a refund landing there is budget that can never be re-earned.
                # Headroom is measured against the row's own ceiling and floored at zero: a
                # refund must never be able to compute a negative and subtract it.
                to_month = max(0, min(units, MONTH_LIMIT - month))
                new_month = month + to_month
                to_initial = max(0, min(units - to_month, ceiling - initial))
                new_initial = initial + to_initial
                new_trial = min(TRIAL_LIMIT, trial + units - to_month - to_initial)
            now = _now()
            try:
                if item is None:
                    self.table.put_item(
                        Item={**key, "trialRemaining": new_trial, "initialRemaining": new_initial,
                              "monthRemaining": new_month, "monthResetAt": reset,
                              "initialLimit": ceiling, "updatedAt": now},
                        ConditionExpression="attribute_not_exists(PK)",
                    )
                else:
                    # Pin what the row actually stores, not what it defaults to. A bucket added
                    # after a row was written (trialRemaining) is *absent*, and "absent = 50"
                    # is false in DynamoDB however the read defaulted it — so an equality pin
                    # failed on every one of the eight attempts and every import 500'd on the
                    # contention guard below. attribute_not_exists is still a race-safe pin:
                    # any writer SETs all five at once, so a row that gained the attribute
                    # under us loses the condition exactly as an equality mismatch would.
                    pins, pinned = [], {}
                    for name in ("trialRemaining", "initialRemaining", "monthRemaining",
                                 "monthResetAt", "initialLimit"):
                        stored = item.get(name)
                        if stored is None:
                            pins.append(f"attribute_not_exists({name})")
                        else:
                            pins.append(f"{name} = :p_{name}")
                            pinned[f":p_{name}"] = int(stored)
                    self.table.update_item(
                        Key=key,
                        UpdateExpression="SET trialRemaining = :nt, initialRemaining = :ni, monthRemaining = :nm, monthResetAt = :reset, initialLimit = :ceiling, updatedAt = :now",
                        ConditionExpression=" AND ".join(pins),
                        ExpressionAttributeValues={
                            ":nt": new_trial, ":ni": new_initial, ":nm": new_month,
                            ":reset": reset, ":ceiling": ceiling, ":now": now, **pinned,
                        },
                    )
            except Exception as error:
                if _is_conditional_failure(error):
                    continue
                raise
            return self._quota(new_trial, new_initial, new_month, reset, ceiling)
        raise RuntimeError("quota contention: compare-and-set did not settle")

    def reserve_quota(self, units: int) -> Quota | None:
        """Spend `units`, free trial first. None means exhausted — the caller 402s."""
        return self._write_quota(-units) if units > 0 else self.get_quota()

    def refund_quota(self, units: int) -> Quota:
        """Give `units` back after work that was charged for but did not happen."""
        return self._write_quota(units) if units > 0 else self.get_quota()

    # -------------------------------------------------------------- deep-pass cap

    def charge_deep_pass(self, cap: int) -> bool:
        """Count one deep-pass call against today's allowance; False means the cap is reached.

        One item beside QUOTA, holding the UTC day it counts and the count. The day is what
        resets it — a call on a new day overwrites yesterday's number instead of adding to it
        — so this needs no scheduled sweep, exactly like the month roll above.

        Compare-and-set on the same terms as the quota row: the condition pins both stored
        values, so two concurrent deep-pass calls cannot both take the last one.
        """
        key = self._deep_pass_key()
        today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        for _ in range(QUOTA_CAS_ATTEMPTS):
            item = self._get(key)
            used = int(item.get("usedToday", 0)) if item and item.get("utcDay") == today else 0
            if used >= cap:
                return False
            try:
                if item is None:
                    self.table.put_item(
                        Item={**key, "utcDay": today, "usedToday": 1, "updatedAt": _now()},
                        ConditionExpression="attribute_not_exists(PK)",
                    )
                else:
                    self.table.update_item(
                        Key=key,
                        UpdateExpression="SET utcDay = :today, usedToday = :used, updatedAt = :now",
                        ConditionExpression="utcDay = :prevDay AND usedToday = :prevUsed",
                        ExpressionAttributeValues={
                            ":today": today, ":used": used + 1, ":now": _now(),
                            ":prevDay": item.get("utcDay"),
                            ":prevUsed": int(item.get("usedToday", 0)),
                        },
                    )
            except Exception as error:
                if _is_conditional_failure(error):
                    continue
                raise
            return True
        raise RuntimeError("deep-pass cap contention: compare-and-set did not settle")

    def list_results(self, import_id: str, cursor: str | None = None, limit: int = 50) -> ResultPage:
        prefix = f"IMPORT#{import_id}#VIDEO#"
        start_key = {"PK": self.partition, "SK": f"{prefix}{cursor}"} if cursor else None
        terminal = {VideoState.COMPLETED.value, VideoState.UNAVAILABLE.value, VideoState.FAILED.value}
        results: list[VideoResult] = []
        for page in self._pages(prefix, start_key=start_key, limit=limit):
            for item in page.get("Items", []):
                if item.get("state") not in terminal:
                    continue
                raw_result = item.get("result") or {
                    "videoID": item["videoID"],
                    "unavailable": item.get("state") == VideoState.UNAVAILABLE.value,
                    "errorCode": item.get("errorCode"),
                }
                results.append(VideoResult.model_validate(raw_result))
                if len(results) >= limit:
                    break
            if len(results) >= limit:
                break
        next_cursor = results[-1].video_id if len(results) == limit else None
        return ResultPage(results=results, nextCursor=next_cursor)
