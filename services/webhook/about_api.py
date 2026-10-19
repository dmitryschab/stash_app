"""Stash /v1 about — the one text search matches a save against.

  POST /v1/about  {items: [AboutItem]} -> {abouts: [str]}, one per item, in the order sent

Its own module and its own router, mounted in app.py, like embeddings_api before it.

Search used to rank on a save's title, topics and hashtags, and those are the creator's words
for getting reach, not for what the video is: #fyp matched everything and "pasta" matched a
caption that never showed a plate. Every save now gets one "about" text instead — what is said,
else what the post is about — and the app matches against that alone. Music is the exception,
because a song's lyrics describe nothing on screen: it is described by genre only, and the
transcript of a music post is never put in the prompt.

Which words the model reads, first match wins:

  music       the identified tracks (for the genre only), the hashtag-stripped caption, the text
              on screen, and the picture. Never the transcript.
  speech      the transcript, the text on screen, the hashtag-stripped caption and the earlier
              summary. What is said is the answer; the caption and summary are there for the
              many posts whose "transcript" is only the song playing underneath, which the
              model is told to ignore. Summarizing those lyrics described a bathroom renovation
              as a love song.
  otherwise   the text on screen, the hashtag-stripped caption, the earlier summary, and the
              picture. The caption and summary may state the topic: held to what was visible
              on the cover, "a day in the life of a private chef" came back as a man in a lift.

Title, topics and hashtags are not fields of the request at all, so they cannot reach the prompt.

Money: no quota moves — the save was paid for at import, and being able to find it again must
not cost like saving it. Each item spends one daily deep-pass unit instead, charged up front for
the whole request before any model is called, so a capped request costs nothing on the model.
Text goes to Gemma on Bedrock; an item that carries a picture goes to the vision model.

A model with too little to go on sometimes answers by asking for more. That answer is not stored:
the save gets its stripped caption instead, else its earlier summary, else the request fails. A
music post gets "A music post." instead, so a refusal cannot bring its lyrics back in.

Failures: a 502 is about the items sent (the provider turned the request down, the answer held
no text, a refusal had nothing to fall back on), and the app skips such a save until relaunch.
The provider throttling, failing, slow or out of reach is a 503 with a Retry-After instead: it is
the same for every save, so the app ends its about phase and sends them again later.
"""
import base64
import logging
import re
from concurrent.futures import ThreadPoolExecutor

import requests
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

import api_v1
from clef import openrouter_key
from cloud_import_store import DynamoImportStore
from stash_auth import entitled_store

log = logging.getLogger("stash-webhook")

router = APIRouter(prefix="/v1")

# One request is one small batch from the client's backfill, written side by side.
MAX_ITEMS = 8
# All the text fields of one item together, in bytes: a Cyrillic transcript is two a letter.
MAX_TEXT_BYTES = 16 * 1024
# Decoded, not as base64: the size of the JPEG, not of the string that carries it.
MAX_IMAGE_BYTES = 400_000
# How much of a transcript and of the on-screen text the model reads. A sentence or two of
# speech says what a video is about; the rest is the same thing again.
TRANSCRIPT_CHARS = 4000
OCR_CHARS = 1000
# 2-4 plain sentences.
ABOUT_MAX_TOKENS = 220
# Gemma reads the cover too, and on 9 silent covers of the owner's library it named what is
# visibly there as well as Gemini did. Gemini spent ~200 of the 220 tokens reasoning and cut 6
# of the 9 answers off mid-sentence ("A poster"), at ~$0.0017 a save.
ABOUT_VISION_MODEL = api_v1.BEDROCK_MODEL
# Under the app's 30 s request timeout (boxRequestTimeout): a batch's calls run side by side, so
# a batch takes about its slowest call, and an answer that lands after the app hung up is units
# spent for nothing.
ABOUT_TIMEOUT = 25
# How long the app is told to wait when the model's provider is throttling, down or slow.
UPSTREAM_RETRY_AFTER = 60

