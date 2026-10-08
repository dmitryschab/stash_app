# Clef Onboarding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give a fresh library its shape within seconds of an import being accepted: a Clef-classified sample drives a distribution bar, tinted skeleton rows in every category, and a one-time "what do you want to find fast?" picker that puts any category on the tab pill.

**Architecture:** The server classifies 60 evenly spaced videos of each new import with Cloudflare's `clef-flash` (text state, via OpenRouter's System One endpoint) on a background thread pool and reports counts and guesses on the existing status poll. The Kit decodes that map, writes guesses into empty rows, and the app scales the sample's shares to the import's total to draw skeletons; a generic `CategoryView` lets any category hold a tab slot. Gemma's full analysis keeps running and overwrites the guesses.

**Tech Stack:** Python 3.11 + FastAPI + `requests` + DynamoDB (server, pytest); Swift 6 SwiftData Kit (XCTest); SwiftUI iOS app (XcodeGen, DEBUG self-tests).

**Spec:** `docs/superpowers/specs/2026-10-07-clef-onboarding-classification-design.md`

## Global Constraints

- Branch `feat/clef-onboarding`, based on `feat/tiktok-portability-p2`. Never rebase onto `main`.
- Server tests: `cd services/webhook && uv run --with-requirements requirements.txt --with pytest --with cryptography python -m pytest -q`. There is no venv; Homebrew `python3` lacks the deps.
- Kit tests: `cd TikTokBrainKit && swift test`. Check both summary lines ("Executed N tests" and "Test run with N tests").
- App: after adding a file run `cd App && xcodegen generate`, then `xcodebuild -project Stash.xcodeproj -scheme Stash -destination 'generic/platform=iOS Simulator' build`.
- `OPENROUTER_API_KEY` is read through `stash_secrets.secret`; never print it, never write it to a file, never commit it.
- Clef endpoint `https://openrouter.ai/api/v1/systemone`, model `cloudflare/clef-flash`, 10 s timeout, text state only, no quota charge.
- `MAP_SAMPLE = 60`; picker offers at most 6 categories, accepts at most 3 picks; skeleton shelves show at most 5 rows plus "+N more sorting".
- `ANALYSIS_REVISION` stays at 8. No SwiftData migration: "guessed" is `Video.isGuessed`, derived as `!categoryRaw.isEmpty && title.isEmpty && summary.isEmpty`. Not the revision: rows analysed by the old on-device pipeline, and the demo seed, sit at revision 0 with titles.
- Copy voice: short, plain, no exclamation marks, matches the existing screens ("Sorting", "saves", "shelves").
- Commit messages: `feat(scope): …` / `test(scope): …`, no co-author footer, no "Generated with".

## Review Focus

- An import of fewer than 20 videos: the map's `done` reaches `sampled` quickly; the picker must still wait for `done >= min(20, sampled)` and at least one non-`other` count (Task 8 self-test covers a 3-video map).
- A map whose every guess is `other`: no picker, and the account's key stays unset so a later import can still show it (Task 8 self-test).
- Status with `fastPass.total == 0` or `map.done == 0`: `expected` must return 0 without dividing by zero (Task 5 self-test).
- A video the phone already analysed at revision 8 appearing in `guesses` (a re-import of an existing library): `applyGuesses` must leave it alone (Task 4 test).
- Two `POST /v1/imports` with the same `clientImportID` in flight: exactly one map pass (Task 3 test).

---

### Task 1: `clef.py` — the classifier

**Files:**
- Create: `services/webhook/clef.py`
- Modify: `services/webhook/api_v1.py:112-113` (replace `_openrouter_key` with an import)
- Test: `services/webhook/test_clef.py`

**Interfaces:**
- Consumes: `stash_secrets.secret(name)`.
- Produces: `clef.classify(state: dict) -> tuple[str, float] | None`, `clef.state_from_metadata(metadata: dict) -> dict`, `clef.openrouter_key() -> str`, `clef.CATEGORIES: dict[str, str]`.

- [ ] **Step 1: Write the failing tests**

```python
# services/webhook/test_clef.py
"""clef.classify: one choice question, every failure is None, never raises."""
import json

import pytest
import requests

import clef


class Resp:
    def __init__(self, status, body):
        self.status_code = status
        self._body = body
        self.text = json.dumps(body) if isinstance(body, dict) else str(body)

    def json(self):
        if isinstance(self._body, dict):
            return self._body
        raise ValueError("not json")


@pytest.fixture(autouse=True)
def key(monkeypatch):
    monkeypatch.setenv("OPENROUTER_API_KEY", "test-key")


def answer(choice, probability=0.91):
    return {"answers": {"category": {"type": "choice", "choice": choice,
                                     "probabilities": {choice: probability, "other": 1 - probability}}}}


def test_a_well_formed_answer_returns_the_choice_and_its_probability(monkeypatch):
    sent = {}

    def post(url, json=None, timeout=None, headers=None):
        sent.update(url=url, body=json, timeout=timeout, headers=headers)
        return Resp(200, answer("coding"))

    monkeypatch.setattr(clef.requests, "post", post)
    assert clef.classify({"caption": "arch linux rice"}) == ("coding", 0.91)
    assert sent["url"] == clef.CLEF_URL
    assert sent["timeout"] == clef.CLEF_TIMEOUT
    assert sent["headers"]["Authorization"] == "Bearer test-key"
    assert sent["body"]["model"] == "cloudflare/clef-flash"
    assert sent["body"]["state"] == {"caption": "arch linux rice"}
    question = sent["body"]["questions"]["category"]
    assert question["type"] == "choice"
    assert set(question["criteria"]) == set(clef.CATEGORIES)


@pytest.mark.parametrize("status,body", [
    (429, {"error": "slow down"}),
    (500, {"error": "boom"}),
    (200, {"answers": {}}),
    (200, "not json"),
    (200, answer("gardening")),          # off the enum
])
def test_every_bad_reply_is_none(monkeypatch, status, body):
    monkeypatch.setattr(clef.requests, "post", lambda *a, **k: Resp(status, body))
    assert clef.classify({"caption": "x"}) is None


def test_a_timeout_is_none(monkeypatch):
    def post(*a, **k):
        raise requests.Timeout("slow")
    monkeypatch.setattr(clef.requests, "post", post)
    assert clef.classify({"caption": "x"}) is None


def test_the_state_is_built_from_ytdlp_metadata():
    state = clef.state_from_metadata({
        "description": "pasta night #recipe #easy", "tags": ["recipe", "easy"],
        "uploader": "cook", "track": "original sound - cook", "artist": "cook", "duration": 31.5,
    })
    assert state == {
        "caption": "pasta night #recipe #easy", "hashtags": ["recipe", "easy"], "author": "cook",
        "sound_title": "original sound - cook", "sound_artist": "cook",
        "is_original_sound": True, "duration_s": 31.5,
    }


def test_hashtags_fall_back_to_the_caption_when_metadata_has_no_tags():
    state = clef.state_from_metadata({"description": "lift day #gym #fitness"})
    assert state["hashtags"] == ["gym", "fitness"]
    assert state["is_original_sound"] is False
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd services/webhook && uv run --with-requirements requirements.txt --with pytest --with cryptography python -m pytest -q test_clef.py`
Expected: FAIL with `ModuleNotFoundError: No module named 'clef'`

- [ ] **Step 3: Write `clef.py`**

```python
# services/webhook/clef.py
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
```

- [ ] **Step 4: Point `api_v1.py` at the shared key helper**

In `services/webhook/api_v1.py`, replace lines 112–113:

```python
def _openrouter_key() -> str:
    return stash_secrets.secret("OPENROUTER_API_KEY")
```

with:

```python
from clef import openrouter_key as _openrouter_key  # one key helper for every OpenRouter call
```

(Keep it at the same place in the file, below the `OPENROUTER_*` constants, so the vision
path reads unchanged.)

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd services/webhook && uv run --with-requirements requirements.txt --with pytest --with cryptography python -m pytest -q test_clef.py test_api_v1.py`
Expected: all PASS (test_api_v1 proves the import rewrite did not break the module).

- [ ] **Step 6: Commit**

```bash
git add services/webhook/clef.py services/webhook/test_clef.py services/webhook/api_v1.py
git commit -m "feat(clef): one-question category classifier on OpenRouter's System One endpoint"
```

---

### Task 2: Store and wire — `ImportMap` on the status

**Files:**
- Modify: `services/webhook/cloud_import_models.py:159-176` (add `ImportMap`, `ImportStatus.map`)
- Modify: `services/webhook/cloud_import_store.py:511-524` (`get_status`) and add three methods after `complete_video`
- Modify: `services/webhook/conftest.py:59-76` (`apply_update`: nested paths and `if_not_exists`)
- Test: `services/webhook/test_cloud_import_store.py`, `services/webhook/test_cloud_import_models.py`

**Interfaces:**
- Consumes: `DynamoImportStore._key`, `ConditionalTable.update_item`.
- Produces: `ImportMap(sampled, done, counts, guesses)`; `ImportStatus.map: ImportMap | None`;
  `DynamoImportStore.start_map(import_id, sampled)`, `.guess_video(import_id, video_id, category)`,
  `.skip_map_video(import_id)`.

- [ ] **Step 1: Write the failing tests**

Append to `services/webhook/test_cloud_import_store.py`:

```python
from conftest import ConditionalTable


def test_the_map_counts_guesses_and_skips_on_meta_only():
    table = ConditionalTable()
    store = DynamoImportStore(table=table, user_id=USER)
    created = store.create_import(request(("1", "2", "3")))

    assert store.get_status(created.import_id).map is None     # no map until it starts

    store.start_map(created.import_id, sampled=3)
    store.guess_video(created.import_id, "1", "coding")
    store.guess_video(created.import_id, "2", "coding")
    store.skip_map_video(created.import_id)

    status = store.get_status(created.import_id)
    assert status.map.sampled == 3
    assert status.map.done == 3
    assert status.map.counts == {"coding": 2}
    assert status.map.guesses == {"1": "coding", "2": "coding"}
    # Nothing landed on the video rows: the status poll must not have to scan them.
    assert "guess" not in table.items[(store.partition, f"IMPORT#{created.import_id}#VIDEO#1")]


