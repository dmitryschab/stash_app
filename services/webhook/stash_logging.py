"""One JSON line per log record, shared by the API and the import worker.

journald keeps these as-is, so `journalctl -u stash-webhook -o cat | jq` is the whole
log-analysis stack. Request fields (method/path/status/durationMs/userID) arrive through
`logging`'s `extra=`; anything absent is simply omitted rather than logged as null.
"""

from __future__ import annotations

import json
import logging
import time

# Everything a caller may attach with extra=. Kept explicit so a typo in a call site
# silently drops one field instead of dumping the whole LogRecord into the line.
REQUEST_FIELDS = ("method", "path", "status", "durationMs", "userID", "messageID")


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        payload = {
            "ts": time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(record.created)) + "Z",
            "level": record.levelname,
            "logger": record.name,
            "msg": record.getMessage(),
        }
        for field in REQUEST_FIELDS:
            value = getattr(record, field, None)
            if value is not None:
                payload[field] = value
        if record.exc_info:
            payload["exc"] = self.formatException(record.exc_info)
        return json.dumps(payload, default=str)


def configure(level: int = logging.INFO) -> None:
    handler = logging.StreamHandler()
    handler.setFormatter(JsonFormatter())
    root = logging.getLogger()
    root.handlers = [handler]  # replace, so uvicorn's default text handler does not double-log
    root.setLevel(level)