ABOUT_SYSTEM_PROMPT = """You write the text a search engine matches a saved short video against. Answer with 2-4 plain
English sentences and nothing else: no lists, no Markdown, no preamble. Use concrete nouns a
person would search for: dishes, ingredients, places, products, brands, people, techniques,
activities. Never mention hashtags, the creator's handle, or the words "this video". Never ask
for more material and never say you cannot: if the material is thin, write one plain sentence
from what there is."""

MUSIC_INSTRUCTION = (
    "This is a music post. Do not use any lyrics. In one sentence say the genre of the music; "
    "then describe what is shown if the material below says. Never write a song, artist or "
    "album name.")
SPEECH_INSTRUCTION = (
    "Summarize what is said. If the transcript is only song lyrics or background music rather "
    "than someone talking, ignore it and describe what the post is about from the caption, the "
    "earlier summary and the on-screen text instead.")
SILENT_INSTRUCTION = (
    "Describe what the post is about, from the material below. The caption and the earlier "
    "summary may state its topic; the picture and the on-screen text add what is shown.")

# What a music post is about when the model refused it: nothing the prompt kept out gets back in.
MUSIC_FALLBACK = "A music post."

# How a model answers when it will not: asking for material, apologizing, saying it cannot. The
# first-person phrases mark a refusal wherever they sit, since an about-text never speaks as "I";
# "unfortunately" also turns up inside real summaries, so it counts only as the opening word.
REFUSAL = re.compile(
    r"\b(please provide|no material|i'm sorry|i am sorry|i cannot|i can't|i'm unable|"
    r"i am unable)\b|^unfortunately\b", re.IGNORECASE)


class AboutItem(BaseModel):
    videoID: str
    category: str = ""
    transcript: str = ""
    ocrText: str = ""
    caption: str = ""
    summary: str = ""
    music: list[str] = []  # each "Title by Artist"
    image: str | None = None  # base64 JPEG


def strip_hashtags(caption: str) -> str:
    return " ".join(re.sub(r"#\w+", "", caption).split())


def build_about_prompt(item: AboutItem) -> str:
    transcript = item.transcript.strip()
    ocr = item.ocrText.strip()[:OCR_CHARS]
    if item.category == "music":
        instruction = MUSIC_INSTRUCTION
        material = [
            ("Identified tracks (for the genre only)", "; ".join(item.music)),
            ("Caption", strip_hashtags(item.caption)),
            ("On-screen text", ocr)]
    elif transcript:
        instruction = SPEECH_INSTRUCTION
        material = [
            ("Transcript", transcript[:TRANSCRIPT_CHARS]),
            ("On-screen text", ocr),
            ("Caption", strip_hashtags(item.caption)),
            ("Earlier summary", item.summary.strip())]
    else:
        instruction = SILENT_INSTRUCTION
        material = [
            ("On-screen text", ocr),
            ("Caption", strip_hashtags(item.caption)),
            ("Earlier summary", item.summary.strip())]
    return "\n\n".join([instruction] + [f"{label}: {text}" for label, text in material if text])


def _chat(url: str, model: str, token: str, system: str, content: str | list,
          max_tokens: int) -> str:
    """The one network call. Raises on anything but a 200 with an answer in it."""
    response = requests.post(
        url,
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        json={
            "model": model,
            "temperature": 0.2,
            "max_tokens": max_tokens,
            "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": content},
            ],
        },
        timeout=ABOUT_TIMEOUT,
    )
    if response.status_code != 200:
        raise requests.HTTPError(f"about model {response.status_code}", response=response)
    return response.json()["choices"][0]["message"]["content"]


def _endpoint(model: str) -> tuple[str, str]:
    """The URL and bearer token for a model: Bedrock's own Gemma, or else OpenRouter."""
    if model == api_v1.BEDROCK_MODEL:
        return api_v1.BEDROCK_URL, api_v1._bedrock_token()
    return api_v1.OPENROUTER_URL, openrouter_key()