def test_two_categories_keep_separate_counters():
    store = DynamoImportStore(table=ConditionalTable(), user_id=USER)
    created = store.create_import(request(("1", "2")))
    store.start_map(created.import_id, sampled=2)
    store.guess_video(created.import_id, "1", "recipe")
    store.guess_video(created.import_id, "2", "music")
    assert store.get_status(created.import_id).map.counts == {"recipe": 1, "music": 1}
```

Append to `services/webhook/test_cloud_import_models.py`:

```python
def test_import_status_serialises_the_map_and_omits_it_when_absent():
    from datetime import datetime, timezone
    from cloud_import_models import ImportMap, ImportState, ImportStatus, Progress
    base = dict(importID="i", state=ImportState.FAST_PASS, fastPass=Progress(done=0, total=10),
                unavailable=0, partialFailures=0, estimatedCostUSD=0.0,
                updatedAt=datetime.now(timezone.utc))
    assert ImportStatus(**base).model_dump(by_alias=True)["map"] is None
    with_map = ImportStatus(**base, map=ImportMap(sampled=2, done=1, counts={"coding": 1}, guesses={"7": "coding"}))
    assert with_map.model_dump(by_alias=True)["map"] == {
        "sampled": 2, "done": 1, "counts": {"coding": 1}, "guesses": {"7": "coding"}}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd services/webhook && uv run --with-requirements requirements.txt --with pytest --with cryptography python -m pytest -q test_cloud_import_store.py test_cloud_import_models.py`
Expected: FAIL with `AttributeError: 'ImportStatus' object has no attribute 'map'` and `'DynamoImportStore' object has no attribute 'start_map'`.

- [ ] **Step 3: Add the wire model**

In `services/webhook/cloud_import_models.py`, directly above `class ImportStatus`:

```python
class ImportMap(ContractModel):
    """The first sort of a sample of the import: how many were sampled, how many Clef has
    answered (skips included), the answers tallied by category, and each sampled video's
    guess. The phone scales `counts` to the import's total for its skeleton rows."""
    sampled: int
    done: int
    counts: dict[str, int] = Field(default_factory=dict)      # category -> n
    guesses: dict[str, str] = Field(default_factory=dict)     # videoID -> category
```

and in `ImportStatus`, after `updated_at`:

```python
    # None until the map pass has started — a status from before this field, or an import
    # whose map never ran, reads as "no map" and the phone behaves as it did before.
    map: ImportMap | None = None
```

- [ ] **Step 4: Teach the fake table nested paths and `if_not_exists`**

In `services/webhook/conftest.py`, replace `apply_update` (lines 59–76) with:

```python
def _path(token: str, names: dict) -> list[str]:
    """`mapCounts.#c` → ["mapCounts", "coding"]: a document path, names resolved."""
    return [names.get(part, part) for part in token.strip().split(".")]


def _get_path(item: dict, path: list[str]):
    node = item
    for part in path:
        if not isinstance(node, dict):
            return None
        node = node.get(part)
    return node


def _set_path(item: dict, path: list[str], value) -> None:
    node = item
    for part in path[:-1]:
        node = node.setdefault(part, {})
    node[path[-1]] = value


def _operand(token: str, item: dict, names: dict, values: dict):
    """A value token: `:v`, `if_not_exists(path,:v)` (no space after the comma — the
    assignment splitter cuts on ", "), or a document path read for arithmetic."""
    token = token.strip()
    if token.startswith(":"):
        return values[token]
    if token.startswith("if_not_exists(") and token.endswith(")"):
        path_token, default = token[len("if_not_exists("):-1].split(",", 1)
        existing = _get_path(item, _path(path_token, names))
        return existing if existing is not None else values[default.strip()]
    return _get_path(item, _path(token, names))


def apply_update(item: dict, expression: str, names: dict, values: dict) -> None:
    if not expression.startswith("SET "):
        raise NotImplementedError(f"fake table cannot apply {expression!r}")
    for assignment in expression[4:].split(", "):
        name, value = [part.strip() for part in assignment.split("=", 1)]
        target = _path(name, names)
        for symbol, combine in ((" + ", operator.add), (" - ", operator.sub)):
            if symbol in value:
                base, operand = [part.strip() for part in value.split(symbol, 1)]
                _set_path(item, target, combine(_operand(base, item, names, values) or 0, values[operand]))
                break
        else:
            if not (value.startswith(":") or value.startswith("if_not_exists(")):
                raise NotImplementedError(f"fake table cannot evaluate {value!r}")
            _set_path(item, target, _operand(value, item, names, values))
```

- [ ] **Step 5: Add the store methods**

In `services/webhook/cloud_import_store.py`, after `complete_video` (before `fail_video`):

```python
    # ---------------------------------------------------------------- map pass

    def start_map(self, import_id: str, sampled: int) -> None:
        """Open the map on META: how many will be classified, nothing answered yet."""
        self.table.update_item(
            Key=self._key(import_id, "META"),
            UpdateExpression="SET mapSampled = :sampled, mapDone = :zero, mapCounts = :counts, mapGuesses = :guesses",
            ExpressionAttributeValues={":sampled": sampled, ":zero": 0, ":counts": {}, ":guesses": {}},
        )

    def guess_video(self, import_id: str, video_id: str, category: str) -> None:
        """One answer: advance done, tally the category, remember the guess. All on META, one
        atomic update, so eight threads tallying at once cannot lose a count — and so the
        status poll reads one row instead of scanning twelve hundred."""
        self.table.update_item(
            Key=self._key(import_id, "META"),
            # No space after the comma inside if_not_exists: DynamoDB accepts it either way,
            # and the test double splits assignments on ", ".
            UpdateExpression="SET mapDone = mapDone + :one, mapCounts.#c = if_not_exists(mapCounts.#c,:zero) + :one, mapGuesses.#v = :c",
            ExpressionAttributeNames={"#c": category, "#v": video_id},
            ExpressionAttributeValues={":one": 1, ":zero": 0, ":c": category},
        )

    def skip_map_video(self, import_id: str) -> None:
        """A sampled video Clef or yt-dlp could not answer still counts as done: `done` is
        the phone's "the map has settled" signal, and a skip must not stall it."""
        self.table.update_item(
            Key=self._key(import_id, "META"),
            UpdateExpression="SET mapDone = mapDone + :one",
            ExpressionAttributeValues={":one": 1},
        )
```

and in `get_status`, add to the `ImportStatus(...)` call after `updatedAt=item["updatedAt"],`:

```python
            map=ImportMap(
                sampled=int(item["mapSampled"]),
                done=int(item.get("mapDone", 0)),
                counts={key: int(value) for key, value in (item.get("mapCounts") or {}).items()},
                guesses={key: str(value) for key, value in (item.get("mapGuesses") or {}).items()},
            ) if "mapSampled" in item else None,
```

Add `ImportMap` to the `from cloud_import_models import (...)` list at the top of the file.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `cd services/webhook && uv run --with-requirements requirements.txt --with pytest --with cryptography python -m pytest -q`
Expected: all PASS (the whole suite — `apply_update` is shared by every conditional-table test).

- [ ] **Step 7: Commit**

```bash
git add services/webhook/cloud_import_models.py services/webhook/cloud_import_store.py services/webhook/conftest.py services/webhook/test_cloud_import_store.py services/webhook/test_cloud_import_models.py
git commit -m "feat(import): the status carries a map — sampled, done, counts and guesses on META"
```

---

### Task 3: The map pass on `POST /v1/imports`

**Files:**
- Modify: `services/webhook/cloud_import_pipeline.py:136-152` (lift `_metadata` to `fetch_metadata`)
- Modify: `services/webhook/cloud_import_api.py` (pool, `sample_for_map`, `start_map_pass`, call in `create_import`)
- Test: `services/webhook/test_cloud_import_api.py`

**Interfaces:**
- Consumes: `clef.classify`, `clef.state_from_metadata`, store methods from Task 2, `FastPassPipeline._metadata`.
- Produces: `cloud_import_pipeline.fetch_metadata(url) -> dict | None`; `cloud_import_api.sample_for_map(videos, size=MAP_SAMPLE)`, `cloud_import_api.start_map_pass(store, import_id, videos, pool=None) -> int`, `cloud_import_api._MAP_POOL`.

- [ ] **Step 1: Write the failing tests**

Append to `services/webhook/test_cloud_import_api.py`:

```python
class InlinePool:
    """Runs each submission on the spot, so a test sees the map finished when the route returns."""
    def __init__(self):
        self.submitted = 0

    def submit(self, fn, *args):
        self.submitted += 1
        fn(*args)


class MapStore(FakeStore):
    def __init__(self):
        super().__init__()
        self.map = None

    def start_map(self, import_id, sampled):
        self.map = {"importID": import_id, "sampled": sampled, "done": 0, "counts": {}, "guesses": {}}

    def guess_video(self, import_id, video_id, category):
        self.map["done"] += 1
        self.map["counts"][category] = self.map["counts"].get(category, 0) + 1
        self.map["guesses"][video_id] = category

    def skip_map_video(self, import_id):
        self.map["done"] += 1


@pytest.fixture
def map_dependencies(monkeypatch):
    store = MapStore()
    queue = FakeQueue()
    pool = InlinePool()
    app.dependency_overrides[stash_auth.current_user] = lambda: USER_ID
    app.dependency_overrides[stash_auth.user_store] = lambda: store
    app.dependency_overrides[stash_auth.entitled_store] = lambda: store
    app.dependency_overrides[cloud_import_api.get_queue] = lambda: queue
    monkeypatch.setattr(cloud_import_api, "_MAP_POOL", pool)
    monkeypatch.setattr(cloud_import_api, "fetch_metadata",
                        lambda url: {"description": f"video {url.rsplit('/', 1)[1]} #linux", "tags": ["linux"]})
    monkeypatch.setattr(cloud_import_api.clef, "classify", lambda state: ("coding", 0.9))
    yield store, queue, pool
    app.dependency_overrides.clear()


