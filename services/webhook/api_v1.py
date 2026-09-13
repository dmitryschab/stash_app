"""Stash /v1 API — the cloud half of the tester pipeline.

Three endpoints, each behind a per-user Stash JWT (spec:
docs/superpowers/specs/2026-07-11-tester-ready-cloud-pipeline-design.md):

  POST /v1/videos/transcript   {url} -> yt-dlp audio -> Groq whisper -> filtered text
  POST /v1/chat/completions    OpenAI-shape proxy to Bedrock Gemma (model and output cap
                               pinned here; the client body is not forwarded as-is)
  GET  /v1/tiktok/download/{id} -> mp4 bytes, transient only (visual-text OCR backfill)

TikTok blocks all in-app media downloads (blank playAddr / CDN 403 / CORS), so the
box owns every media fetch. Groq free tier: 7200 audio-sec per rolling hour — 429s
are passed through with Retry-After so the app can park the stage and retry.

The analyzer proxy costs one quota unit, charged only when the work actually produced
something: a throttled provider or a Bedrock error must not eat the caller's budget. The
other two are the app's deep pass over a library it already paid for a unit per video at
import, so they move no quota at all — re-reading a save must not cost as much as saving it.
Nothing here is free, though: an unbounded authenticated route is an unbounded bill, so those
two are capped per user per UTC day instead (`DEEP_PASS_DAILY_CAP`).
"""
import base64
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from collections import Counter
from datetime import datetime, timedelta, timezone

import requests
from fastapi import APIRouter, Depends, HTTPException, Response
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

import stash_secrets
from cloud_import_store import DynamoImportStore
from stash_auth import entitled_store, peek_quota

router = APIRouter(prefix="/v1")

GROQ_URL = "https://api.groq.com/openai/v1/audio/transcriptions"
GROQ_MODEL = "whisper-large-v3-turbo"
GROQ_MAX_BYTES = 24_000_000  # free-tier file cap is 25 MB; re-encode above this

BEDROCK_URL = "https://bedrock-mantle.eu-central-1.api.aws/openai/v1/chat/completions"
BEDROCK_MODEL = "google.gemma-4-26b-a4b"
BEDROCK_REGION = "eu-central-1"

# yt-dlp is pip-installed into the service venv; systemd's PATH can't see it.
YTDLP = os.path.join(os.path.dirname(sys.executable), "yt-dlp")

# Caps on the proxied analyzer call. The prompt this endpoint serves is a few hundred bytes
# and its answer is one JSON object; anything larger is either a bug or someone using our
# Bedrock budget as a general-purpose LLM. A size cap alone does NOT bound the bill — output
# tokens are what cost money, and n/best_of/stream multiply them — so the outbound body is
# rebuilt from an allowlist and max_tokens is clamped. Clamped per call still is not a bound
# on the total, so the route is quota-metered too: one unit per answer Bedrock actually
# returned, which is what caps an account at its budget instead of at our bill.
CHAT_MAX_BYTES = 32_000
CHAT_MAX_OUTPUT_TOKENS = 1280  # a full recipe measures ~600; eight "buys" entries add ~250


def _groq_key() -> str:
    """Read lazily: a module-level read would make pytest and `python api_v1.py` reach
    for instance metadata off-box."""
    return stash_secrets.secret("GROQ_API_KEY")


def _has_no_video_track(directory: str) -> bool:
    """True when yt-dlp's sidecar metadata says every format is audio-only — a photo post.

    Unreadable or absent metadata answers False: the caller then transcribes as before, which
    is the behaviour this whole check is narrowing, not a new risk.
    """
    for name in os.listdir(directory):
        if not name.endswith(".info.json"):
            continue
        try:
            with open(os.path.join(directory, name), encoding="utf-8") as handle:
                formats = json.load(handle).get("formats") or []
        except (OSError, ValueError):
            return False
        return bool(formats) and all(fmt.get("vcodec") == "none" for fmt in formats)
    return False


# The photo-post analyzer. Gemma cannot recognise album artwork — asked outright it answers
# that it cannot — and this account's Bedrock endpoint serves no other model that takes an
# image. Measured against a real album-grid post, this one named every sleeve that could be
# checked by hand, matched Claude Opus 5 for accuracy at a twenty-fourth of the cost, and
# returned the same list on four consecutive runs. Roughly $0.0035 per photo post.
OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions"
OPENROUTER_VISION_MODEL = "google/gemini-3.7-flash"
# One entry per sleeve, and a sixteen-album grid runs past 1500 output tokens. At
# CHAT_MAX_OUTPUT_TOKENS the JSON is cut mid-object and the whole analysis is lost, not just
# the tail of the list.
VISION_MAX_OUTPUT_TOKENS = 4096


