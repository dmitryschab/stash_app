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