def test_sample_is_evenly_spaced_and_capped():
    videos = list(range(300))
    sample = cloud_import_api.sample_for_map(videos)
    assert len(sample) == 60
    assert sample[:3] == [0, 5, 10]            # every fifth, from the first
    assert sample[-1] == 295
    assert cloud_import_api.sample_for_map(list(range(7))) == list(range(7))   # fewer than 60: all
    assert cloud_import_api.sample_for_map([]) == []


def test_a_new_import_starts_the_map_and_tallies_guesses(map_dependencies):
    store, queue, pool = map_dependencies
    with TestClient(app) as client:
        response = client.post("/v1/imports", json=payload(3))
    import_id = response.json()["importID"]
    assert pool.submitted == 3
    assert store.map == {"importID": import_id, "sampled": 3, "done": 3,
                         "counts": {"coding": 3}, "guesses": {"1": "coding", "2": "coding", "3": "coding"}}
    assert len(queue.messages) == 3           # the fast pass is untouched
    assert store.initial == INITIAL_LIMIT - 3  # the map charged nothing extra


def test_a_clef_failure_still_counts_as_done(map_dependencies, monkeypatch):
    store, _, _ = map_dependencies
    answers = iter([("coding", 0.9), None, ("recipe", 0.8)])
    monkeypatch.setattr(cloud_import_api.clef, "classify", lambda state: next(answers))
    with TestClient(app) as client:
        client.post("/v1/imports", json=payload(3))
    assert store.map["done"] == 3
    assert store.map["counts"] == {"coding": 1, "recipe": 1}


def test_missing_metadata_is_a_skip_not_a_crash(map_dependencies, monkeypatch):
    store, _, _ = map_dependencies
    monkeypatch.setattr(cloud_import_api, "fetch_metadata", lambda url: None)
    with TestClient(app) as client:
        client.post("/v1/imports", json=payload(2))
    assert store.map == {"importID": store.map["importID"], "sampled": 2, "done": 2, "counts": {}, "guesses": {}}


def test_a_retry_does_not_start_a_second_map(map_dependencies):
    store, _, pool = map_dependencies
    with TestClient(app) as client:
        client.post("/v1/imports", json=payload(2))
        client.post("/v1/imports", json=payload(2))
    assert pool.submitted == 2
    assert store.map["sampled"] == 2
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd services/webhook && uv run --with-requirements requirements.txt --with pytest --with cryptography python -m pytest -q test_cloud_import_api.py`
Expected: FAIL with `AttributeError: module 'cloud_import_api' has no attribute 'sample_for_map'` (and `_MAP_POOL`).

- [ ] **Step 3: Lift the metadata fetch out of the pipeline class**

In `services/webhook/cloud_import_pipeline.py`, replace the `_metadata` method (lines 136–152) with a module-level function above `class FastPassPipeline`, and keep a one-line method delegating to it:

```python
def fetch_metadata(url: str) -> dict | None:
    """One yt-dlp metadata record for `url` — caption, tags, sound, cover — with no download.
    None when the video is gone or private; raises PipelineError on a timeout or bad JSON."""
    try:
        completed = subprocess.run(
            [YTDLP, "--dump-single-json", "--skip-download", "--no-warnings", "--socket-timeout", "30", url],
            capture_output=True,
            text=True,
            timeout=90,
        )
    except subprocess.TimeoutExpired as error:
        raise PipelineError("yt-dlp timed out", True, "metadata_timeout") from error
    if completed.returncode != 0 or not completed.stdout.strip():
        return None
    try:
        metadata = json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        raise PipelineError("yt-dlp returned invalid JSON", False, "invalid_metadata") from error
    return metadata if isinstance(metadata, dict) and metadata else None
```

```python
    def _metadata(self, url: str) -> dict | None:
        return fetch_metadata(url)
```

- [ ] **Step 4: Add the map pass to the API**

In `services/webhook/cloud_import_api.py`, extend the imports:

```python
import logging
from concurrent.futures import ThreadPoolExecutor

import clef
from cloud_import_pipeline import fetch_metadata
```

Below `router = APIRouter(prefix="/v1")`:

```python
log = logging.getLogger("stash-webhook")

# How many videos of an import get a first guess from Clef. Sixty evenly spaced through a
# thousand-video library puts a category's share within about ±12 points — enough to shape
# the shelves — and finishes in ~10 s at eight wide.
MAP_SAMPLE = 60

# One pool per process, shared by every import. Eight threads is the whole budget however
# many imports arrive at once: each task is one yt-dlp run (~1.3 s) and one Clef call
# (~0.4 s), and the box is also running the fast-pass worker.
_MAP_POOL = ThreadPoolExecutor(max_workers=8, thread_name_prefix="map")