def _openrouter_key() -> str:
    return stash_secrets.secret("OPENROUTER_API_KEY")


# ---------------------------------------------------------------- deep-pass cap

# How many transcript + download calls one account may make in a UTC day. Sized for the
# honest ceiling of a library (~600 videos, two calls each): a whole library deepens over
# a few nights of charging rather than in one, which is exactly the pace the client's
# charging + Wi-Fi gate already implies.
DEEP_PASS_DAILY_CAP = 300


def _daily_cap() -> int:
    """Read per call, not at import: the box sets this in the unit file and a test sets it in
    the environment, and a module-level read would freeze whichever got there first."""
    return int(os.environ.get("DEEP_PASS_DAILY_CAP") or DEEP_PASS_DAILY_CAP)


def charge_deep_pass(store: DynamoImportStore) -> None:
    """Count this call against the caller's daily allowance, or 429.

    Charged up front, before the work — the opposite of the quota rule the analyzer route
    follows, and deliberately so. Quota counts videos the user got something for; this counts
    what we spend, and a yt-dlp run costs the same box-minute whether the video turns out to be
    deleted, silent or a photo post.

    Retry-After points at the next UTC midnight, which is when the counter rolls. The app needs
    nothing new to honour it: five failures in a row already stop a backfill, and it resumes
    where it left off on the next pass.
    """
    if store.charge_deep_pass(_daily_cap()):
        return
    now = datetime.now(timezone.utc)
    midnight = (now + timedelta(days=1)).replace(hour=0, minute=0, second=0, microsecond=0)
    raise HTTPException(
        status_code=429, detail="deep-pass daily cap reached",
        headers={"Retry-After": str(max(1, int((midnight - now).total_seconds())))})


# ---------------------------------------------------------------- transcript

class TranscriptRequest(BaseModel):
    url: str


# Segment quality gates. Whisper hallucinates canned lines on music/silence
# (its verbose_json exposes the confidence signals that give them away).
NO_SPEECH_MAX = 0.6        # drop a segment Whisper itself scores as non-speech
AVG_LOGPROB_MIN = -1.0     # drop very low-confidence guesses
COMPRESSION_RATIO_MAX = 2.4  # Whisper's own gibberish/repeat heuristic
MIN_WORDS = 5              # keep short-but-real speech ("add two eggs then mix")

# Canonical Whisper hallucinations — subtitle credits and sign-offs baked into
# its training data that surface on non-speech audio. Matched case-insensitively
# as substrings on a normalized line. High-precision list; extend as new ones show up.
_HALLUCINATIONS = (
    "субтитры сделал", "субтитры создавал", "субтитры делал", "редактор субтитров",
    "dimatorzok", "amara.org", "subtitles by", "subs by", "subtitle by",
    "thanks for watching", "thank you for watching", "please subscribe",
    "like and subscribe", "don't forget to subscribe", "see you next time",
    "시청해주셔서 감사합니다", "mbc 뉴스", "字幕", "字幕志愿者",
)


def _is_hallucination(text: str) -> bool:
    t = text.strip().lower()
    return any(h in t for h in _HALLUCINATIONS)


def keep_segment(seg: dict) -> bool:
    """True when a Whisper segment looks like real speech, not a hallucination.

    Missing confidence fields default to 'keep' so we never over-drop on responses
    (or test fakes) that omit them; the text blocklist still applies.
    """
    if seg.get("no_speech_prob", 0.0) >= NO_SPEECH_MAX:
        return False
    if seg.get("avg_logprob", 0.0) < AVG_LOGPROB_MIN:
        return False
    if seg.get("compression_ratio", 0.0) > COMPRESSION_RATIO_MAX:
        return False
    return not _is_hallucination(seg.get("text", ""))


# Whisper repetition filter — port of the validated pipeline filter (PROMPT.md).
def _ngram_loops(line: str) -> bool:
    words = line.split()
    for n in (3, 4):
        if len(words) < n * 2:
            continue
        grams = [tuple(words[i:i + n]) for i in range(len(words) - n + 1)]
        if grams and max(Counter(grams).values()) >= 2:
            return True
    return False


