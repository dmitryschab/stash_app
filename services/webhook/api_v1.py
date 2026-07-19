"""Stash /v1 API — the cloud half of the tester pipeline.

Three endpoints behind one shared bearer token (spec:
docs/superpowers/specs/2026-07-11-tester-ready-cloud-pipeline-design.md):

  POST /v1/videos/transcript   {url} -> yt-dlp audio -> Groq whisper -> filtered text
  POST /v1/chat/completions    OpenAI-shape proxy to Bedrock Gemma (model pinned here)
  GET  /v1/tiktok/download/{id} -> mp4 bytes (app "Keep offline")

TikTok blocks all in-app media downloads (blank playAddr / CDN 403 / CORS), so the
box owns every media fetch. Groq free tier: 7200 audio-sec per rolling hour — 429s
are passed through with Retry-After so the app can park the stage and retry.
"""
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from collections import Counter

import requests
from fastapi import APIRouter, Header, HTTPException, Response
from pydantic import BaseModel

router = APIRouter(prefix="/v1")

API_TOKEN = os.environ.get("STASH_API_TOKEN", "")
GROQ_API_KEY = os.environ.get("GROQ_API_KEY", "")
GROQ_URL = "https://api.groq.com/openai/v1/audio/transcriptions"
GROQ_MODEL = "whisper-large-v3-turbo"
GROQ_MAX_BYTES = 24_000_000  # free-tier file cap is 25 MB; re-encode above this

BEDROCK_URL = "https://bedrock-mantle.eu-central-1.api.aws/openai/v1/chat/completions"
BEDROCK_MODEL = "google.gemma-4-26b-a4b"
BEDROCK_REGION = "eu-central-1"

# yt-dlp is pip-installed into the service venv; systemd's PATH can't see it.
YTDLP = os.path.join(os.path.dirname(sys.executable), "yt-dlp")


def require_auth(authorization: str | None):
    """Fail closed: no configured token means no /v1 service."""
    if not API_TOKEN:
        raise HTTPException(status_code=503, detail="API token not configured")
    if authorization != f"Bearer {API_TOKEN}":
        raise HTTPException(status_code=401, detail="bad token")


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
def video_transcript(body: TranscriptRequest, authorization: str | None = Header(None)):
    require_auth(authorization)
    if not GROQ_API_KEY:
        raise HTTPException(status_code=503, detail="transcription not configured")
    if not re.match(r"^https://(www\.)?tiktok(v)?\.com/", body.url):
        raise HTTPException(status_code=400, detail="not a tiktok url")

    with tempfile.TemporaryDirectory() as td:
        # Keep yt-dlp's native container — Groq accepts m4a/mp4/webm alike.
        dl = subprocess.run(
            [YTDLP, "-q", "--no-warnings", "-f", "bestaudio/best",
             "-o", os.path.join(td, "audio.%(ext)s"), body.url],
            capture_output=True, timeout=180)
        produced = [os.path.join(td, f) for f in os.listdir(td) if f.startswith("audio.")]
        if dl.returncode != 0 or not produced:
            # deleted / private / region-locked — a normal library condition
            return {"transcript": None, "duration": 0, "unavailable": True}
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
                headers={"Authorization": f"Bearer {GROQ_API_KEY}"},
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
    return {"transcript": text or None, "duration": data.get("duration", 0)}


# ---------------------------------------------------------------- analyze proxy

_token_cache: dict = {"token": None, "expires": 0.0}


def _bedrock_token() -> str:
    if _token_cache["token"] and time.time() < _token_cache["expires"]:
        return _token_cache["token"]
    from aws_bedrock_token_generator import provide_token
    _token_cache["token"] = provide_token(region=BEDROCK_REGION)
    _token_cache["expires"] = time.time() + 300  # regenerate every 5 min
    return _token_cache["token"]


ANALYSIS_SYSTEM_PROMPT = """
You classify a short video into a single strict JSON object. Respond with ONLY the JSON
object, with category, title, summary, and topics fields. Category must be one of
recipe, fitness, style, travel, home, learning, comedy, music, coding, or other
(fitness=workouts/gym/nutrition, style=fashion/beauty/makeup, travel=trips/destinations,
home=decor/DIY/gardening, learning=facts/how-to/study, comedy=skits/jokes/memes,
coding=software/gadgets/AI); use other only when none fit. Always answer in English. Use
empty strings or arrays when information is missing. Never output placeholder prose. If
caption and transcript are empty, use title \"Saved video\" and summarize that no caption
or audio was available.
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
    return "\n".join(parts) if parts else "(no metadata available)"


def analyze_metadata(metadata: dict) -> dict:
    """Run the existing Bedrock analyzer directly for a worker fast pass."""
    response = requests.post(
        BEDROCK_URL,
        headers={"Authorization": f"Bearer {_bedrock_token()}", "Content-Type": "application/json"},
        json={
            "model": BEDROCK_MODEL,
            "temperature": 0.2,
            "messages": [
                {"role": "system", "content": ANALYSIS_SYSTEM_PROMPT},
                {"role": "user", "content": build_analysis_prompt(metadata)},
            ],
        },
        timeout=120,
    )
    if response.status_code != 200:
        error = requests.HTTPError(f"bedrock {response.status_code}", response=response)
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
def chat_completions(body: dict, authorization: str | None = Header(None)):
    require_auth(authorization)
    body["model"] = BEDROCK_MODEL  # pinned server-side; client value ignored
    # Gemma via Mantle rejects OpenAI's response_format param; the prompt already
    # demands bare JSON and the app strips fences, so drop it rather than 400.
    body.pop("response_format", None)
    resp = requests.post(
        BEDROCK_URL,
        headers={"Authorization": f"Bearer {_bedrock_token()}",
                 "Content-Type": "application/json"},
        json=body, timeout=120)
    return Response(content=resp.content, status_code=resp.status_code,
                    media_type="application/json")


# ---------------------------------------------------------------- keep-offline

@router.get("/tiktok/download/{video_id}")
def tiktok_download(video_id: str, authorization: str | None = Header(None)):
    require_auth(authorization)
    if not re.fullmatch(r"\d{5,25}", video_id):
        raise HTTPException(status_code=400, detail="bad video id")
    with tempfile.TemporaryDirectory() as td:
        out = os.path.join(td, f"{video_id}.mp4")
        dl = subprocess.run(
            [YTDLP, "-q", "--no-warnings", "-f", "mp4", "-o", out,
             f"https://www.tiktok.com/@/video/{video_id}"],
            capture_output=True, timeout=180)
        if dl.returncode != 0 or not os.path.exists(out):
            raise HTTPException(status_code=502, detail="download failed")
        data = open(out, "rb").read()
    return Response(content=data, media_type="video/mp4")


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
