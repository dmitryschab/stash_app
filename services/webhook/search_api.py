"""Stash /v1 search — a model picks the saves that answer a request.

  POST /v1/search  {query, candidates: [{id, about}]} -> {ids: [str]}, best first

Its own module and its own router, mounted in app.py, like about_api before it.

The app still finds the candidates itself: its SearchIndex ranks the whole library by meaning and
words on the phone and sends the top few dozen, each with its about-text. The model reads them
against the request and answers with the ones that fit, best first. A request like "something
quick and vegetarian for tonight" is not a word any about-text says, and cosine alone cannot tell
a recipe from a restaurant review of the same dish; reading can. Only a pool goes up, never the
library: a library is thousands of saves.

Candidates are numbered in the prompt and the model answers with the numbers, not the ids: a
19-digit TikTok id copied back by a model is one wrong digit away from pointing at nothing. A
number that names no candidate is dropped.

The model is Gemma on Bedrock in Frankfurt — the one that wrote the about-texts, through the same
Mantle endpoint and token (about_api._chat), so no new processor sees a library. Claude Haiku 5.5
was the first choice and is what 76bdb7b called; AWS refuses every Claude model newer than 4.6
to this account, so it waits on AWS.

Money: one unit of a daily counter of its own (SEARCHCAP, beside ABOUTCAP) per request, charged
before the model is called, so a capped request costs nothing on the model. No quota moves:
finding a save again must not cost like saving it.

Failures are the app's to absorb: on anything but a 200 it shows the list its own ranking made.
The provider throttling, failing, slow or out of reach is a 503 with a Retry-After; anything else
is a 502.
"""
import logging
import os
import re

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

import api_v1
from about_api import _chat, charge_daily, is_upstream_trouble
from cloud_import_store import DynamoImportStore
from stash_auth import entitled_store

log = logging.getLogger("stash-webhook")

router = APIRouter(prefix="/v1")

# The app sends at most this many: its ranking's top, which is where an answer to the request
# can be. 60 about-texts are ~3K tokens.
MAX_CANDIDATES = 60
MAX_QUERY_CHARS = 300
# One about-text is 2-4 sentences; Cyrillic is two bytes a letter.
MAX_ABOUT_BYTES = 2000
# What the model may pick: a screenful and a half. Past this it is listing, not choosing.
MAX_PICKS = 20
# Twenty numbers and commas.
SEARCH_MAX_TOKENS = 120
# Under the app's deadline for this call (SearchView), with no retry: a late answer would land
# after the app has already shown its own list.
SEARCH_TIMEOUT = 8
UPSTREAM_RETRY_AFTER = 60
# Requests per account per UTC day. At ~3K tokens in, a search costs well under a tenth of a
# cent, so a user who spends all of these costs cents a day.
SEARCH_DAILY_CAP = 300

SEARCH_SYSTEM_PROMPT = f"""You help a person find short videos they saved. You get their request and a
numbered list of their saved videos, each described in a sentence or a few. Pick the videos that
answer the request: the ones they would want to open for it, best match first. Leave out a video
that only shares a word with the request but is about something else. Pick at most {MAX_PICKS}.
Answer with only the numbers of your picks, best first, separated by commas, like: 4, 12, 7
If nothing fits, answer: none"""

NUMBER = re.compile(r"\d+")


class Candidate(BaseModel):
    id: str
    about: str


class SearchRequest(BaseModel):
    query: str
    candidates: list[Candidate]


def build_prompt(query: str, candidates: list[Candidate]) -> str:
    lines = [f"{number}: {' '.join(c.about.split())}"
             for number, c in enumerate(candidates, start=1)]
    return f"Request: {query}\n\nSaved videos:\n" + "\n".join(lines)


def parse_picks(answer: str, candidates: list[Candidate]) -> list[str]:
    """The candidates' ids the answer names, in its order, each once. "none" — or a refusal,
    which names no number either — is an empty list, and the app keeps its own ranking."""
    ids: list[str] = []
    for match in NUMBER.findall(answer):
        number = int(match)
        if 1 <= number <= len(candidates) and candidates[number - 1].id not in ids:
            ids.append(candidates[number - 1].id)
    return ids[:MAX_PICKS]


def pick(query: str, candidates: list[Candidate]) -> list[str]:
    answer = _chat(api_v1.BEDROCK_URL, api_v1.BEDROCK_MODEL, api_v1._bedrock_token(),
                   SEARCH_SYSTEM_PROMPT, build_prompt(query, candidates), SEARCH_MAX_TOKENS,
                   timeout=SEARCH_TIMEOUT)
    return parse_picks(answer, candidates)


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