def _low_diversity(line: str) -> bool:
    """Single-token loops the n-gram check misses on short lines ('The The The The')."""
    words = line.split()
    return len(words) >= 4 and len({w.lower() for w in words}) / len(words) < 0.5


def filter_transcript(lines: list[str]) -> str:
    out: list[str] = []
    for line in lines:
        line = re.sub(r"\s+", " ", line).strip()
        if not line:
            continue
        if out and line == out[-1]:
            continue
        if _ngram_loops(line) or _low_diversity(line) or _is_hallucination(line):
            continue
        out.append(line)
    counts = Counter(out)
    out = [l for l in out if counts[l] <= 4]
    text = "\n".join(out).strip()
    return text if len(text.split()) >= MIN_WORDS else ""


@router.post("/videos/transcript")
def video_transcript(body: TranscriptRequest, store: DynamoImportStore = Depends(entitled_store)):
    groq_key = _groq_key()
    if not groq_key:
        raise HTTPException(status_code=503, detail="transcription not configured")
    if not re.match(r"^https://(www\.)?tiktok(v)?\.com/", body.url):
        raise HTTPException(status_code=400, detail="not a tiktok url")
    charge_deep_pass(store)  # 429 before spending yt-dlp and Groq time
    # Echoed unchanged: the app keeps its counter fresh from whatever route answered last,
    # and this one no longer moves it.
    quota = store.get_quota()

    with tempfile.TemporaryDirectory() as td:
        # Keep yt-dlp's native container — Groq accepts m4a/mp4/webm alike.
        dl = subprocess.run(
            [YTDLP, "-q", "--no-warnings", "-f", "bestaudio/best", "--write-info-json",
             "-o", os.path.join(td, "audio.%(ext)s"), body.url],
            capture_output=True, timeout=180)
        produced = [os.path.join(td, f) for f in os.listdir(td)
                    if f.startswith("audio.") and not f.endswith(".info.json")]
        if dl.returncode != 0 or not produced:
            # deleted / private / region-locked — a normal library condition
            return {"transcript": None, "duration": 0, "unavailable": True,
                    "quota": quota.model_dump(by_alias=True)}

        # A photo post has no speech: its audio is a licensed backing track the poster chose,
        # and Whisper duly returns that song's lyrics. The app treats any non-empty transcript
        # as the post's own content — it clears the structured payload and re-analyses from the
        # text alone — so transcribing somebody else's song here destroyed the album picks the
        # fast pass had just read off the picture. Written in the same yt-dlp run as the audio,
        # so knowing this costs no extra round trip.
        if _has_no_video_track(td):
            return {"transcript": None, "duration": 0,
                    "quota": quota.model_dump(by_alias=True)}
        audio = produced[0]

        if os.path.getsize(audio) > GROQ_MAX_BYTES:
            small = os.path.join(td, "small.ogg")
            subprocess.run(["ffmpeg", "-y", "-v", "error", "-i", audio,
                            "-ar", "16000", "-ac", "1", "-b:a", "24k", small],
                           capture_output=True, timeout=180)
            audio = small

        with open(audio, "rb") as f:
            resp = requests.post(
                GROQ_URL,
                headers={"Authorization": f"Bearer {groq_key}"},
                files={"file": (os.path.basename(audio), f)},
                # temperature=0 disables Whisper's sampling fallback, which is a
                # major source of hallucinated text on noisy/musical clips.
                data={"model": GROQ_MODEL, "response_format": "verbose_json", "temperature": 0},
                timeout=120)

    if resp.status_code == 429:
        retry = resp.headers.get("retry-after", "60")
        raise HTTPException(status_code=429, detail="transcription throttled",
                            headers={"Retry-After": retry})
    if resp.status_code != 200:
        # Log the upstream body so the cause of these 502s is diagnosable — the
        # bare status alone told us nothing about the ~60% historical failure rate.
        print(f"groq transcription {resp.status_code}: {resp.text[:300]}", file=sys.stderr)
        raise HTTPException(status_code=502, detail=f"groq {resp.status_code}")

    data = resp.json()
    # Gate each segment on Whisper's own confidence signals before joining, so a
    # hallucinated sign-off on a music clip never reaches the analyzer as "content".
    lines = [s.get("text", "") for s in data.get("segments", []) if keep_segment(s)]
    text = filter_transcript(lines)
    return {"transcript": text or None, "duration": data.get("duration", 0),
            "quota": quota.model_dump(by_alias=True)}