def sample_for_map(videos: list, size: int = MAP_SAMPLE) -> list:
    """Evenly spaced through the submission. The phone sends newest-first, so a stride walks
    the whole date range rather than the newest week — the picker is about the library, not
    about last Tuesday."""
    stride = max(1, len(videos) // size)
    return videos[::stride][:size]


def _map_one(store: DynamoImportStore, import_id: str, video_id: str, url: str) -> None:
    try:
        metadata = fetch_metadata(url)
        guess = clef.classify(clef.state_from_metadata(metadata)) if metadata else None
    except Exception:
        # The journal is the only place this lands; the map just has one fewer answer.
        log.exception("map pass failed video=%s import=%s", video_id, import_id)
        guess = None
    if guess is None:
        store.skip_map_video(import_id)
        return
    category, probability = guess
    log.info("map guess import=%s video=%s category=%s p=%.2f", import_id, video_id, category, probability)
    store.guess_video(import_id, video_id, category)


def start_map_pass(store: DynamoImportStore, import_id: str, videos: list, pool=None) -> int:
    """Open the map and hand a sample of the import to the pool. Returns how many were sampled.
    Never raises: the import is already accepted and charged by the time this runs."""
    sample = sample_for_map(videos)
    try:
        store.start_map(import_id, sampled=len(sample))
    except Exception:
        log.exception("could not start the map for import=%s", import_id)
        return 0
    pool = pool or _MAP_POOL
    for video in sample:
        pool.submit(_map_one, store, import_id, video.video_id, video.url)
    return len(sample)
```

In `create_import`, in the `else:` branch, replace:

```python
        else:
            for video in body.videos:
                queue.enqueue(store.user_id, created.import_id, video.video_id, url=video.url)
```

with:

```python
        else:
            for video in body.videos:
                queue.enqueue(store.user_id, created.import_id, video.video_id, url=video.url)
            # After the queue, never before: the fast pass is what the user paid for, and a
            # first guess that delayed it would be a worse deal than no guess.
            start_map_pass(store, created.import_id, body.videos)
```

(The retry branch above it, and the `not created.created` refund branch, start no map.)

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd services/webhook && uv run --with-requirements requirements.txt --with pytest --with cryptography python -m pytest -q`
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add services/webhook/cloud_import_api.py services/webhook/cloud_import_pipeline.py services/webhook/test_cloud_import_api.py
git commit -m "feat(import): classify a 60-video sample with Clef the moment an import is accepted"
```

---

### Task 4: Kit — decode the map, apply guesses

**Files:**
- Modify: `TikTokBrainKit/Sources/TikTokBrainKit/CloudImport.swift` (`CloudImportMap`, `CloudImportStatus.map`, `apply(status:)`, upserter)
- Modify: `TikTokBrainKit/Sources/TikTokBrainKit/Core/Entities.swift` (`Video.isGuessed`)
- Test: `TikTokBrainKit/Tests/TikTokBrainKitTests/CloudImportTests.swift`

**Interfaces:**
- Consumes: `Category`, `Video`, `CloudImportResultUpserter.apply`.
- Produces: `public struct CloudImportMap { sampled, done, counts: [Category: Int], guesses: [String: Category] }`; `CloudImportStatus.map: CloudImportMap?` (init param `map: CloudImportMap? = nil`, last); `CloudImportResultUpserter.applyGuesses(_ guesses: [String: Category], to context: ModelContext) throws -> Int`; `Video.isGuessed: Bool`.

- [ ] **Step 1: Write the failing tests**

Add to `CloudImportTests.swift` (inside the class):

```swift
    func testStatusDecodesWithAndWithoutAMapAndDropsUnknownCategories() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let base = """
        {"importID":"i","state":"fast_pass","fastPass":{"done":0,"total":10},"unavailable":0,
         "partialFailures":0,"estimatedCostUSD":0,"updatedAt":"2026-10-07T10:00:00Z"
        """
        let without = try decoder.decode(CloudImportStatus.self, from: Data((base + "}").utf8))
        XCTAssertNil(without.map)

        let with = try decoder.decode(CloudImportStatus.self, from: Data((base + """
        ,"map":{"sampled":3,"done":2,"counts":{"coding":1,"gardening":1},"guesses":{"7":"coding","8":"gardening"}}}
        """).utf8))
        let map = try XCTUnwrap(with.map)
        XCTAssertEqual(map.sampled, 3)
        XCTAssertEqual(map.done, 2)
        XCTAssertEqual(map.counts, [.coding: 1])
        XCTAssertEqual(map.guesses, ["7": .coding])

        // Round-trips through the persisted sync state.
        let encoded = try JSONEncoder().encode(with)
        XCTAssertEqual(try decoder.decode(CloudImportStatus.self, from: encoded).map, map)
    }

    func testSyncStateKeepsTheMapWithTheHigherDone() {
        var state = CloudImportSyncState(importID: "import-1")
        let early = CloudImportMap(sampled: 60, done: 10, counts: [.coding: 10])
        let late = CloudImportMap(sampled: 60, done: 40, counts: [.coding: 30, .recipe: 10])
        state.apply(status: status(state: .fastPass, done: 1, map: late))
        state.apply(status: status(state: .fastPass, done: 2, map: early))
        XCTAssertEqual(state.status?.map, late)
        state.apply(status: status(state: .fastPass, done: 3, map: nil))
        XCTAssertEqual(state.status?.map, late)   // a poll without a map does not erase it
    }

    func testGuessesFillOnlyEmptyUnanalysedRowsAndTheFastPassOverridesThem() throws {
        let container = try ModelContainer(for: Video.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        for id in ["1", "2", "3"] {
            context.insert(Video(videoID: id, url: URL(string: "https://www.tiktok.com/@x/video/\(id)")!,
                                 bookmarkedAt: Date(timeIntervalSince1970: 1)))
        }
        try context.save()
        // "2" was analysed in an earlier import.
        _ = try CloudImportResultUpserter.apply([CloudImportResult(videoID: "2", analysisRevision: 8, category: "music")], to: context)

        let changed = try CloudImportResultUpserter.applyGuesses(["1": .coding, "2": .recipe, "9": .film], to: context)
        XCTAssertEqual(changed, 1)
        let videos = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<Video>()).map { ($0.videoID, $0) })
        XCTAssertEqual(videos["1"]?.categoryRaw, "coding")
        XCTAssertEqual(videos["1"]?.isGuessed, true)               // a guess is not an analysis
        XCTAssertEqual(videos["2"]?.categoryRaw, "music")          // analysed rows are left alone
        XCTAssertEqual(videos["2"]?.isGuessed, false)
        XCTAssertEqual(videos["3"]?.categoryRaw, "")
        XCTAssertEqual(videos["3"]?.isGuessed, false)              // nothing is not a guess

        XCTAssertEqual(try CloudImportResultUpserter.applyGuesses(["1": .coding], to: context), 0)   // idempotent

        _ = try CloudImportResultUpserter.apply([CloudImportResult(videoID: "1", analysisRevision: 8, category: "learning", title: "Real")], to: context)
        XCTAssertEqual(videos["1"]?.categoryRaw, "learning")       // the fast pass wins a disagreement
        XCTAssertEqual(videos["1"]?.isGuessed, false)
    }

    func testARowAnalysedOnDeviceAtRevisionZeroIsNotAGuess() {
        // The old on-device pipeline and the demo seed both leave revision 0 behind — with a
        // title. Only a row with a category and nothing else is Clef's.
        let video = Video(videoID: "1", url: URL(string: "https://www.tiktok.com/@x/video/1")!, bookmarkedAt: Date())
        video.categoryRaw = "recipe"
        video.title = "Pasta"
        XCTAssertFalse(video.isGuessed)
        video.title = ""
        video.summary = "A dish."
        XCTAssertFalse(video.isGuessed)
        video.summary = ""
        XCTAssertTrue(video.isGuessed)
    }

    func testAnUnavailableResultClearsAGuess() throws {
        let container = try ModelContainer(for: Video.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        context.insert(Video(videoID: "1", url: URL(string: "https://www.tiktok.com/@x/video/1")!,
                             bookmarkedAt: Date(timeIntervalSince1970: 1)))
        try context.save()
        _ = try CloudImportResultUpserter.applyGuesses(["1": .coding], to: context)
        _ = try CloudImportResultUpserter.apply([CloudImportResult(videoID: "1", analysisRevision: 8, unavailable: true, errorCode: "unavailable")], to: context)
        let video = try XCTUnwrap(context.fetch(FetchDescriptor<Video>()).first)
        XCTAssertTrue(video.unavailable)
        XCTAssertEqual(video.categoryRaw, "")
    }
```

Extend the test file's `status(...)` helper with a trailing parameter `map: CloudImportMap? = nil` passed through as `map: map`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd TikTokBrainKit && swift test --filter CloudImportTests`
Expected: compile failure, `cannot find 'CloudImportMap' in scope`.

- [ ] **Step 3: Add the map to the Kit**

In `Core/Entities.swift`, inside the existing `public extension Video` (after the class):

```swift
    /// A row Clef has filed but nothing has read: a category and no words. The old on-device
    /// pipeline and the demo seed also leave `cloudAnalysisRevision == 0` behind, but with a
    /// title — so the revision is not the test, the emptiness is.
    var isGuessed: Bool { !categoryRaw.isEmpty && title.isEmpty && summary.isEmpty }
```

In `CloudImport.swift`, above `public struct CloudImportSubmission`:

```swift
/// The first sort of a sample of the import, as the box reports it on every status poll:
/// how many it sampled, how many Clef has answered (skips included), those answers tallied
/// by category, and each sampled video's guess. Shares are the phone's to scale — the box
/// does not know how many of the import's rows the phone already holds.
public struct CloudImportMap: Codable, Equatable, Sendable {
    public var sampled: Int
    public var done: Int
    public var counts: [Category: Int]
    public var guesses: [String: Category]

    public init(sampled: Int, done: Int, counts: [Category: Int] = [:], guesses: [String: Category] = [:]) {
        self.sampled = sampled
        self.done = done
        self.counts = counts
        self.guesses = guesses
    }

    private enum CodingKeys: String, CodingKey { case sampled, done, counts, guesses }

    /// Keys and values arrive as strings. A category this build does not know is dropped,
    /// not folded into `.other` the way `Category.init(from:)` would — a skeleton shelf
    /// counting an unknown category as "other" would be a shelf the user cannot find.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sampled = try values.decodeIfPresent(Int.self, forKey: .sampled) ?? 0
        done = try values.decodeIfPresent(Int.self, forKey: .done) ?? 0
        let rawCounts = try values.decodeIfPresent([String: Int].self, forKey: .counts) ?? [:]
        counts = rawCounts.reduce(into: [:]) { if let category = Category(rawValue: $1.key) { $0[category] = $1.value } }
        let rawGuesses = try values.decodeIfPresent([String: String].self, forKey: .guesses) ?? [:]
        guesses = rawGuesses.reduce(into: [:]) { if let category = Category(rawValue: $1.value) { $0[$1.key] = category } }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sampled, forKey: .sampled)
        try container.encode(done, forKey: .done)
        try container.encode(Dictionary(uniqueKeysWithValues: counts.map { ($0.key.rawValue, $0.value) }), forKey: .counts)
        try container.encode(guesses.mapValues(\.rawValue), forKey: .guesses)
    }
}
```

In `CloudImportStatus`: add `public var map: CloudImportMap?` after `updatedAt`, and a trailing init parameter `map: CloudImportMap? = nil` assigned with `self.map = map`. (Synthesised `Codable` decodes an optional with `decodeIfPresent`, so an older box's status still decodes.)

In `CloudImportSyncState.apply(status:)`, replace the two `status = ...` assignments so the map survives:

```swift
        guard let current = status else {
            status = incoming
            return
        }
        guard incoming.state.rank >= current.state.rank else { return }

        // The newer map, by how much of it has settled — and never nil over something: a
        // poll that answered before the map started must not take the skeletons down.
        let map = (incoming.map?.done ?? -1) >= (current.map?.done ?? -1) ? incoming.map : current.map
        status = CloudImportStatus(
            importID: incoming.importID,
            state: incoming.state,
            fastPass: CloudImportProgress(
                done: max(current.fastPass.done, incoming.fastPass.done),
                total: max(current.fastPass.total, incoming.fastPass.total)),
            unavailable: max(current.unavailable, incoming.unavailable),
            partialFailures: max(current.partialFailures, incoming.partialFailures),
            estimatedCostUSD: max(current.estimatedCostUSD, incoming.estimatedCostUSD),
            updatedAt: max(current.updatedAt, incoming.updatedAt),
            map: map ?? current.map
        )
```

In `CloudImportResultUpserter.apply`, inside the `for result in results` loop, after the `if !result.unavailable, result.errorCode == nil { ... }` block and before `video.unavailable = result.unavailable`:

```swift
            // A row that only ever held a guess and turns out to be gone must not keep a
            // category it was guessed into — it would sit on a shelf as a dead save.
            if result.unavailable, video.isGuessed { video.categoryRaw = "" }
```

And add to the enum:

```swift
    /// Writes Clef's first guesses into rows that have nothing yet: no analysis (revision 0)
    /// and no category. Returns how many changed. The fast pass overwrites these through
    /// `apply` — every result carries a revision above 0 and a title, and a title is what
    /// turns a guess into a save (`Video.isGuessed`).
    public static func applyGuesses(_ guesses: [String: Category], to context: ModelContext) throws -> Int {
        guard !guesses.isEmpty else { return 0 }
        let ids = Array(guesses.keys)
        let videos = try context.fetch(FetchDescriptor<Video>(
            predicate: #Predicate { ids.contains($0.videoID) }))
        var changed = 0
        for video in videos where video.cloudAnalysisRevision == 0 && video.categoryRaw.isEmpty {
            guard let category = guesses[video.videoID] else { continue }
            video.categoryRaw = category.rawValue
            changed += 1
        }
        if changed > 0 { try context.save() }
        return changed
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd TikTokBrainKit && swift test`
Expected: both summary lines green, four new tests passing.

- [ ] **Step 5: Commit**

```bash
git add TikTokBrainKit/Sources/TikTokBrainKit/CloudImport.swift TikTokBrainKit/Sources/TikTokBrainKit/Core/Entities.swift TikTokBrainKit/Tests/TikTokBrainKitTests/CloudImportTests.swift
git commit -m "feat(kit): decode the import map and write Clef's guesses into empty rows"
```

---

### Task 5: `PipelineCenter` — guesses, expected counts, map shares

**Files:**
- Modify: `App/Sources/PipelineCenter.swift` (new state + `syncLibraryImport` hook + `apply` hook + self-test)
- Modify: `App/Sources/TikTokBrainApp.swift:48` (register the self-test)
- Modify: `App/Sources/LibraryView.swift:356-380` (`SaveIntent.deskSymbol`)

**Interfaces:**
- Consumes: `CloudImportResultUpserter.applyGuesses`, `cloudState`, `cloudStatus`, `SaveIntent.classify`.
- Produces: `PipelineCenter.expected(_ category: Category) -> Int`, `expected(_ intent: SaveIntent, includeBuy: Bool) -> Int`, `mapShares: [(category: Category, count: Int)]`, `isShapingLibrary: Bool`, `static func expected(count:done:total:landed:) -> Int`, `static func expectedSelfTest() -> Bool`; `SaveIntent.deskSymbol: String`.

- [ ] **Step 1: Write the failing self-test**

In `PipelineCenter.swift`, next to `shellStatusSelfTest`:

```swift
    #if DEBUG
    /// The skeleton arithmetic, checked at launch like the pill's: it is a ratio of three
    /// numbers from two different sources and a clamp, none of it visible from any one screen.
    static func expectedSelfTest() -> Bool {
        expected(count: 30, done: 50, total: 1000, landed: 100) == 500
            && expected(count: 20, done: 50, total: 1000, landed: 450) == 0        // clamped
            && expected(count: 0, done: 50, total: 1000, landed: 0) == 0
            && expected(count: 30, done: 0, total: 1000, landed: 0) == 0           // nothing settled yet
            && expected(count: 30, done: 50, total: 0, landed: 0) == 0             // nothing to scale to
            && expected(count: 1, done: 3, total: 10, landed: 0) == 3              // rounds, not truncates
    }
    #endif
```

Register it in `TikTokBrainApp.init` after the `shellStatusSelfTest` line:

```swift
        assert(PipelineCenter.expectedSelfTest(), "PipelineCenter expected self-test failed")
```

- [ ] **Step 2: Build to verify it fails**

Run: `cd App && xcodegen generate && xcodebuild -project Stash.xcodeproj -scheme Stash -destination 'generic/platform=iOS Simulator' build 2>&1 | grep -E "error:|BUILD" | head`
Expected: `error: type 'PipelineCenter' has no member 'expected'`.

- [ ] **Step 3: Add the state and the arithmetic**

In `PipelineCenter.swift`, after `var cloudStatus: CloudImportStatus?` (line 47):

```swift
    /// How many rows the library holds per category, split by whether an analysis has
    /// written them (`analysed`) or only Clef has (`guessed`, see `Video.isGuessed`). Refreshed after
    /// every batch of results or guesses on the poll's own context, so the views that draw
    /// skeletons read a dictionary instead of fetching the library per body.
    struct CategoryTally: Equatable { var analysed = 0; var guessed = 0 }
    private(set) var tallies: [Category: CategoryTally] = [:]
```

Add these members (a `// MARK: - Library map` section, after `dismissShellStatus`):

```swift
    // MARK: - Library map

    /// True while an import is running and its map has at least one answer — the window in
    /// which skeletons and the picker exist.
    var isShapingLibrary: Bool {
        guard let status = cloudStatus, status.state == .accepted || status.state == .fastPass,
              let map = status.map else { return false }
        return map.done > 0
    }

    /// The map's counts scaled to the import's total, largest first: what the picker's chips
    /// and the Import hero's bar show.
    var mapShares: [(category: Category, count: Int)] {
        guard isShapingLibrary, let status = cloudStatus, let map = status.map else { return [] }
        return map.counts
            .map { (category: $0.key, count: Self.scaled(count: $0.value, done: map.done, total: status.fastPass.total)) }
            .filter { $0.count > 0 }
            .sorted { ($0.count, $1.category.rawValue) > ($1.count, $0.category.rawValue) }
    }

    /// Skeleton rows still owed to `category`: the sample's share scaled to the import, minus
    /// every row already carrying that category (analysed or guessed). Zero outside an import.
    func expected(_ category: Category) -> Int {
        guard isShapingLibrary, let status = cloudStatus, let map = status.map else { return 0 }
        #if DEBUG
        if let forced = Self.debugSorting { return forced }
        #endif
        let tally = tallies[category] ?? CategoryTally()
        return Self.expected(count: map.counts[category] ?? 0, done: map.done,
                             total: status.fastPass.total, landed: tally.analysed + tally.guessed)
    }

    /// The same, per desk shelf: every category whose saves file under `intent` when nothing
    /// but the category is known — which is all a guessed row has.
    func expected(_ intent: SaveIntent, includeBuy: Bool) -> Int {
        librarySegments
            .filter { SaveIntent.classify(category: $0, topics: [], hasBuys: false, includeBuy: includeBuy) == intent }
            .reduce(0) { $0 + expected($1) }
    }

    static func scaled(count: Int, done: Int, total: Int) -> Int {
        guard done > 0, total > 0 else { return 0 }
        return Int((Double(count) / Double(done) * Double(total)).rounded())
    }

    static func expected(count: Int, done: Int, total: Int, landed: Int) -> Int {
        max(0, scaled(count: count, done: done, total: total) - landed)
    }

    #if DEBUG
    /// `-debugSorting 12` draws twelve skeletons under every category, with no import running
    /// — the only way to screenshot a shelf mid-sort from a seeded simulator.
    static let debugSorting: Int? = UserDefaults.standard.string(forKey: "debugSorting").flatMap(Int.init)
    #endif

    /// Recount the library by category on a detached context, then publish.
    private func refreshTallies() {
        guard let container else { return }
        Task.detached(priority: .utility) { [weak self] in
            let context = ModelContext(container)
            guard let videos = try? context.fetch(FetchDescriptor<Video>()) else { return }
            var tallies: [Category: CategoryTally] = [:]
            for video in videos where !video.unavailable {
                guard let category = Category(rawValue: video.categoryRaw) else { continue }
                if video.isGuessed { tallies[category, default: CategoryTally()].guessed += 1 }
                else { tallies[category, default: CategoryTally()].analysed += 1 }
            }
            await MainActor.run { self?.tallies = tallies }
        }
    }

    private static func applyGuesses(_ guesses: [String: Category], to container: ModelContainer) async throws -> Int {
        try await Task.detached(priority: .utility) {
            try CloudImportResultUpserter.applyGuesses(guesses, to: ModelContext(container))
        }.value
    }
```

`isShapingLibrary` with `debugSorting`: when the flag is set, make `isShapingLibrary` return `true` too, so screenshots work with no import:

```swift
    var isShapingLibrary: Bool {
        #if DEBUG
        if Self.debugSorting != nil { return true }
        #endif
        guard let status = cloudStatus, ...
```

In `syncLibraryImport`, after `cloudState.apply(status: status)` / `persistCloudState()` and before the results loop:

```swift
            if let guesses = status.map?.guesses, !guesses.isEmpty, let container,
               try await Self.applyGuesses(guesses, to: container) > 0 {
                refreshTallies()
            }
```

In the same function's results loop, after `if applied > 0 {` add `refreshTallies()` as the first line of that block. Also call `refreshTallies()` at the end of `configure(container:)` so a cold launch mid-import has counts.

In `LibraryView.swift`, inside the `extension SaveIntent` that defines `deskTitle` (line ~356), add:

```swift
    /// The skeleton's glyph while a shelf is still being sorted: the desk's verb, not a category.
    var deskSymbol: String {
        switch self {
        case .watch: "play.rectangle"
        case .tryIt: "checklist"
        case .buy: "bag"
        case .mood: "photo.on.rectangle"
        case .reference: "bookmark"
        }
    }
```

- [ ] **Step 4: Build and run the self-test**

Run: `cd App && xcodebuild -project Stash.xcodeproj -scheme Stash -destination 'generic/platform=iOS Simulator' build 2>&1 | grep -E "error:|BUILD" | head`
Expected: `** BUILD SUCCEEDED **`. (The assert runs at launch; Task 10's simulator run exercises it.)

- [ ] **Step 5: Commit**

```bash
git add App/Sources/PipelineCenter.swift App/Sources/TikTokBrainApp.swift App/Sources/LibraryView.swift
git commit -m "feat(pipeline): apply Clef guesses and scale the map to skeleton counts per category and desk"
```

---

### Task 6: Any category can be a tab — `StashTab` cases and `CategoryView`

**Files:**
- Modify: `App/Sources/TikTokBrainApp.swift:82-140` (`StashTab`), `:200-245` (`TabSlots.selfTest`), `:404-414` (`tabShell` switch)
- Modify: `App/Sources/LibraryView.swift:490` (`LibraryRow` → internal)
- Create: `App/Sources/CategoryView.swift`

**Interfaces:**
- Consumes: `Category.displayName/color/symbol`, `librarySegments`, `StashScrollView`, `StashHeader`, `monthRuns`, `TimeRail`, `LibraryRow`, `PipelineCenter.expected(_:)`.
- Produces: `StashTab` cases `fitness, style, travel, home, learning, comedy, dining, wellness`; `StashTab.tab(owning: Category) -> StashTab?`; `CategoryView(tab: StashTab)`; `SkeletonShelf` is consumed here but defined in Task 7 — add the `SkeletonShelf(...)` line in Task 7, not here.

- [ ] **Step 1: Extend the self-test (fails first)**

In `TabSlots.selfTest`, before the final `decode(encode(...))` line, add:

```swift
            && librarySegments.filter { $0 != .other }.allSatisfy { StashTab.tab(owning: $0) != nil }
            && StashTab.tab(owning: .other) == nil
            && StashTab.tab(owning: .recipe) == .cook && StashTab.tab(owning: .home) == .home
            && decode("home,style") == [.style, .home, .library]                   // catalogue order
            && decode("today,code,cook,music,films,haul,home,style,wellness")       // nine asked for
                == [.music, .films, .haul, .style, .home, .wellness, .library]        // seven kept, Library pinned
```

- [ ] **Step 2: Build to verify it fails**

Run: `cd App && xcodebuild -project Stash.xcodeproj -scheme Stash -destination 'generic/platform=iOS Simulator' build 2>&1 | grep -E "error:|BUILD" | head`
Expected: `error: type 'StashTab' has no member 'tab'`.

- [ ] **Step 3: Grow `StashTab`**

In `TikTokBrainApp.swift`, change the case list to:

```swift
enum StashTab: String, CaseIterable, Identifiable {
    // The four rich sections first, then every plain category in `librarySegments` order,
    // Library last. The order is the pill's and the Settings list's.
    case today, code, cook, music, films, haul
    case fitness, style, travel, home, learning, comedy, dining, wellness
    case library
```

Extend each switch:

```swift
    var label: String {
        switch self {
        case .today: "Lately"
        case .code: "Code"
        case .cook: "Cook"
        case .music: "Music"
        case .films: "Films"
        case .haul: "Haul"
        case .fitness: "Fitness"
        case .style: "Style"
        case .travel: "Travel"
        case .home: "Home"
        case .learning: "Learning"
        case .comedy: "Comedy"
        case .dining: "Dining"
        case .wellness: "Wellness"
        case .library: "Library"
        }
    }

    var symbol: String {
        switch self {
        case .today: "point.3.connected.trianglepath.dotted"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .cook: "fork.knife"
        case .music: "music.note"
        case .films: "movieclapper"
        case .haul: "bag.fill"
        case .library: "square.grid.2x2.fill"
        case .fitness, .style, .travel, .home, .learning, .comedy, .dining, .wellness:
            ownedCategory!.symbol
        }
    }

    var blurb: String {
        switch self {
        case .today: "A few connections in your saves."
        case .code: "Coding saves, links first."
        case .cook: "Recipes as a photo wall."
        case .music: "Records and recommendation lists."
        case .films: "Every film your saves named, as a poster wall."
        case .haul: "Everything your saves are selling."
        case .fitness: "Workouts and training saves."
        case .style: "Outfits, beauty and hair."
        case .travel: "Places and trips."
        case .home: "Decor, cleaning and DIY."
        case .learning: "Facts, how-tos and explainers."
        case .comedy: "The ones that made you laugh."
        case .dining: "Restaurants, cafés and bars."
        case .wellness: "Health, sleep and habits."
        case .library: "Every shelf, plus Import and Settings."
        }
    }

    var ownedCategory: Category? {
        switch self {
        case .cook: .recipe
        case .music: .music
        case .code: .coding
        case .films: .film
        case .fitness: .fitness
        case .style: .style
        case .travel: .travel
        case .home: .home
        case .learning: .learning
        case .comedy: .comedy
        case .dining: .dining
        case .wellness: .wellness
        case .today, .haul, .library: nil
        }
    }

    /// The tab that shows `category`, rich or plain; nil for `other`, which has no tab.
    static func tab(owning category: Category) -> StashTab? {
        allCases.first { $0.ownedCategory == category }
    }
```

In `RootView.tabShell`, extend the switch:

```swift
                case .haul: HaulView()
                case .fitness, .style, .travel, .home, .learning, .comedy, .dining, .wellness:
                    CategoryView(tab: tab)
                case .library: ...
```

In `LibraryView.swift`, change `private struct LibraryRow: View {` to `struct LibraryRow: View {`.

- [ ] **Step 4: Create `CategoryView.swift`**

```swift
// CategoryView.swift
//
// The plain section: one category's saves as dated rows, for every category without a
// screen of its own (Cook, Music, Code and Films keep theirs). Any of these can hold a slot
// on the pill — chosen in Settings, or by the focus picker after the first import — and
// Library hands the category over while the tab is on (`libraryShelves(visible:)`).
//
// While an import is sorting, the rows that have not landed yet are drawn as skeletons in
// the category's tint: as many as the map expects, minus what is already here.

import SwiftUI
import SwiftData
import TikTokBrainKit

struct CategoryView: View {
    let tab: StashTab

    @Query(sort: \Video.bookmarkedAt, order: .reverse) private var videos: [Video]
    private var center = PipelineCenter.shared

    init(tab: StashTab) { self.tab = tab }

    private var category: Category { tab.ownedCategory ?? .other }

    /// Rows an analysis has written. A guessed row is a skeleton, not a row: it has no title,
    /// no thumbnail and no summary to show.
    private var analysed: [Video] {
        videos.filter { $0.category == category && !$0.isGuessed && !$0.needsLook }
    }

    private var guessed: Int {
        videos.filter { $0.category == category && $0.isGuessed && !$0.unavailable }.count
    }

    private var sorting: Int { guessed + center.expected(category) }

    private var runs: [MonthRun<Video>] { monthRuns(analysed) { $0.bookmarkedAt } }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                StashScrollView(tab: tab) {
                    VStack(alignment: .leading, spacing: 0) {
                        StashHeader(title: category.displayName, trailing: "\(analysed.count) saves")
                            .padding(.top, 8)
                        if analysed.isEmpty && sorting == 0 {
                            emptyState.padding(.top, 48)
                        } else {
                            list.padding(.top, 4)
                        }
                        // Task 7 adds: SkeletonShelf(count: sorting, tint: category.color, symbol: category.symbol)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, stashTabBarClearance)
                }
                .background(Color.stashBackground.ignoresSafeArea())
                .toolbar(.hidden, for: .navigationBar)
                .overlay(alignment: .trailing) {
                    let entries = timeRailEntries(for: runs)
                    if entries.count >= 2 {
                        TimeRail(entries: entries, proxy: proxy)
                    }
                }
            }
        }
    }

    private var list: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(runs) { run in
                Micro(text: run.title, size: 10, tracking: 2.2, color: .stashInk.opacity(0.62))
                    .padding(.top, 14)
                    .padding(.bottom, 4)
                    .id(run.id)
                ForEach(run.items, id: \.videoID) { video in
                    NavigationLink { VideoDetailView(video: video) } label: {
                        LibraryRow(video: video, tint: category.color)
                    }
                    .buttonStyle(.plain)
                    Divider().overlay(Color.stashInk.opacity(0.12))
                }
            }
        }
    }

    private var emptyState: some View {
        Text("Nothing filed under \(category.displayName.lowercased()) yet.")
            .font(.archivo(14, .semibold))
            .foregroundStyle(Color.stashInk.opacity(0.55))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
```

- [ ] **Step 5: Regenerate, build, confirm the self-test compiles**

Run: `cd App && xcodegen generate && xcodebuild -project Stash.xcodeproj -scheme Stash -destination 'generic/platform=iOS Simulator' build 2>&1 | grep -E "error:|BUILD" | head`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add App/Sources/TikTokBrainApp.swift App/Sources/LibraryView.swift App/Sources/CategoryView.swift
git commit -m "feat(shell): every category can hold a tab slot, shown by one plain CategoryView"
```

---

### Task 7: Skeletons and the map bar

**Files:**
- Modify: `App/Sources/Theme.swift` (append `SkeletonRow`, `SkeletonShelf`, `MapBar`)
- Modify: `App/Sources/CategoryView.swift` (the `SkeletonShelf` line)
- Modify: `App/Sources/LibraryView.swift:88-98` (`desked`), `:186-193` (shelf list), shelf builders

**Interfaces:**
- Consumes: `PipelineCenter.expected(_:)`, `expected(_:includeBuy:)`, `SaveIntent.deskTint/deskTitle/deskSymbol`.
- Produces: `SkeletonRow(tint: Color, symbol: String)`, `SkeletonShelf(count: Int, tint: Color, symbol: String)` with `static let visible = 5`, `MapBar(shares: [(category: Category, count: Int)], ink: Color = .stashInk.opacity(0.62))`.

- [ ] **Step 1: Add the three views to `Theme.swift`**

Append at the end of the file:

```swift
// MARK: - Sorting skeletons

/// A save that is on its way: the category's tint where the thumbnail and two lines will be,
/// a light sweep across every 1.4 s, and the category's symbol breathing in the square. Under
/// Reduce Motion it is a still, tinted placeholder.
struct SkeletonRow: View {
    let tint: Color
    let symbol: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep = false
    @State private var breathe = false

    var body: some View {
        HStack(spacing: 11) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(tint.opacity(0.12))
                .frame(width: 52, height: 52)
                .overlay {
                    Image(systemName: symbol)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(tint.opacity(reduceMotion ? 0.5 : (breathe ? 0.7 : 0.35)))
                }
            VStack(alignment: .leading, spacing: 8) {
                Capsule().fill(tint.opacity(0.12)).frame(width: 180, height: 12)
                Capsule().fill(tint.opacity(0.12)).frame(width: 110, height: 9)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 68)
        .overlay {
            if !reduceMotion {
                GeometryReader { geo in
                    LinearGradient(colors: [.clear, tint.opacity(0.10), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width * 0.5)
                        .offset(x: sweep ? geo.size.width : -geo.size.width * 0.5)
                }
                .allowsHitTesting(false)
            }
        }
        .clipped()
        .accessibilityLabel("Sorting a save")
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { sweep = true }
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { breathe = true }
        }
    }
}

/// Up to five skeleton rows and a count of the rest — the same cap every shelf has, because
/// building hundreds of animated placeholders is what made Library slow the first time.
struct SkeletonShelf: View {
    let count: Int
    let tint: Color
    let symbol: String

    static let visible = 5

    var body: some View {
        if count > 0 {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(0..<min(count, Self.visible), id: \.self) { _ in
                    SkeletonRow(tint: tint, symbol: symbol)
                    Divider().overlay(Color.stashInk.opacity(0.12))
                }
                if count > Self.visible {
                    Micro(text: "+\(count - Self.visible) more sorting", size: 9.5, tracking: 1.2, color: tint)
                        .padding(.top, 8)
                }
            }
            .transition(.opacity)
        }
    }
}

/// The library's shape as one bar: a tinted segment per category, proportional to its share,
/// and the four largest named under it. `ink` is the legend's colour — cream on the Import
/// hero's green card, ink everywhere else.
struct MapBar: View {
    let shares: [(category: Category, count: Int)]
    var ink: Color = .stashInk.opacity(0.62)

    var body: some View {
        let total = max(1, shares.reduce(0) { $0 + $1.count })
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                let gaps = CGFloat(max(0, shares.count - 1)) * 2
                HStack(spacing: 2) {
                    ForEach(shares, id: \.category) { share in
                        Capsule()
                            .fill(share.category.color)
                            .frame(width: max(3, (geo.size.width - gaps) * CGFloat(share.count) / CGFloat(total)))
                    }
                }
            }
            .frame(height: 6)
            Micro(text: shares.prefix(4).map { "\($0.category.displayName) ~\($0.count)" }.joined(separator: " · "),
                  size: 9.5, tracking: 1, color: ink)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(shares.prefix(4).map { "\($0.category.displayName), about \($0.count)" }.joined(separator: ", "))
    }
}
```

- [ ] **Step 2: Put the shelf under `CategoryView`**

In `CategoryView.swift`, replace the `// Task 7 adds:` comment line with:

```swift
                        SkeletonShelf(count: sorting, tint: category.color, symbol: category.symbol)
                            .padding(.top, analysed.isEmpty ? 8 : 0)
```

- [ ] **Step 3: Library desks**

In `LibraryView.swift`:

1. `desked` (line ~88): change the loop guard so guessed rows are not desked as rows:

```swift
        for video in videos where !video.needsLook && !video.isGuessed {
```

2. Add next to `desked`:

```swift
    /// Guessed rows per desk: a category and nothing else, which is exactly what
    /// `SaveIntent.classify` files on when topics are empty. Drawn as skeletons, never as rows.
    private var guessedByIntent: [SaveIntent: Int] {
        let scope = Set(shelves)
        var out: [SaveIntent: Int] = [:]
        for video in videos where video.isGuessed && !video.unavailable {
            guard let category = video.category, scope.contains(category) else { continue }
            let intent = SaveIntent.classify(category: category, topics: [], hasBuys: false,
                                             includeBuy: includeBuyShelf)
            out[intent, default: 0] += 1
        }
        return out
    }

    /// Skeleton rows owed to a desk: guessed rows already here, plus what the map still expects.
    private func sorting(_ intent: SaveIntent) -> Int {
        (guessedByIntent[intent] ?? 0) + center.expected(intent, includeBuy: includeBuyShelf)
    }

    private func sortingShelf(_ intent: SaveIntent) -> some View {
        SkeletonShelf(count: sorting(intent), tint: intent.deskTint, symbol: intent.deskSymbol)
    }
```

3. In the shelf list (lines ~186–193), draw a sorting shelf under every desk, and a bare one for a desk that has no rows yet:

```swift
        if let watch = desked[.watch] { watchShelf(watch) } else if sorting(.watch) > 0 { sortingHeader(.watch) }
        sortingShelf(.watch)
        if let doable = desked[.tryIt] { rowShelf(.tryIt, doable, badge: "try it") } else if sorting(.tryIt) > 0 { sortingHeader(.tryIt) }
        sortingShelf(.tryIt)
        if !buyPicks.isEmpty { buyShelf(buyPicks) }
        if let mood = desked[.mood] { moodShelf(mood) } else if sorting(.mood) > 0 { sortingHeader(.mood) }
        sortingShelf(.mood)
        if let reference = desked[.reference] { rowShelf(.reference, reference) } else if sorting(.reference) > 0 { sortingHeader(.reference) }
        sortingShelf(.reference)
```

(`.buy` gets no skeletons: a buy is a pick inside a save, and the map does not know about picks.)

4. Add the bare header:

```swift
    /// A desk with nothing landed yet, named so the skeletons under it read as a shelf.
    private func sortingHeader(_ intent: SaveIntent) -> some View {
        Micro(text: "\(intent.deskTitle) · sorting", size: 10, tracking: 2, color: intent.deskTint)
            .frame(height: 44)
            .padding(.top, 16)
    }
```

- [ ] **Step 4: Build**

Run: `cd App && xcodebuild -project Stash.xcodeproj -scheme Stash -destination 'generic/platform=iOS Simulator' build 2>&1 | grep -E "error:|BUILD" | head`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add App/Sources/Theme.swift App/Sources/CategoryView.swift App/Sources/LibraryView.swift
git commit -m "feat(library): tinted skeleton rows and a map bar while an import sorts"
```

---

### Task 8: The focus picker

**Files:**
- Create: `App/Sources/FocusPickerView.swift`
- Modify: `App/Sources/TikTokBrainApp.swift` (`RootView`: state, sheet, trigger; register self-test)

**Interfaces:**
- Consumes: `PipelineCenter.mapShares`, `isShapingLibrary`, `importRouteRequested`; `TabSlots.encode`, `StashTab.tab(owning:)`; `MapBar`, `TopicChip`, `StashPrimaryButton`, `Micro`.
- Produces: `FocusPickerView(shares:onDone:)`, `FocusPickerView.maxPicks = 3`, `static func slots(for picks: [Category]) -> [StashTab]`, `static func offered(_ shares: [(category: Category, count: Int)]) -> [(category: Category, count: Int)]`, `static func shouldShow(map: CloudImportMap?, shaping: Bool, picked: Bool) -> Bool`, `static func selfTest() -> Bool`.

- [ ] **Step 1: Write the self-test (fails first)**

Register in `TikTokBrainApp.init`:

```swift
        assert(FocusPickerView.selfTest(), "FocusPickerView self-test failed")
```

- [ ] **Step 2: Build to verify it fails**

Run: `cd App && xcodebuild -project Stash.xcodeproj -scheme Stash -destination 'generic/platform=iOS Simulator' build 2>&1 | grep -E "error:|BUILD" | head`
Expected: `error: cannot find 'FocusPickerView' in scope`.

- [ ] **Step 3: Create `FocusPickerView.swift`**

```swift
// FocusPickerView.swift
//
// Shown once per account, the first time an import's map has settled: the library's shape as
// a bar, and the biggest categories as chips. Up to three picks become tabs on the pill —
// three keeps every slot labelled (TabSlots: past five, labels go) — and the rest stay as
// Library shelves. Skipping is a choice too; the sheet never comes back on its own, and
// Settings keeps the full picker.

import SwiftUI
import TikTokBrainKit

struct FocusPickerView: View {
    let shares: [(category: Category, count: Int)]
    /// Called with the picks on "Set up my bar", with [] on Skip. The presenter marks the
    /// account either way.
    let onDone: ([Category]) -> Void

    @State private var picks: [Category] = []
    @State private var refused = false

    static let maxPicks = 3
    static let maxOffered = 6

    var body: some View {
        VStack(alignment: .leading, spacing: StashSpacing.group) {
            Micro(text: "YOUR LIBRARY", size: 11, tracking: 3.4, color: .stashInk)
                .padding(.top, 28)
            MapBar(shares: shares)
            Text("What do you want to find fast?")
                .font(.archivo(28, .heavy))
                .foregroundStyle(Color.stashInk)
            Text("Pick up to three. Each gets its own tab; everything else stays in Library.")
                .font(.archivo(14, .semibold))
                .foregroundStyle(Color.stashInk.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                ForEach(Self.offered(shares), id: \.category) { share in
                    TopicChip(label: share.category.displayName, count: share.count, symbol: share.category.symbol,
                              unit: "saves", isOn: picks.contains(share.category)) {
                        toggle(share.category)
                    }
                }
            }
            if refused {
                Micro(text: "Three keeps every tab labelled; add more in Settings", size: 9.5, tracking: 1.2,
                      color: .categoryOther)
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
            StashPrimaryButton(title: "Set up my bar") { onDone(picks) }
                .disabled(picks.isEmpty)
                .opacity(picks.isEmpty ? 0.5 : 1)
            Button { onDone([]) } label: {
                Micro(text: "Skip", size: 11, tracking: 1.7, color: .stashInk.opacity(0.55))
                    .frame(maxWidth: .infinity)
                    .minTapTarget()
            }
            .buttonStyle(.plain)
            .padding(.bottom, 12)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.stashBackground.ignoresSafeArea())
        .animation(.easeOut(duration: 0.2), value: refused)
    }

    private func toggle(_ category: Category) {
        if let index = picks.firstIndex(of: category) {
            picks.remove(at: index)
            refused = false
        } else if picks.count < Self.maxPicks {
            picks.append(category)
            refused = false
        } else {
            refused = true
        }
    }

    // MARK: - Rules, as values

    /// The chips: the largest categories, never `other` (it has no tab), at most six.
    static func offered(_ shares: [(category: Category, count: Int)]) -> [(category: Category, count: Int)] {
        Array(shares.filter { $0.category != .other }.prefix(maxOffered))
    }

    /// The pill after a choice: Lately, the picks' tabs, Library. `TabSlots.encode` puts them
    /// in catalogue order whatever order they were tapped in.
    static func slots(for picks: [Category]) -> [StashTab] {
        [.today] + picks.prefix(maxPicks).compactMap(StashTab.tab(owning:)) + [.library]
    }

    /// Whether to present: not yet answered for this account, an import is shaping the library,
    /// and the map has settled enough to mean something — twenty answers, or all of a small
    /// import — with at least one category worth offering.
    static func shouldShow(map: CloudImportMap?, shaping: Bool, picked: Bool) -> Bool {
        guard !picked, shaping, let map else { return false }
        guard map.done >= min(20, map.sampled) else { return false }
        return map.counts.contains { $0.key != .other && $0.value > 0 }
    }

    #if DEBUG
    static func selfTest() -> Bool {
        let shares: [(category: Category, count: Int)] = [(.coding, 230), (.recipe, 180), (.music, 90), (.other, 60),
                                                           (.home, 40), (.style, 20), (.film, 10), (.travel, 5)]
        let small = CloudImportMap(sampled: 3, done: 3, counts: [.coding: 3])
        let settling = CloudImportMap(sampled: 60, done: 19, counts: [.coding: 19])
        let settled = CloudImportMap(sampled: 60, done: 20, counts: [.coding: 20])
        let allOther = CloudImportMap(sampled: 60, done: 60, counts: [.other: 60])
        return offered(shares).map(\.category) == [.coding, .recipe, .music, .home, .style, .film]
            && TabSlots.encode(slots(for: [.coding, .home, .recipe])) == "today,code,cook,home,library"
            && slots(for: [.other]) == [.today, .library]
            && slots(for: [.coding, .home, .recipe, .music]).count == 5                   // a fourth pick is dropped
            && shouldShow(map: small, shaping: true, picked: false)
            && !shouldShow(map: settling, shaping: true, picked: false)
            && shouldShow(map: settled, shaping: true, picked: false)
            && !shouldShow(map: settled, shaping: true, picked: true)
            && !shouldShow(map: settled, shaping: false, picked: false)
            && !shouldShow(map: allOther, shaping: true, picked: false)
            && !shouldShow(map: nil, shaping: true, picked: false)
    }
    #endif
}
```

- [ ] **Step 4: Present it from `RootView`**

In `RootView`, add state next to `welcomeDismissed`:

```swift
    /// The focus picker, once per account. The key is set on every way out — picked, skipped
    /// or swiped away — so it is seen once and Settings is where tabs change after that.
    @State private var focusPickerShown = false
    private static func focusKey(_ userID: String) -> String { "focusPicked-\(userID)" }
    private var focusPicked: Bool {
        guard let userID = session.userID else { return true }
        return UserDefaults.standard.bool(forKey: Self.focusKey(userID))
    }
    private func markFocusPicked() {
        if let userID = session.userID { UserDefaults.standard.set(true, forKey: Self.focusKey(userID)) }
    }
    #if DEBUG
    /// `-showFocusPicker` presents the sheet over a seeded library with sample shares — the
    /// only way to screenshot it without an import.
    private static var forcesFocusPicker: Bool { CommandLine.arguments.contains("-showFocusPicker") }
    private static let sampleShares: [(category: Category, count: Int)] =
        [(.coding, 230), (.recipe, 180), (.music, 90), (.home, 60), (.film, 40), (.style, 25)]
    #endif
```

On `tabShell`'s outer `ZStack`, after `.onChange(of: slotsRaw)`:

```swift
        .onChange(of: center.cloudStatus?.map?.done, initial: true) { _, _ in
            guard !focusPickerShown, !center.importRouteRequested, !session.isDemoAccount else { return }
            if FocusPickerView.shouldShow(map: center.cloudStatus?.map, shaping: center.isShapingLibrary,
                                          picked: focusPicked) {
                focusPickerShown = true
            }
            #if DEBUG
            if Self.forcesFocusPicker { focusPickerShown = true }
            #endif
        }
        .sheet(isPresented: $focusPickerShown, onDismiss: markFocusPicked) {
            #if DEBUG
            let shares = Self.forcesFocusPicker ? Self.sampleShares : center.mapShares
            #else
            let shares = center.mapShares
            #endif
            FocusPickerView(shares: shares) { picks in
                if !picks.isEmpty { slotsRaw = TabSlots.encode(FocusPickerView.slots(for: picks)) }
                focusPickerShown = false
            }
            .presentationDetents([.large])
        }
```

- [ ] **Step 5: Regenerate, build**

Run: `cd App && xcodegen generate && xcodebuild -project Stash.xcodeproj -scheme Stash -destination 'generic/platform=iOS Simulator' build 2>&1 | grep -E "error:|BUILD" | head`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add App/Sources/FocusPickerView.swift App/Sources/TikTokBrainApp.swift
git commit -m "feat(onboarding): the focus picker — up to three categories onto the pill after the first import"
```

---

### Task 9: Import hero, provider disclosure, privacy page

**Files:**
- Modify: `App/Sources/ImportView.swift:189-199` (hero bar), `:304-318` (`heroSubtitle`), `:383-392` (disclosure), `:901` (legal line), `:340-362` (self-test)
- Modify: `services/webhook/site/privacy.html:135`, `:141-146`, `:149`

**Interfaces:**
- Consumes: `PipelineCenter.mapShares`, `isShapingLibrary`, `MapBar`.
- Produces: `ImportView.heroSubtitle(_:_:)` reads `cloud.map`.

- [ ] **Step 1: Extend the hero self-test (fails first)**

In `ImportView.selfTest`, after the `hero(...)` checks, add (keeping the `box` helper; give it a trailing `map: CloudImportMap? = nil` parameter passed through):

```swift
            && heroSubtitle(.syncing, box(.fastPass, 0, 941, map: CloudImportMap(sampled: 60, done: 12)))
                == "Shaping your library from 60 saves · 12 sorted so far"
            && heroSubtitle(.syncing, box(.fastPass, 412, 941, map: CloudImportMap(sampled: 60, done: 60)))
                == "Sorted 412 of 941 · you can close the app, Stash pings you when it is done"
```

- [ ] **Step 2: Build to verify it fails**

Run: `cd App && xcodebuild -project Stash.xcodeproj -scheme Stash -destination 'generic/platform=iOS Simulator' build 2>&1 | grep -E "error:|BUILD" | head`
Expected: `error: extra argument 'map' in call` (the helper), then the assertion once it compiles.

- [ ] **Step 3: Hero subtitle and bar**

In `heroSubtitle`, replace the `.syncing` case:

```swift
        case .syncing:
            // While the map is still settling the library has no shape yet; say what is being
            // built from, not a count that reads as stalled at 0.
            if let map = cloud.map, map.done < map.sampled {
                return "Shaping your library from \(map.sampled) saves · \(map.done) sorted so far"
            }
            return "Sorted \(cloud.fastPass.done) of \(cloud.fastPass.total) "
                + "· you can close the app, Stash pings you when it is done"
```

In `syncCard`, after the progress-bar `if let progress = localProgress ... { ... .padding(.top, 14) }`:

```swift
            if heroState == .syncing, controller.isShapingLibrary, !controller.mapShares.isEmpty {
                MapBar(shares: controller.mapShares, ink: .stashOnAccent.opacity(0.8))
                    .padding(.top, 12)
            }
```

- [ ] **Step 4: Disclosure copy**

`cloudDisclosure` text becomes:

```swift
            Text("Stash servers download each video you submit. Its audio goes to Groq, Inc. "
                 + "(United States) for speech-to-text; the caption, transcript and on-screen "
                 + "text go to AWS Bedrock (Frankfurt) to write the summary and pick the "
                 + "category. The caption and hashtags also go to Cloudflare's Clef model, "
                 + "through OpenRouter, Inc. (United States), for a first sort while that runs. "
                 + "The downloaded video is deleted straight after, and nothing is used to train "
                 + "models.")
```

Update the comment above it: "The three names match the sub-processors the privacy policy lists".

The Settings legal line becomes:

```swift
            Text("The privacy policy names everything Stash holds and the providers that process it: Groq for speech-to-text, OpenRouter and Cloudflare for the first sort, AWS for hosting and analysis.")
```

- [ ] **Step 5: Privacy page**

In `services/webhook/site/privacy.html`:

Line 135, append to the "Where it is processed" paragraph, before `</p>`:

```html
 While that analysis runs, the caption and hashtags of each imported video also go to Cloudflare's Clef model, through OpenRouter, Inc., for a first category guess that the full analysis then replaces.
```

In the sub-processors `<dl>` after the Groq entry:

```html
        <dt>OpenRouter, Inc.</dt>
        <dd>Routes the caption and hashtags of each imported video to Cloudflare, Inc.'s Clef model for a first category guess. Receives no cover images, transcripts, account identifiers or email. Established in the United States; see international transfers.</dd>
```

In "International transfers", change the first sentence to:

```html
      <p>Groq, Inc. and OpenRouter, Inc. are established in the United States and we send audio to Groq's API and captions to OpenRouter's, so these are transfers outside the EEA under Chapter V GDPR. They are made under the European Commission's Standard Contractual Clauses, together with the fact that the data is transient — it is processed for the length of one request and is not retained by us afterwards.</p>
```

- [ ] **Step 6: Build, then check the page is still valid HTML**

Run: `cd App && xcodebuild -project Stash.xcodeproj -scheme Stash -destination 'generic/platform=iOS Simulator' build 2>&1 | grep -E "error:|BUILD" | head`
Expected: `** BUILD SUCCEEDED **`.

Run: `python3 -c "import html.parser,sys; p=html.parser.HTMLParser(); p.feed(open('services/webhook/site/privacy.html').read()); print('parsed')"`
Expected: `parsed`.

- [ ] **Step 7: Commit**

```bash
git add App/Sources/ImportView.swift services/webhook/site/privacy.html
git commit -m "feat(import): the hero shows the map while it settles; OpenRouter and Cloudflare disclosed"
```

---

### Task 10: Whole-feature verification

**Files:**
- None created. Screenshots go to the session scratchpad.

- [ ] **Step 1: Server, Kit, App suites**

```bash
cd services/webhook && uv run --with-requirements requirements.txt --with pytest --with cryptography python -m pytest -q
cd ../../TikTokBrainKit && swift test 2>&1 | grep -E "Executed|Test run with|error"
cd ../App && xcodegen generate && xcodebuild -project Stash.xcodeproj -scheme Stash -destination 'generic/platform=iOS Simulator' build 2>&1 | grep -E "error:|warning: unre|BUILD"
```

Expected: pytest all pass; both Kit summary lines with 0 failures; `** BUILD SUCCEEDED **`.

- [ ] **Step 2: Simulator run — self-tests, picker, skeletons**

Build for the spare device and launch headlessly (never `open_application`; reboot the device first):

```bash
UD=55BEAA32-9D81-4FE5-AF1F-2A60B51F244E
cd App && xcodebuild -project Stash.xcodeproj -scheme Stash -destination "id=$UD" -derivedDataPath build build 2>&1 | grep -E "error:|BUILD"
xcrun simctl shutdown $UD; xcrun simctl boot $UD; xcrun simctl bootstatus $UD -b
xcrun simctl uninstall $UD dev.dmitryschab.Stash
xcrun simctl install $UD build/Build/Products/Debug-iphonesimulator/Stash.app
S=/private/tmp/claude-501/-Users-dmitryschab-Documents-projects-stash-app/83691862-76b8-4710-9cef-c4a04638a0e7/scratchpad
# 1. Picker over a seeded library (self-tests assert at launch — a crash here is a failed assert).
perl -e 'alarm 30; exec @ARGV' -- xcrun simctl launch $UD dev.dmitryschab.Stash -seedSample -showFocusPicker
sleep 6; xcrun simctl io $UD screenshot $S/picker.png
# 2. A plain category tab with skeletons.
xcrun simctl terminate $UD dev.dmitryschab.Stash
perl -e 'alarm 30; exec @ARGV' -- xcrun simctl launch $UD dev.dmitryschab.Stash -seedSample -tabSlots today,home,style,library -initialTab home -debugSorting 12
sleep 6; xcrun simctl io $UD screenshot $S/category-home.png
# 3. Library desks with sorting shelves.
xcrun simctl terminate $UD dev.dmitryschab.Stash
perl -e 'alarm 30; exec @ARGV' -- xcrun simctl launch $UD dev.dmitryschab.Stash -seedSample -initialTab library -debugSorting 12
sleep 6; xcrun simctl io $UD screenshot $S/library-sorting.png
xcrun simctl terminate $UD dev.dmitryschab.Stash; xcrun simctl shutdown $UD
```

Expected: three PNGs; the app did not crash (`simctl launch` prints a pid each time). Read each screenshot with the Read tool and check: the picker shows the bar, six chips, the primary button; the Home tab shows real rows then five tinted skeleton rows and "+7 more sorting"; Library shows skeletons under its desks.

- [ ] **Step 3: Record the evidence and finish**

Paste the three summary lines (pytest count, both Kit lines, BUILD SUCCEEDED) and the three screenshot paths into the final report. Then invoke `superpowers:finishing-a-development-branch`.
