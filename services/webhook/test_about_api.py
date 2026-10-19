"""The about route: one text per save, the thing search matches against.

What these pin is which words reach the model. Speech leads, with the caption and the earlier
summary beside it for when the "speech" is only a song; music gets no lyrics at all; and a save
with neither is described from its caption, earlier summary and picture. A model that refuses
instead of answering is replaced by the caption, then the summary. The route's shape and its
money (a daily deep-pass unit per item, no quota) are the rest.
"""

import base64
import time
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

import about_api
import api_v1
import stash_auth
from about_api import AboutItem, build_about_prompt
from app import app
from cloud_import_models import INITIAL_LIMIT
from cloud_import_store import DynamoImportStore
from conftest import ConditionalTable


@pytest.fixture
def store():
    subject = DynamoImportStore(table=ConditionalTable(), user_id="user-a")
    app.dependency_overrides[stash_auth.current_user] = lambda: "user-a"
    app.dependency_overrides[stash_auth.entitled_store] = lambda: subject
    yield subject
    app.dependency_overrides.clear()


@pytest.fixture(autouse=True)
def tokens(monkeypatch):
    """No test reaches for AWS or the secrets file: a missing credential would raise inside the
    route and pass every 502 assertion for the wrong reason."""
    monkeypatch.setattr(api_v1, "_bedrock_token", lambda: "test-bedrock-token")
    monkeypatch.setattr(about_api, "openrouter_key", lambda: "test-openrouter-key")


@pytest.fixture
def chat(monkeypatch):
    """Stand in for the one network call, recording what it was handed."""
    calls = []

    def fake(url, model, token, system, content, max_tokens):
        calls.append({"url": url, "model": model, "token": token, "system": system,
                      "content": content, "max_tokens": max_tokens})
        return "  About text.  "

    monkeypatch.setattr(about_api, "_chat", fake)
    return calls


def jpeg(size: int) -> str:
    return base64.b64encode(b"\xff" * size).decode()


# ------------------------------------------------------------------ the route


def test_one_about_per_item_in_order(store, chat, monkeypatch):
    items = [{"videoID": "a", "transcript": "we make carbonara"},
             {"videoID": "b", "caption": "sunset #fyp"}]
    with TestClient(app) as client:
        r = client.post("/v1/about", json={"items": items})
    assert r.status_code == 200 and r.json() == {"abouts": ["About text.", "About text."]}
    assert len(chat) == 2

    # Items are written side by side, so the answers arrive in whatever order the model gets to
    # them. The client reads them by position, so make the first one the slow one.
    def fake(url, model, token, system, content, max_tokens):
        if "carbonara" in content:
            time.sleep(0.2)
            return "slow"
        return "fast"

    monkeypatch.setattr(about_api, "_chat", fake)
    with TestClient(app) as client:
        r = client.post("/v1/about", json={"items": items})
    assert r.json() == {"abouts": ["slow", "fast"]}


def test_image_item_goes_to_vision_model_text_item_to_bedrock(store, chat):
    image = jpeg(64)
    with TestClient(app) as client:
        r = client.post("/v1/about", json={"items": [
            {"videoID": "a", "caption": "a grid of albums", "image": image},
            {"videoID": "b", "transcript": "we make carbonara"}]})
    assert r.status_code == 200

    vision = next(call for call in chat if isinstance(call["content"], list))
    text = next(call for call in chat if isinstance(call["content"], str))
    if about_api.ABOUT_VISION_MODEL == api_v1.BEDROCK_MODEL:
        expected = (api_v1.BEDROCK_URL, api_v1.BEDROCK_MODEL, "test-bedrock-token")
    else:
        expected = (api_v1.OPENROUTER_URL, about_api.ABOUT_VISION_MODEL, "test-openrouter-key")
    assert (vision["url"], vision["model"], vision["token"]) == expected
    assert vision["content"][0]["type"] == "text" and "albums" in vision["content"][0]["text"]
    assert vision["content"][1] == {
        "type": "image_url", "image_url": {"url": "data:image/jpeg;base64," + image}}
    assert (text["url"], text["model"], text["token"]) == (
        api_v1.BEDROCK_URL, api_v1.BEDROCK_MODEL, "test-bedrock-token")
    assert "carbonara" in text["content"]
    for call in chat:
        assert call["system"] == about_api.ABOUT_SYSTEM_PROMPT
        assert call["max_tokens"] == about_api.ABOUT_MAX_TOKENS