# ---------------------------------------------------------------- analyze proxy

_token_cache: dict = {"token": None, "expires": 0.0}


def _bedrock_token() -> str:
    if _token_cache["token"] and time.time() < _token_cache["expires"]:
        return _token_cache["token"]
    from aws_bedrock_token_generator import provide_token
    _token_cache["token"] = provide_token(region=BEDROCK_REGION)
    _token_cache["expires"] = time.time() + 300  # regenerate every 5 min
    return _token_cache["token"]


# The analysis prompt, and the only one. The app used to ship its own copy for the deep pass,
# so a re-analysis ran different instructions than the fast pass that produced the entry; the
# proxy below now substitutes this for whatever system message the client sent. Rules marked by
# the 855-video validation run live in pipeline-lab/PROMPT.md.
ANALYSIS_SYSTEM_PROMPT = """
You classify a short video into a single strict JSON object. Respond with ONLY the JSON
object, no prose and no Markdown code fences. Use this exact shape:
{
  "category": "recipe" | "fitness" | "style" | "travel" | "home" | "learning" | "comedy" | "music" | "coding" | "film" | "dining" | "wellness" | "other",
  "title": string,
  "summary": string,
  "topics": [string],            // short lowercase topic keywords
  "recipe": { "name": string, "ingredients": [string], "steps": [string] } | null,
  "music": [ { "kind": "album" | "track", "title": string, "artist": string } ],
  "code": { "summary": string, "links": [string], "techTags": [string] } | null,
  "buys": [ { "name": string, "kind": string, "price": string } ]
}
recipe, music and code belong to a category: fill the one matching the category you chose and
leave the others empty — for every other category set "recipe" and "code" to null and "music"
to []. Never include a "link" field; the app resolves streaming links separately.

"buys" is different, and it is the one field that does NOT follow the category. Judge it
separately, on every video, whatever you filed it under.

Pick the category from the whole post, hashtags included, even when the transcript is empty
(fitness=workouts/gym/running/nutrition, style=fashion/beauty/makeup,
travel=trips/destinations/hotels/flights, home=decor/cleaning/DIY/renovation/gardening,
learning=facts/how-to/study/science/history, comedy=skits/jokes/memes/pranks,
coding=software/gadgets/AI and tags like #linux #arch #selfhosted #homelab #docker #python
#react #vim, film=movies/TV/anime/what to watch, dining=restaurants/cafes/coffee/wine,
wellness=health/supplements/sleep/mental health); use other only when none fit.

Captions and transcripts may be in any language; ALWAYS answer in English. Title max 60
characters. Use empty strings or arrays when information is missing. NEVER output placeholder
prose such as "No Content Provided" or "Untitled Video". If caption and transcript are both
empty, use title "Saved video" and summary "No caption or audio was available for this save."

Two categories carry extra structure, and the Cook and Music screens are empty without it:
- category recipe: fill the "recipe" object only when the source actually lists a name,
  ingredients or steps; leave it null rather than inventing a recipe. Write every quantity in
  metric — grams, millilitres, °C, centimetres. Convert cups, ounces, pounds and °F rather
  than copying them; teaspoons and tablespoons may stay.
- category music: list EVERY distinct release the video recommends, in the order it shows
  them, one "music" entry each and at most 12 — a video running through five albums has five
  entries, not one, and a video about a single song is simply one entry. Do NOT collapse a
  list into its theme or genre: "jungle selection", "russian shoegaze" and the like are
  descriptions, never titles. Read the names off the on-screen text; it is usually the only
  place they appear, and copy each title as written. Set "kind" to "album" for a
  record/EP/mixtape/compilation and "track" for a single song. Set "artist" to the act named
  next to that title, or leave it an empty string — NEVER invent an artist you are not
  confident about, and never reuse one entry's artist for another, because a guessed artist
  links the wrong release.

"buys" — things the user might want to own, collected from every category into one shelf.
Ask one question: is a specific, purchasable product a FOCAL POINT of this post? If the video
is built around some item — a shoe, a phone, a bag, a chair, a camera, a serum, a gadget, a
tool, a pan, a supplement, a game — then list it. A haul, an unboxing, a review, a comparison,
a "things I use daily", a get-ready-with-me that names what it is wearing, a desk tour, a gift
guide, a "this changed my life" pitch: all of these are buys, and they arrive filed as style,
home, coding, fitness, wellness or anything else. That is expected. Fill "buys" anyway.

Include an item when the post names it, holds it up, wears it, demonstrates it, or puts it on
screen as the thing being talked about. Exclude:
- scenery and props: the mug on the desk, the couch behind the speaker, the car it was filmed
  in — anything merely visible rather than presented;
- ingredients of a recipe, which are already in "recipe";
- releases in "music", and software, apps and repos, which are already in "code";
- services, subscriptions, courses, hotels, restaurants, flights and destinations — this is a
  shelf of objects you can put in a cart, not of things you can book;
- categories rather than products: "a good moisturiser", "running shoes" with no brand.

Write "name" as the shortest string that would find the product in a store's search box —
brand and model as the video says them ("Nike Vomero 5", "Aesop Resurrection hand balm"),
never a sentence and never a description. Write "kind" as one lowercase noun for what it is
("sneakers", "phone", "serum", "chair"). Write "price" ONLY when the post states one, copied
as written with its currency ("€39", "under $20"); leave it "" otherwise and NEVER estimate a
price you were not told. At most 8 entries, in the order the video presents them, no
duplicates. Most posts sell nothing at all: [] is the correct and common answer, and a list of
props is worse than an empty one.
""".strip()

