"""Stash /v1 embeddings — the call behind "Meaning, not just keywords".

  POST /v1/embeddings  {texts: [...]} -> {vectors: [[float]], model, dims}

Its own module and its own router, mounted in app.py, so api_v1.py keeps carrying exactly the
three routes it documents.

Not the Mantle endpoint the analyzer proxies to: `bedrock-mantle.eu-central-1.api.aws` serves
`/openai/v1/chat/completions` but answers 404 for `/openai/v1/embeddings`, for every embedding
model in the region — checked against the live endpoint, not assumed. So this goes straight at
`bedrock-runtime` in the same region, which boto3 already speaks.

Titan v2 at 256 dimensions, normalized by the model. 256 because the whole point is a vector per
save sitting in SwiftData on a phone (1200 saves x 256 floats = 1.2 MB, and cosine over it is
free); Titan v2 because it is multilingual, and captions and transcripts here are in any
language.

Costs no quota. Embedding is a fraction of a cent per library, and the video was already charged
for at import — being able to find a save again must not cost as much as saving it. What bounds
the route instead is its shape: at most 32 texts of at most 8 KB per request.
"""
import json
import logging

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from cloud_import_store import DynamoImportStore
from stash_auth import entitled_store

log = logging.getLogger("stash-webhook")

router = APIRouter(prefix="/v1")

EMBEDDING_REGION = "eu-central-1"
EMBEDDING_MODEL = "amazon.titan-embed-text-v2:0"
EMBEDDING_DIMS = 256

# One request is one backfill batch on the client, and a save's embed text is title + topics +
# summary + caption + a slice of transcript and OCR — well under a kilobyte in practice.
MAX_TEXTS = 32
MAX_TEXT_BYTES = 8 * 1024

_runtime_client = None


def _runtime():
    """Built on first use, not at import: a module-level client would make pytest and
    `python embeddings_api.py` reach for instance metadata off-box."""
    global _runtime_client
    if _runtime_client is None:
        import boto3
        _runtime_client = boto3.client("bedrock-runtime", region_name=EMBEDDING_REGION)
    return _runtime_client


def _embed(text: str) -> list[float]:
    # Titan rejects an empty inputText, and one blank string would fail the whole batch. A zero
    # vector is also the honest answer: it is cosine-0 against every query, which is what a save
    # with nothing written about it should score.
    if not text.strip():
        return [0.0] * EMBEDDING_DIMS
    response = _runtime().invoke_model(
        modelId=EMBEDDING_MODEL,
        body=json.dumps({"inputText": text, "dimensions": EMBEDDING_DIMS, "normalize": True}),
    )
    return json.loads(response["body"].read())["embedding"]


class EmbeddingsRequest(BaseModel):
    texts: list[str]


@router.post("/embeddings")
def embeddings(body: EmbeddingsRequest, store: DynamoImportStore = Depends(entitled_store)):
    """One vector per text, in the order they were sent.

    `entitled_store` rather than `user_store`: this reaches Bedrock, so it is spending, and the
    subscription check is what stops a stranger signing in and spending it. No quota moves.
    """
    texts = body.texts
    if not texts or len(texts) > MAX_TEXTS:
        raise HTTPException(status_code=422, detail=f"1..{MAX_TEXTS} texts per request")
    if any(len(text.encode("utf-8")) > MAX_TEXT_BYTES for text in texts):
        raise HTTPException(status_code=422, detail=f"each text must be under {MAX_TEXT_BYTES} bytes")

    try:
        vectors = [_embed(text) for text in texts]
    except Exception as error:
        # The app treats any failure here as "no embedding" and silently stays lexical, so a bad
        # day at Bedrock costs search its meaning half and nothing else.
        log.warning("embedding failed: %s", error)
        raise HTTPException(status_code=502, detail="embeddings unavailable")

    return {"vectors": vectors, "model": EMBEDDING_MODEL, "dims": EMBEDDING_DIMS}
