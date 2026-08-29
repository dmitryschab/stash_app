"""Stash — TikTok Data Portability webhook receiver, and the app that mounts /v1.

Receives TikTok's "archive ready" webhooks, verifies the signature, and durably
records each event. The archive download + favourite extraction is a separate
worker built once the app is approved and we can see a real payload.

Everything under /v1 lives in five routers: stash_auth (sign-in and account),
api_v1 (transcript, analyzer proxy, transient media), cloud_import_api (imports),
embeddings_api (search vectors) and haul_offers_api (live prices for picks).
Only /health and /v1/auth/* are reachable without a per-user Stash JWT.
"""
import hashlib
import hmac
import json
import logging
import os
import time

from fastapi import FastAPI, HTTPException, Request, Response
from fastapi.encoders import jsonable_encoder
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

import stash_logging
import stash_secrets

stash_logging.configure()
log = logging.getLogger("stash-webhook")

# Secrets Manager on the box, environment locally. Empty + STASH_DEV_MODE=1 = dev mode.
CLIENT_SECRET = stash_secrets.secret("TIKTOK_CLIENT_SECRET")
EVENTS_LOG = os.environ.get("STASH_EVENTS_LOG", "/var/lib/stash-webhook/events.jsonl")

# TikTok's "archive ready" payloads are a few hundred bytes. The cap is generous enough
# that a real event can never hit it and small enough that the one public, unauthenticated
# route cannot be used to buffer a box-sized body before the signature is even checked.
WEBHOOK_MAX_BYTES = 64_000

# Reachability probes are cached: /health is public and unauthenticated, so an uncached
# probe would let anyone bill us two AWS API calls per request.
HEALTH_CACHE_SECONDS = 15
_health_cache: dict = {"checked_at": 0.0, "result": {}}

app = FastAPI(title="Stash webhook receiver")

import stash_auth  # noqa: E402
from stash_auth import router as auth_router  # noqa: E402
app.include_router(auth_router)
# /v1 pipeline API (transcript, analyze proxy, transient media) — see api_v1.py.
from api_v1 import router as v1_router  # noqa: E402
app.include_router(v1_router)
from cloud_import_api import router as cloud_import_router  # noqa: E402
app.include_router(cloud_import_router)
# Search's meaning half — one route, its own module, no quota. See embeddings_api.py.
from embeddings_api import router as embeddings_router  # noqa: E402
app.include_router(embeddings_router)
# Haul's price check — one route, a daily cap instead of quota. See haul_offers_api.py.
from haul_offers_api import router as haul_offers_router  # noqa: E402
app.include_router(haul_offers_router)


@app.exception_handler(stash_auth.QuotaExhausted)
async def quota_exhausted_handler(request: Request, exc: stash_auth.QuotaExhausted):
    """402 with "detail" and "quota" as top-level siblings, per the API contract."""
    return JSONResponse(status_code=402, content=exc.body())


@app.exception_handler(RequestValidationError)
async def validation_failed_handler(request: Request, exc: RequestValidationError):
    """Same 422 body FastAPI would send, plus a server-side line saying which field failed.

    Without this a rejected payload is a bare "status": 422 in the access log and the only
    copy of the reason is on the phone that sent it — which is a debugging dead end when the
    client is a shipped iOS build. Logs the field path and message, never the value: a
    bookmark URL is user content and has no business in the journal.
    """
    log.warning("request rejected", extra={
        "method": request.method,
        "path": request.url.path,
        "userID": getattr(request.state, "user_id", None),
        "errors": [{"loc": ".".join(str(part) for part in error.get("loc", ())),
                    "msg": error.get("msg"), "type": error.get("type")}
                   for error in exc.errors()[:10]],
    })
    return JSONResponse(status_code=422, content=jsonable_encoder({"detail": exc.errors()}))


@app.middleware("http")
async def access_log(request: Request, call_next):
    """One structured line per request. userID is set by the current_user dependency,
    so it is present exactly on the requests that actually authenticated."""
    started = time.perf_counter()
    try:
        response = await call_next(request)
    except Exception:
        log.exception("request failed", extra={"method": request.method, "path": request.url.path,
                                               "userID": getattr(request.state, "user_id", None)})
        raise
    log.info("request", extra={
        "method": request.method,
        "path": request.url.path,
        "status": response.status_code,
        "durationMs": round((time.perf_counter() - started) * 1000, 1),
        "userID": getattr(request.state, "user_id", None),
    })
    return response