# Appended to the prompt above on the vision path, never copied into it: none of this means
# anything to a text-only call, where the picture is exactly what is missing.
PHOTO_SYSTEM_PROMPT_ADDENDUM = """
A TikTok photo post carries no speech and usually no caption: the attached images ARE the
whole post, and they outrank the rule above about missing information — never answer "Saved
video" when there is an image. Read every word printed on them. When several images are
attached they are the slides of one post, in order — a list post routinely spends its first
slide on a cover or a joke and keeps the actual list on the later slides, so never judge the
post from the first image alone.

A grid, ranking or chart of album sleeves is category music, however few words it carries.
Name each sleeve you recognise from its cover artwork — most carry no readable title, and a
sleeve you leave out is a release the user loses. Put one "music" entry per sleeve, in reading
order, kind "album", and skip only the ones you genuinely cannot identify. The words printed
beside a sleeve are almost always a genre, a mood or a rank: those belong in topics, never in
title and never in artist.

A photo post's "Sound" is the backing track the poster picked, not something the post
recommends — never put it in "music" unless the image itself is about that release.

A photo post is very often a product: one item shot on a table, a wishlist grid, an outfit
flatlay, a "what's in my bag". Read the brands and models off the image and off any price tag
in frame, and fill "buys" from what you see — this is the path where the picture is the only
place the product name ever appears.
""".strip()


def build_analysis_prompt(metadata: dict) -> str:
    """Build the caption-first prompt shared by the API proxy and cloud worker."""
    parts = []
    if metadata.get("caption"):
        parts.append(f"Caption: {metadata['caption']}")
    if metadata.get("hashtags"):
        parts.append(f"Hashtags: {', '.join(metadata['hashtags'])}")
    if metadata.get("author"):
        parts.append(f"Author: {metadata['author']}")
    if metadata.get("track"):
        sound = metadata["track"]
        if metadata.get("artist"):
            sound += f" by {metadata['artist']}"
        parts.append(f"Sound: {sound}")
    if metadata.get("isPhotoPost"):
        # Without this the sound is the only line in the prompt, and the model reads a photo
        # post as a song recommendation — naming the backing track instead of the nine albums
        # the picture is actually about. Said even when no picture could be fetched,
        # which is exactly when the prompt is otherwise just a song title.
        count = len(metadata.get("images") or [])
        if count > 1:
            parts.append(
                f"This is a photo post of {count} slides, attached in order: the pictures are "
                "the entire post and the sound above is only the backing track, not a "
                "recommendation.")
        elif count == 1:
            parts.append(
                "This is a photo post: the picture is the entire post and the sound above is "
                "only the backing track, not a recommendation.")
        else:
            parts.append(
                "This is a photo post whose picture could not be fetched. The sound above is "
                "only the backing track, not a recommendation — leave \"music\" empty.")
    return "\n".join(parts) if parts else "(no metadata available)"


