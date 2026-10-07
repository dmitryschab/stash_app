"""Clef — Cloudflare's decision model, through OpenRouter's System One endpoint.

Clef answers a bounded question with one probability per option in a single forward pass:
no text, no parsing. Here it answers exactly one question per video — which of the thirteen
Stash categories fits — so a fresh import gets its shape in seconds while Gemma's full
analysis (title, summary, recipe, picks) runs behind it. Measured against Gemma's own
labels on the owner's library: top-1 agreement 84 % on text alone, 86 % with the cover.
The cover costs double the latency and a CDN fetch per video, so this sends text only.

The guess is the first word, not the last: `CloudImportResultUpserter` on the phone
overwrites it the moment the fast pass lands. Nothing here is charged to the import quota.
"""

from __future__ import annotations

import logging
import re

import requests

import stash_secrets

log = logging.getLogger("stash-webhook")

CLEF_URL = "https://openrouter.ai/api/v1/systemone"
CLEF_MODEL = "cloudflare/clef-flash"
CLEF_TIMEOUT = 10

QUESTION = "Which single category best describes what this short video is about?"

# One line per category, the same wording the canonical analysis prompt gives Gemma
# (api_v1.ANALYSIS_SYSTEM_PROMPT), so both models are asked the same taxonomy.
CATEGORIES = {
    "recipe": "cooking a dish: a recipe with ingredients or steps, baking, meal prep",
    "fitness": "workouts, gym, running, sports training, nutrition for training",
    "style": "fashion, outfits, beauty, makeup, skincare routines, hair",
    "travel": "trips, destinations, hotels, flights, city guides",
    "home": "decor, interior, cleaning, DIY, renovation, gardening",
    "learning": "facts, how-to, study tips, science, history, explainers",
    "comedy": "skits, jokes, memes, pranks, funny moments",
    "music": "songs, albums, artists, music recommendations or lists, concerts",
    "coding": "software, programming, gadgets, AI tools, linux, self-hosting, dev tools",
    "film": "movies, TV series, anime, what to watch, film lists",
    "dining": "restaurants, cafes, coffee, wine, bars, eating out",
    "wellness": "health, supplements, sleep, mental health, therapy, habits",
    "other": "none of the other categories fit",
}

# TikTok's "original sound" label in every locale the library has met.
ORIGINAL_SOUND = re.compile(
    r"original sound|originalton|son original|sonido original|som original|suono originale|"
    r"оригинальный звук|原聲|原声|âm thanh gốc|オリジナル楽曲|suara asli|orijinal ses|"
    r"dźwięk oryginalny|originele geluid|originalljud", re.I)


def openrouter_key() -> str:
    return stash_secrets.secret("OPENROUTER_API_KEY")


def state_from_metadata(metadata: dict) -> dict:
    """The fields Clef reads, from one yt-dlp `--dump-single-json` record — the same ones
    the fast pass hands Gemma, minus the images."""
    caption = metadata.get("description") or ""
    track = metadata.get("track") or ""
    return {
        "caption": caption,
        "hashtags": metadata.get("tags") or re.findall(r"#(\w+)", caption),
        "author": metadata.get("uploader") or metadata.get("channel") or "",
        "sound_title": track,
        "sound_artist": metadata.get("artist") or "",
        "is_original_sound": bool(ORIGINAL_SOUND.search(track)),
        "duration_s": metadata.get("duration"),
    }


def classify(state: dict) -> tuple[str, float] | None:
    """Clef-flash's category for one video, with its probability — or None on any failure.

    None is the whole error contract: a map with one fewer guess is still a map, and the
    caller must never wait on, retry, or fail an import over a first guess.
    """
    body = {
        "model": CLEF_MODEL,
        "state": state,
        "questions": {"category": {"type": "choice", "instructions": QUESTION, "criteria": CATEGORIES}},
    }
    try:
        response = requests.post(CLEF_URL, json=body, timeout=CLEF_TIMEOUT,
                                 headers={"Authorization": f"Bearer {openrouter_key()}"})
    except requests.RequestException as error:
        log.warning("clef unreachable: %s", error)
        return None
    if response.status_code != 200:
        log.warning("clef %s: %s", response.status_code, response.text[:200])
        return None
    try:
        answer = response.json()["answers"]["category"]
        choice = answer["choice"]
        probability = float(answer.get("probabilities", {}).get(choice, answer.get("confidence", 0.0)))
    except (ValueError, KeyError, TypeError) as error:
        log.warning("clef malformed answer: %r", error)
        return None
    if choice not in CATEGORIES:
        log.warning("clef answered off the list: %r", choice)
        return None
    return choice, probability
