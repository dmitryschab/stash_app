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


def filter_transcript(lines: list[str]) -> str:
    out: list[str] = []
    for line in lines:
        line = re.sub(r"\s+", " ", line).strip()
        if not line:
            continue
        if out and line == out[-1]:
            continue
        if _ngram_loops(line):
            continue
        out.append(line)
    counts = Counter(out)
    out = [l for l in out if counts[l] <= 4]
    text = "\n".join(out).strip()
    return text if len(text.split()) >= 12 else ""


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
                data={"model": GROQ_MODEL, "response_format": "verbose_json"},
                timeout=120)

    if resp.status_code == 429:
        retry = resp.headers.get("retry-after", "60")
        raise HTTPException(status_code=429, detail="transcription throttled",
                            headers={"Retry-After": retry})
    if resp.status_code != 200:
        raise HTTPException(status_code=502, detail=f"groq {resp.status_code}")

    data = resp.json()
    lines = [s.get("text", "") for s in data.get("segments", [])]
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
    print("api_v1 selftest OK")


if __name__ == "__main__":
    selftest()