def analyze_metadata(metadata: dict) -> dict:
    """Analyze one video's metadata, or one photo post's pictures, into the Analysis object.

    Everything with words goes to Bedrock, as it always has. A photo post — `metadata["images"]`,
    a list of raw JPEGs, one per slide in post order — goes to the vision model instead, because
    its releases exist as pixels and nowhere else: no caption, no speech, and no video track for
    the OCR pass to sample.

    A photo post with no vision key configured falls back to the text path rather than failing.
    The picture is then unread, which the prompt already knows how to say honestly, and one
    missing credential must not turn every photo post in an import into an error.
    """
    prompt = build_analysis_prompt(metadata)
    images = metadata.get("images") or []
    vision_key = _openrouter_key() if images else ""
    if images and vision_key:
        provider, url, model, token = "vision", OPENROUTER_URL, OPENROUTER_VISION_MODEL, vision_key
        max_tokens = VISION_MAX_OUTPUT_TOKENS
        system = f"{ANALYSIS_SYSTEM_PROMPT}\n\n{PHOTO_SYSTEM_PROMPT_ADDENDUM}"
        content = [{"type": "text", "text": prompt}] + [
            {"type": "image_url",
             "image_url": {"url": "data:image/jpeg;base64," + base64.b64encode(image).decode()}}
            for image in images]
    else:
        provider, url, model, token = "bedrock", BEDROCK_URL, BEDROCK_MODEL, _bedrock_token()
        # Was unset, which left the ceiling to the provider default. A recipe object pushes
        # the response to roughly 600 tokens, so an unstated limit is a truncated JSON body
        # — and a truncated body fails the whole analysis, not just the recipe.
        max_tokens = CHAT_MAX_OUTPUT_TOKENS
        system = ANALYSIS_SYSTEM_PROMPT
        content = prompt

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
        # The vision model takes 12-18 s on a full grid, well inside this.
        timeout=180,
    )
    if response.status_code != 200:
        error = requests.HTTPError(f"{provider} {response.status_code}", response=response)
        raise error
    try:
        content = response.json()["choices"][0]["message"]["content"]
        content = content.strip()
        if content.startswith("```"):
            content = content.split("\n", 1)[1].rsplit("```", 1)[0].strip()
        return json.loads(content)
    except (KeyError, IndexError, TypeError, ValueError) as error:
        raise ValueError("invalid analyzer response") from error


@router.post("/chat/completions")
def chat_completions(body: dict, store: DynamoImportStore = Depends(entitled_store)):
    if len(json.dumps(body)) > CHAT_MAX_BYTES:
        raise HTTPException(status_code=413, detail="request too large")
    peek_quota(store)  # 402 before spending Bedrock money
    try:
        wanted = int(body.get("max_tokens") or CHAT_MAX_OUTPUT_TOKENS)
        temperature = float(body.get("temperature", 0.2))
    except (TypeError, ValueError):
        raise HTTPException(status_code=400, detail="bad analyzer body")
    # Allowlist, not blocklist: anything unnamed here is dropped, so n/best_of/stream cannot
    # multiply the output bill. Gemma via Mantle also rejects OpenAI's response_format, and
    # the prompt already demands bare JSON that the app strips fences from.
    outbound = {
        "model": BEDROCK_MODEL,  # pinned server-side; client value ignored
        "messages": body.get("messages") or [],
        "temperature": max(0.0, min(temperature, 1.0)),
        "max_tokens": max(1, min(wanted, CHAT_MAX_OUTPUT_TOKENS)),
    }
    # One prompt, not two. The app's deep pass re-analyses videos the fast pass above already
    # classified, and while it shipped its own copy of the instructions the two drifted apart —
    # a re-analysis silently answered to rules the original never saw.
    # ponytail: the substitution is unconditional, with no version handshake. This endpoint has
    # exactly one caller (AnalyzerClient), which sends a placeholder system message purely so
    # there is something to replace; a body without a leading system message goes as it is.
    messages = outbound["messages"]
    if messages and isinstance(messages[0], dict) and messages[0].get("role") == "system":
        outbound["messages"] = [{"role": "system", "content": ANALYSIS_SYSTEM_PROMPT},
                                *messages[1:]]
    resp = requests.post(
        BEDROCK_URL,
        headers={"Authorization": f"Bearer {_bedrock_token()}",
                 "Content-Type": "application/json"},
        json=outbound, timeout=120)
    headers = {}
    if resp.status_code == 200:
        # Commit the unit only for an answer we were billed for, same rule as the two routes
        # above. The body is a verbatim OpenAI-shape pass-through the app decodes as such, so
        # the fresh quota rides in the header StashHTTP already reads on every response.
        quota = store.reserve_quota(1) or store.get_quota()
        headers["X-Stash-Quota"] = json.dumps(quota.model_dump(by_alias=True))
    return Response(content=resp.content, status_code=resp.status_code,
                    media_type="application/json", headers=headers)


