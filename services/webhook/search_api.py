"""Stash /v1 search — Claude Haiku picks the saves that answer a request.

  POST /v1/search  {query, candidates: [{id, about}]} -> {ids: [str]}, best first

Its own module and its own router, mounted in app.py, like about_api before it.

The app still finds the candidates itself: its SearchIndex ranks the whole library by meaning and
words on the phone and sends the top few dozen, each with its about-text. Haiku reads them against
the request and answers with the ones that fit, best first. A request like "something quick and
vegetarian for tonight" is not a word any about-text says, and cosine alone cannot tell a recipe
from a restaurant review of the same dish; reading can. Only a pool goes up, never the library:
a library is thousands of saves, and Haiku past 100K tokens costs five times as much a token.

Candidates are numbered in the prompt and Haiku answers with the numbers, not the ids: a 19-digit
TikTok id copied back by a model is one wrong digit away from pointing at nothing. The answer is
held to a JSON schema (structured outputs), and a number that names no candidate is dropped.

Haiku runs in Claude in Amazon Bedrock, Frankfurt, under the box's existing Bedrock user — the
same region and account the about-texts were written in, so no new processor sees a library.

Money: one unit of a daily counter of its own (SEARCHCAP, beside ABOUTCAP) per request, charged
before the model is called, so a capped request costs nothing on the model. No quota moves:
finding a save again must not cost like saving it.

Failures are the app's to absorb: on anything but a 200 it shows the list its own ranking made.
The provider throttling, failing, slow or out of reach is a 503 with a Retry-After; a refusal, a
cut-off answer or one that does not parse is a 502.
"""
import json
import logging
import os

import anthropic
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from about_api import charge_daily
from cloud_import_store import DynamoImportStore
from stash_auth import entitled_store

log = logging.getLogger("stash-webhook")

router = APIRouter(prefix="/v1")

SEARCH_REGION = "eu-central-1"
SEARCH_MODEL = "anthropic.claude-haiku-5-5"
# The app sends at most this many: its ranking's top, which is where an answer to the request
# can be. 60 about-texts are ~3K tokens.
MAX_CANDIDATES = 60
MAX_QUERY_CHARS = 300
# One about-text is 2-4 sentences; Cyrillic is two bytes a letter.
MAX_ABOUT_BYTES = 2000
# What Haiku may pick: a screenful and a half. Past this it is listing, not choosing.
MAX_PICKS = 20
# Thinking counts against this, and at effort low it is a few hundred tokens at most; the answer
# itself is twenty small numbers.
SEARCH_MAX_TOKENS = 2048
# Under the app's deadline for this call (SearchView), with no retry: a retried answer would land
# after the app has already shown its own list.
SEARCH_TIMEOUT = 8
UPSTREAM_RETRY_AFTER = 60
# Requests per account per UTC day. At ~3K tokens in and a few hundred out, a search costs about
# $0.0005, so a user who spends all of these costs about $0.15 a day.
SEARCH_DAILY_CAP = 300

SEARCH_SYSTEM_PROMPT = f"""You help a person find short videos they saved. You get their request and a
numbered list of their saved videos, each described in a sentence or a few. Pick the videos that
answer the request: the ones they would want to open for it, best match first. Leave out a video
that only shares a word with the request but is about something else. Pick at most {MAX_PICKS}. If
nothing fits, pick none."""

PICKS_SCHEMA = {
    "type": "object",
    "properties": {"picks": {"type": "array", "items": {"type": "integer"}}},
    "required": ["picks"],
    "additionalProperties": False,
}


class Candidate(BaseModel):
    id: str
    about: str


class SearchRequest(BaseModel):
    query: str
    candidates: list[Candidate]


_client = None


def _haiku() -> anthropic.AnthropicBedrockMantle:
    """Built on first use, not at import, so pytest never reaches for AWS credentials."""
    global _client
    if _client is None:
        _client = anthropic.AnthropicBedrockMantle(
            aws_region=SEARCH_REGION, timeout=SEARCH_TIMEOUT, max_retries=0)
    return _client


def build_prompt(query: str, candidates: list[Candidate]) -> str:
    lines = [f"{number}: {' '.join(c.about.split())}"
             for number, c in enumerate(candidates, start=1)]
    return f"Request: {query}\n\nSaved videos:\n" + "\n".join(lines)


def pick(query: str, candidates: list[Candidate]) -> list[str]:
    """The ids Haiku picked, best first. Raises on a refusal or an answer that is not one."""
    response = _haiku().messages.create(
        model=SEARCH_MODEL,
        max_tokens=SEARCH_MAX_TOKENS,
        system=SEARCH_SYSTEM_PROMPT,
        output_config={"effort": "low",
                       "format": {"type": "json_schema", "schema": PICKS_SCHEMA}},
        messages=[{"role": "user", "content": build_prompt(query, candidates)}],
    )
    if response.stop_reason != "end_turn":  # refusal, or cut off before the JSON closed
        raise ValueError(f"search answer stopped: {response.stop_reason}")
    text = next(block.text for block in response.content if block.type == "text")
    ids: list[str] = []
    for number in json.loads(text)["picks"]:
        if isinstance(number, int) and 1 <= number <= len(candidates):
            picked = candidates[number - 1].id
            if picked not in ids:
                ids.append(picked)
    return ids[:MAX_PICKS]


def is_upstream_trouble(error: Exception) -> bool:
    """The provider, not the request: throttled, failing, slow or unreachable."""
    if isinstance(error, anthropic.APIConnectionError):  # APITimeoutError is one
        return True
    return isinstance(error, anthropic.APIStatusError) and (
        error.status_code == 429 or error.status_code >= 500)


def _daily_cap() -> int:
    """Read per call, not at import — same reason as api_v1._daily_cap."""
    return int(os.environ.get("SEARCH_DAILY_CAP") or SEARCH_DAILY_CAP)


def _refuse_bad_shape(body: SearchRequest) -> None:
    if not body.query.strip() or len(body.query) > MAX_QUERY_CHARS:
        raise HTTPException(status_code=422, detail=f"query must be 1..{MAX_QUERY_CHARS} chars")
    if not body.candidates or len(body.candidates) > MAX_CANDIDATES:
        raise HTTPException(status_code=422, detail=f"1..{MAX_CANDIDATES} candidates per request")
    for candidate in body.candidates:
        if len(candidate.about.encode("utf-8")) > MAX_ABOUT_BYTES:
            raise HTTPException(
                status_code=422, detail=f"each about must be under {MAX_ABOUT_BYTES} bytes")


@router.post("/search")
def search(body: SearchRequest, store: DynamoImportStore = Depends(entitled_store)):
    """`entitled_store`: this reaches a model, so it is spending. Shape first, so a refused
    request costs no unit; then one unit; then the model."""
    _refuse_bad_shape(body)
    charge_daily(store, "SEARCHCAP", _daily_cap(), "search")
    try:
        ids = pick(body.query.strip(), body.candidates)
    except Exception as error:
        if is_upstream_trouble(error):
            log.warning("search upstream unavailable: %s", error)
            raise HTTPException(status_code=503, detail="search model unavailable",
                                headers={"Retry-After": str(UPSTREAM_RETRY_AFTER)})
        log.warning("search failed: %s", error, exc_info=True)
        raise HTTPException(status_code=502, detail="search unavailable")
    return {"ids": ids}