def is_upstream_trouble(error: Exception) -> bool:
    """The provider throttling (429), failing (5xx), slow or out of reach: the same for every
    save. Anything else — the provider turning this request down, an answer with no text in it,
    a refusal with nothing to fall back on — is about the item, and stays a 502."""
    if isinstance(error, (requests.Timeout, requests.ConnectionError)):
        return True
    if isinstance(error, requests.HTTPError):
        status = getattr(error.response, "status_code", None)
        return status == 429 or (status is not None and status >= 500)
    return False


def is_refusal(answer: str) -> bool:
    return bool(REFUSAL.search(answer.strip().replace("\u2019", "'")))


def write_about(item: AboutItem) -> str:
    prompt = build_about_prompt(item)
    if item.image:
        model = ABOUT_VISION_MODEL
        content = [
            {"type": "text", "text": prompt},
            {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64," + item.image}}]
    else:
        model, content = api_v1.BEDROCK_MODEL, prompt
    url, token = _endpoint(model)
    answer = _chat(url, model, token, ABOUT_SYSTEM_PROMPT, content, ABOUT_MAX_TOKENS).strip()
    if not answer:
        # A model that spends its whole token budget thinking answers with nothing. Stored as
        # the save's about text that would be final, so it fails the request instead.
        raise ValueError("empty about")
    if is_refusal(answer):
        # Stored, a refusal would be the save's about-text for good, and it matches every query
        # about nothing. The creator's own words are a worse about-text than a written one but a
        # better one than that — except on a music post, whose summary can retell the lyrics and
        # whose caption can name the song: the music prompt keeps both out, so the fallback does.
        if item.category == "music":
            return MUSIC_FALLBACK
        fallback = strip_hashtags(item.caption) or item.summary.strip()
        if not fallback:
            raise ValueError("refused about")
        return fallback
    return answer


class AboutRequest(BaseModel):
    items: list[AboutItem]


def _refuse_bad_shape(items: list[AboutItem]) -> None:
    if not items or len(items) > MAX_ITEMS:
        raise HTTPException(status_code=422, detail=f"1..{MAX_ITEMS} items per request")
    for item in items:
        text = [item.category, item.transcript, item.ocrText, item.caption, item.summary,
                *item.music]
        if sum(len(part.encode("utf-8")) for part in text) > MAX_TEXT_BYTES:
            raise HTTPException(
                status_code=422, detail=f"each item's text must be under {MAX_TEXT_BYTES} bytes")
        if item.image is not None:
            try:
                size = len(base64.b64decode(item.image, validate=True))
            except ValueError:  # binascii.Error is one
                raise HTTPException(status_code=422, detail="image must be base64")
            if size > MAX_IMAGE_BYTES:
                raise HTTPException(
                    status_code=422, detail=f"image must be under {MAX_IMAGE_BYTES} bytes")


@router.post("/about")
def about(body: AboutRequest, store: DynamoImportStore = Depends(entitled_store)):
    """One about text per item, in the order they were sent.

    `entitled_store` rather than `user_store`: this reaches a model, so it is spending, and the
    subscription check is what stops a stranger signing in and spending it. Shape is checked
    first, so a refused request costs no deep-pass unit; then every item is charged, then the
    models are called.
    """
    items = body.items
    _refuse_bad_shape(items)
    for _ in items:
        api_v1.charge_deep_pass(store)

    try:
        with ThreadPoolExecutor(max_workers=MAX_ITEMS) as pool:
            abouts = list(pool.map(write_about, items))
    except Exception as error:
        # One item failing fails the request: the units are already spent either way, and a
        # partial answer would break the by-position pairing the client reads it by.
        if is_upstream_trouble(error):
            # Nothing to do with the saves sent: the app ends its about phase on this and sends
            # the same saves again later, where a 502 would have it skip them as bad.
            log.warning("about upstream unavailable: %s", error, exc_info=True)
            raise HTTPException(status_code=503, detail="about model unavailable",
                                headers={"Retry-After": str(UPSTREAM_RETRY_AFTER)})
        log.warning("about failed: %s", error, exc_info=True)
        raise HTTPException(status_code=502, detail="about unavailable")

    return {"abouts": abouts}
