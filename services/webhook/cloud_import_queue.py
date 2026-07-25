"""SQS adapter for one-message-per-video fast-pass work."""

from __future__ import annotations

import json
import os
from typing import Any

from cloud_import_aws import instance_role_session

# Bumped when the message body changes shape. v2 added the owning userID.
MESSAGE_SCHEMA = 2


class SQSImportQueue:
    def __init__(self, client=None, queue_url: str | None = None):
        self.client = client or instance_role_session().client("sqs")
        self.queue_url = queue_url or os.environ["STASH_IMPORT_QUEUE_URL"]

    def enqueue(self, user_id: str, import_id: str, video_id: str, url: str | None = None) -> dict[str, Any]:
        """Carry the owning user in the message so the worker can build a scoped store.

        `v` is a schema marker: the worker discards anything that is not v2 rather than
        guessing, so pre-cutover messages still in flight are dropped, not mis-routed
        into some other account's partition.
        """
        message = {"v": MESSAGE_SCHEMA, "userID": user_id, "importID": import_id,
                   "videoID": video_id, "stage": "fast_pass"}
        if url:
            message["url"] = url
        response = self.client.send_message(QueueUrl=self.queue_url, MessageBody=json.dumps(message, separators=(",", ":")))
        return {**message, "messageID": response.get("MessageId")}

    def receive(self, max_messages: int = 1, wait_time_seconds: int = 20) -> list[dict[str, Any]]:
        response = self.client.receive_message(
            QueueUrl=self.queue_url,
            MaxNumberOfMessages=max_messages,
            WaitTimeSeconds=wait_time_seconds,
            VisibilityTimeout=300,
        )
        messages = []
        for raw in response.get("Messages", []):
            body = json.loads(raw["Body"])
            messages.append({**body, "receiptHandle": raw["ReceiptHandle"], "messageID": raw.get("MessageId")})
        return messages

    def delete(self, receipt_handle: str) -> None:
        self.client.delete_message(QueueUrl=self.queue_url, ReceiptHandle=receipt_handle)

    def extend_visibility(self, receipt_handle: str, timeout_seconds: int = 300) -> None:
        self.client.change_message_visibility(
            QueueUrl=self.queue_url,
            ReceiptHandle=receipt_handle,
            VisibilityTimeout=timeout_seconds,
        )