def test_refuses_zero_and_too_many_items(store, chat, monkeypatch):
    # Room for exactly one full request, so a refusal that had charged anything would show up as
    # a 429 on the request that follows.
    monkeypatch.setenv("DEEP_PASS_DAILY_CAP", str(about_api.MAX_ITEMS))
    item = {"videoID": "a", "caption": "x"}
    with TestClient(app) as client:
        assert client.post("/v1/about", json={"items": []}).status_code == 422
        too_many = [item] * (about_api.MAX_ITEMS + 1)
        assert client.post("/v1/about", json={"items": too_many}).status_code == 422
        assert chat == []
        r = client.post("/v1/about", json={"items": [item] * about_api.MAX_ITEMS})
    assert r.status_code == 200 and len(r.json()["abouts"]) == about_api.MAX_ITEMS


def test_refuses_oversized_text_and_image(store, chat, monkeypatch):
    monkeypatch.setenv("DEEP_PASS_DAILY_CAP", "2")
    half = about_api.MAX_TEXT_BYTES // 2
    # Bytes, not characters ("я" is two), and all of an item's text together, not field by field.
    at_limit = {"videoID": "a", "transcript": "я" * half}
    over_limit = {"videoID": "a", "transcript": "я" * half, "caption": "x"}
    big_image = {"videoID": "a", "image": jpeg(about_api.MAX_IMAGE_BYTES + 1)}
    with TestClient(app) as client:
        for item in (over_limit, big_image, {"videoID": "a", "image": "not base64!"}):
            assert client.post("/v1/about", json={"items": [item]}).status_code == 422
        assert chat == []
        assert client.post("/v1/about", json={"items": [at_limit]}).status_code == 200
        at_image_limit = {"videoID": "a", "image": jpeg(about_api.MAX_IMAGE_BYTES)}
        assert client.post("/v1/about", json={"items": [at_image_limit]}).status_code == 200
    assert len(chat) == 2


def test_each_item_charges_the_daily_cap(store, chat, monkeypatch):
    monkeypatch.setenv("DEEP_PASS_DAILY_CAP", "1")
    with TestClient(app) as client:
        r = client.post("/v1/about", json={"items": [{"videoID": "a", "caption": "x"},
                                                      {"videoID": "b", "caption": "y"}]})
    assert r.status_code == 429 and r.json()["detail"] == "deep-pass daily cap reached"
    assert 0 < int(r.headers["retry-after"]) <= 86_400
    # Charged before any model call, so a capped request spends nothing on the model.
    assert chat == []


def test_model_failure_is_a_502(store, monkeypatch):
    real_chat = about_api._chat

    def boom(*args):
        raise RuntimeError("model said no")

    monkeypatch.setattr(about_api, "_chat", boom)
    with TestClient(app) as client:
        r = client.post("/v1/about", json={"items": [{"videoID": "a", "caption": "x"}]})
    assert r.status_code == 502 and r.json()["detail"] == "about unavailable"

    # A provider answer that is not a 200 fails the same way, through the real _chat.
    monkeypatch.setattr(about_api, "_chat", real_chat)
    monkeypatch.setattr(about_api.requests, "post",
                        lambda *a, **k: SimpleNamespace(status_code=429))
    with TestClient(app) as client:
        r = client.post("/v1/about", json={"items": [{"videoID": "a", "caption": "x"}]})
    assert r.status_code == 502


def test_an_empty_answer_is_a_502_not_an_empty_about(store, monkeypatch):
    """The app stores whatever comes back as the save's about text and marks it written, so a
    blank one would leave the save unfindable by meaning for good; a 502 lets it retry. A vision
    model that spends its whole token budget thinking answers exactly this way."""
    for blank in ("", "  \n"):
        monkeypatch.setattr(about_api, "_chat", lambda *args, blank=blank: blank)
        with TestClient(app) as client:
            r = client.post("/v1/about", json={"items": [{"videoID": "a", "caption": "x"},
                                                          {"videoID": "b", "caption": "y"}]})
        assert r.status_code == 502 and r.json()["detail"] == "about unavailable"


def test_charges_no_quota(store, chat):
    with TestClient(app) as client:
        r = client.post("/v1/about", json={"items": [{"videoID": "a", "caption": "x"}] * 3})
    assert r.status_code == 200
    assert store.get_quota().initial_remaining == INITIAL_LIMIT


# ------------------------------------------------------------------ the prompt