# ---------------------------------------------------------------- transient media

@router.get("/tiktok/download/{video_id}")
def tiktok_download(video_id: str, store: DynamoImportStore = Depends(entitled_store)):
    """mp4 bytes for the app's visual-text OCR backfill, which samples frames and deletes
    the file immediately. No persistent offline copy is served or kept anywhere."""
    if re.fullmatch(r"\d{5,25}", video_id):
        source = f"https://www.tiktok.com/@/video/{video_id}"
    elif re.fullmatch(r"[A-Za-z0-9_-]{5,64}", video_id):
        # An Instagram reel shortcode. yt-dlp serves it as h264+aac mp4 without cookies.
        source = f"https://www.instagram.com/reel/{video_id}/"
    else:
        raise HTTPException(status_code=400, detail="bad video id")
    charge_deep_pass(store)
    quota = store.get_quota()

    # Not TemporaryDirectory: the file has to outlive this function so the body can be
    # streamed instead of read whole into a 1 GB box's memory. The generator cleans up.
    temp_dir = tempfile.mkdtemp(prefix="stash-dl-")
    try:
        out = os.path.join(temp_dir, f"{video_id}.mp4")
        dl = subprocess.run(
            [YTDLP, "-q", "--no-warnings", "-f", "mp4", "-o", out, source],
            capture_output=True, timeout=180)
        if dl.returncode != 0 or not os.path.exists(out):
            # A photo post has no video track at all, so yt-dlp reports the mp4 format as
            # missing. That is a permanent property of the post, not a transient failure, and
            # saying so lets the app record the read as done. Answering 502 instead made every
            # photo post look retryable, and five in a row abort the whole visual backfill —
            # starving the real videos behind them of their OCR pass.
            stderr = (dl.stderr or b"").decode("utf-8", "replace")
            if "Requested format is not available" in stderr:
                raise HTTPException(status_code=415, detail="no video track")
            raise HTTPException(status_code=502, detail="download failed")
    except BaseException:
        shutil.rmtree(temp_dir, ignore_errors=True)
        raise

    def stream():
        try:
            with open(out, "rb") as handle:
                while chunk := handle.read(1 << 20):
                    yield chunk
        finally:
            shutil.rmtree(temp_dir, ignore_errors=True)

    return StreamingResponse(stream(), media_type="video/mp4",
                             headers={"X-Stash-Quota": json.dumps(quota.model_dump(by_alias=True))})


# ---------------------------------------------------------------- self-check

def selftest():
    assert filter_transcript(["The The The The"] * 3) == ""
    kept = filter_transcript(["a real sentence with plenty of distinct words in it today ok"])
    assert kept != ""
    lines = []
    for i in range(5):
        lines += ["chorus line here", f"unique verse number {i} distinct words follow"]
    res = filter_transcript(lines)
    assert "chorus line here" not in res.split("\n")

    # Hallucinated subtitle credits are stripped even when they'd clear the word floor.
    assert filter_transcript(["Субтитры сделал DimaTorzok"]) == ""
    assert filter_transcript(["Thanks for watching, don't forget to subscribe"]) == ""
    # Short but real speech now survives (floor lowered from 12 to 4 words).
    assert filter_transcript(["add two eggs then mix"]) != ""
    # Segment gate: non-speech / low-confidence / gibberish segments are dropped;
    # a clean speech segment is kept; missing fields default to keep.
    assert keep_segment({"text": "here is the recipe", "no_speech_prob": 0.02, "avg_logprob": -0.3})
    assert not keep_segment({"text": "music", "no_speech_prob": 0.95})
    assert not keep_segment({"text": "hi", "avg_logprob": -2.0})
    assert not keep_segment({"text": "la la la la", "compression_ratio": 3.1})
    assert not keep_segment({"text": "Субтитры создавал кто-то"})
    assert keep_segment({"text": "plain segment with no confidence fields"})
    print("api_v1 selftest OK")


if __name__ == "__main__":
    selftest()