def _dependency_health() -> dict[str, str]:
    checks = {}
    try:
        from cloud_import_store import shared_table
        shared_table().table_status
        checks["dynamodb"] = "ok"
    except Exception as error:
        log.warning("dynamodb health probe failed: %s", error)
        checks["dynamodb"] = "error"
    try:
        from cloud_import_queue import SQSImportQueue
        queue = SQSImportQueue()
        queue.client.get_queue_attributes(QueueUrl=queue.queue_url, AttributeNames=["QueueArn"])
        checks["sqs"] = "ok"
    except Exception as error:
        log.warning("sqs health probe failed: %s", error)
        checks["sqs"] = "error"
    # Sign in with Apple revocation (guideline 5.1.1(v)) degrades silently by design — a
    # missing Apple key must never break sign-in — so this is the one place it is visible.
    # deploy.sh refuses to deploy without the three; this catches a box emptied afterwards.
    checks["appleRevocation"] = "ok" if all(
        stash_secrets.secret(name)
        for name in ("APPLE_TEAM_ID", "APPLE_KEY_ID", "APPLE_PRIVATE_KEY")
    ) else "unconfigured"
    return checks


@app.get("/health")
def health():
    now = time.monotonic()
    if now - _health_cache["checked_at"] >= HEALTH_CACHE_SECONDS:
        _health_cache["result"] = _dependency_health()
        _health_cache["checked_at"] = now
    checks = _health_cache["result"]
    return {
        "status": "ok" if all(value == "ok" for value in checks.values()) else "degraded",
        "service": "stash-webhook",
        "verify": bool(CLIENT_SECRET),
        "checks": checks,
    }


def verify_signature(raw: bytes, header_sig: str | None) -> bool:
    """HMAC-SHA256 over the raw body, keyed by the app's client secret.

    ponytail: header name + exact signing scheme get pinned once we see a real TikTok
    event post-approval. Production is fail-CLOSED — a missing secret rejects everything
    unless STASH_DEV_MODE=1 is explicitly set, because "nobody configured it yet" used to
    look exactly like "verification passed".
    """
    if not CLIENT_SECRET:
        return os.environ.get("STASH_DEV_MODE") == "1"
    if not header_sig:
        return False
    expected = hmac.new(CLIENT_SECRET.encode(), raw, hashlib.sha256).hexdigest()
    # Compare bytes, not str: header values reach us latin-1-decoded, and compare_digest
    # raises TypeError on any str holding a codepoint above 0x7F. One such byte in the
    # signature header turned this public, unauthenticated route into a 500 plus a full
    # logged traceback — a rejection has to be a rejection, not an exception.
    return hmac.compare_digest(expected.encode(), header_sig.encode())


async def _read_capped(request: Request, limit: int) -> bytes | None:
    """The request body, or None once it exceeds `limit`.

    Read by streaming rather than `await request.body()`: this route is public and
    unauthenticated and has to buffer the whole body to HMAC it, so an uncapped read let
    any caller exhaust a 1 GB box's memory with one long POST. Streaming also covers a
    chunked request, where there is no Content-Length to check up front.
    """
    chunks: list[bytes] = []
    total = 0
    async for chunk in request.stream():
        total += len(chunk)
        if total > limit:
            return None
        chunks.append(chunk)
    return b"".join(chunks)


@app.post("/webhook/tiktok")
async def tiktok_webhook(request: Request):
    raw = await _read_capped(request, WEBHOOK_MAX_BYTES)
    if raw is None:
        log.warning("rejected webhook: body over %d bytes", WEBHOOK_MAX_BYTES)
        raise HTTPException(status_code=413, detail="payload too large")
    sig = request.headers.get("x-tiktok-signature") or request.headers.get("x-signature")
    if not verify_signature(raw, sig):
        log.warning("rejected webhook: bad signature")
        raise HTTPException(status_code=401, detail="bad signature")
    try:
        event = json.loads(raw or b"{}")
    except json.JSONDecodeError:
        event = {"_raw": raw.decode("utf-8", "replace")}
    os.makedirs(os.path.dirname(EVENTS_LOG), exist_ok=True)
    with open(EVENTS_LOG, "a") as f:
        f.write(json.dumps({"received_at": int(time.time()), "event": event}) + "\n")
    log.info("stored webhook event (%d bytes)", len(raw))
    return Response(status_code=200)  # ack fast; TikTok expects a prompt 200
