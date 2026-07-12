"""Stash — TikTok Data Portability webhook receiver.

Receives TikTok's "archive ready" webhooks, verifies the signature, and durably
records each event. The archive download + favourite extraction is a separate
worker built once the app is approved and we can see a real payload.
"""
import hashlib
import hmac
import json
import logging
import os
import time

from fastapi import FastAPI, HTTPException, Request, Response

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("stash-webhook")

# Set via /etc/stash-webhook/env (systemd EnvironmentFile). Empty = dev mode, no verification.
CLIENT_SECRET = os.environ.get("TIKTOK_CLIENT_SECRET", "")
EVENTS_LOG = os.environ.get("STASH_EVENTS_LOG", "/var/lib/stash-webhook/events.jsonl")

app = FastAPI(title="Stash webhook receiver")


@app.get("/health")
def health():
    return {"status": "ok", "service": "stash-webhook", "verify": bool(CLIENT_SECRET)}


def verify_signature(raw: bytes, header_sig: str | None) -> bool:
    """HMAC-SHA256 over the raw body, keyed by the app's client secret.

    ponytail: header name + exact signing scheme get pinned once we see a real
    TikTok event post-approval. Until a secret is configured we run open (dev).
    """
    if not CLIENT_SECRET:
        return True
    if not header_sig:
        return False
    expected = hmac.new(CLIENT_SECRET.encode(), raw, hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, header_sig)


@app.post("/webhook/tiktok")
async def tiktok_webhook(request: Request):
    raw = await request.body()
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