def test_speech_prompt_carries_caption_and_summary_beside_the_transcript():
    """A "transcript" is often the song playing under the video, and summarizing lyrics describes
    nothing the post is about; the caption and summary are what the model falls back to then."""
    p = build_about_prompt(AboutItem(videoID="a", transcript="we make carbonara",
                                     caption="#fyp so good", summary="A sunset.",
                                     ocrText="SUBSCRIBE"))
    assert "carbonara" in p and "SUBSCRIBE" in p
    assert "so good" in p and "A sunset." in p and "#fyp" not in p
    assert p.index("Transcript:") < p.index("Caption:")
    assert "lyrics" in p.lower() and "background music" in p.lower()


def test_long_transcript_is_truncated():
    p = build_about_prompt(AboutItem(
        videoID="a", transcript="x" * about_api.TRANSCRIPT_CHARS + "TAIL",
        ocrText="y" * about_api.OCR_CHARS + "END"))
    assert "x" * about_api.TRANSCRIPT_CHARS in p and "TAIL" not in p
    assert "y" * about_api.OCR_CHARS in p and "END" not in p


def test_music_never_sends_lyrics():
    p = build_about_prompt(AboutItem(videoID="a", category="music", transcript="la la love you",
                                     music=["Lovesong by The Cure"], caption="late night #vibes",
                                     ocrText="LIVE 1984"))
    assert "la la love" not in p and "genre" in p.lower() and "Lovesong by The Cure" in p
    assert "late night" in p and "#vibes" not in p and "LIVE 1984" in p


def test_silent_prompt_strips_hashtags_and_keeps_summary():
    p = build_about_prompt(AboutItem(videoID="a", caption="Dinner tonight #pasta #fyp",
                                     summary="A plate of pasta."))
    assert "Dinner tonight" in p and "#pasta" not in p and "A plate of pasta." in p


def test_silent_prompt_lets_caption_and_summary_state_the_topic():
    p = build_about_prompt(AboutItem(videoID="a", caption="Day in the life of a private chef",
                                     summary="A private chef cooks for a footballer."))
    assert "visibly there" not in p
    assert "topic" in p.lower() and "Day in the life of a private chef" in p


def test_system_prompt_forbids_asking_for_more():
    system = " ".join(about_api.ABOUT_SYSTEM_PROMPT.lower().split())
    assert "never ask for more material" in system and "never say you cannot" in system


# ------------------------------------------------------------------ refusals


REFUSALS = [
    "Please provide the material or description of the video so I can write the text for you.",
    "I'm sorry, but I cannot see the video.",
    "I\u2019m sorry, there is nothing to describe.",
    "I cannot describe this post.",
    "I can't write anything from this.",
    "I am unable to provide a description because the video content is not visible.",
    "Unfortunately there is not enough here to go on.",
    "There is no material to describe.",
]


@pytest.mark.parametrize("refusal", REFUSALS)
def test_a_refusal_falls_back_to_the_stripped_caption(monkeypatch, refusal):
    monkeypatch.setattr(about_api, "_chat", lambda *args: refusal)
    item = AboutItem(videoID="a", caption="Dinner tonight #pasta #fyp", summary="A plate of pasta.")
    assert about_api.write_about(item) == "Dinner tonight"


def test_a_refusal_with_no_caption_falls_back_to_the_summary(monkeypatch):
    monkeypatch.setattr(about_api, "_chat", lambda *args: REFUSALS[0])
    for caption in ("", "#fyp #viral"):
        item = AboutItem(videoID="a", caption=caption, summary="  A plate of pasta.  ")
        assert about_api.write_about(item) == "A plate of pasta."


def test_a_refusal_with_nothing_to_fall_back_on_is_a_502(store, monkeypatch):
    monkeypatch.setattr(about_api, "_chat", lambda *args: REFUSALS[0])
    with pytest.raises(ValueError):
        about_api.write_about(AboutItem(videoID="a", caption="#fyp", summary=" "))
    with TestClient(app) as client:
        r = client.post("/v1/about", json={"items": [{"videoID": "a", "transcript": "la la"}]})
    assert r.status_code == 502 and r.json()["detail"] == "about unavailable"


def test_an_answer_that_merely_mentions_cannot_is_kept(monkeypatch):
    answer = "A baker explains why you cannot skip proofing. Unfortunately for him, the dough tears."
    monkeypatch.setattr(about_api, "_chat", lambda *args: answer)
    assert about_api.write_about(AboutItem(videoID="a", caption="bread")) == answer
