"""The search route: Haiku picks which of the app's candidates answer a request.

What these pin is the mapping back from Haiku's numbers to the app's ids (in its order, never
an id it did not send, never twice), what the model is asked for, and the money: one unit of a
daily counter of its own, charged after the shape check and before the model.
"""

import json
from types import SimpleNamespace

import anthropic
import httpx
import pytest
from fastapi.testclient import TestClient

import search_api
import stash_auth
from app import app
from cloud_import_store import DynamoImportStore
from conftest import ConditionalTable


@pytest.fixture
def store():
    subject = DynamoImportStore(table=ConditionalTable(), user_id="user-a")
    app.dependency_overrides[stash_auth.current_user] = lambda: "user-a"
    app.dependency_overrides[stash_auth.entitled_store] = lambda: subject
    yield subject
    app.dependency_overrides.clear()


def answer(picks=None, stop_reason="end_turn", text=None):
    """A Messages response the way Haiku 5.5 sends one: a thinking block may come first."""
    body = text if text is not None else json.dumps({"picks": picks})
    return SimpleNamespace(stop_reason=stop_reason, content=[
        SimpleNamespace(type="thinking", thinking=""), SimpleNamespace(type="text", text=body)])


@pytest.fixture
def haiku(monkeypatch):
    """Stand in for the Bedrock client, recording every request and answering with `reply`."""
    calls = type("Calls", (list,), {})()  # a list that can also carry the reply
    state = {"reply": answer([1])}

    def create(**kwargs):
        calls.append(kwargs)
        if isinstance(state["reply"], Exception):
            raise state["reply"]
        return state["reply"]

    monkeypatch.setattr(search_api, "_haiku",
                        lambda: SimpleNamespace(messages=SimpleNamespace(create=create)))
    calls.state = state
    return calls


def refuse(monkeypatch):
    monkeypatch.setattr(search_api, "_haiku",
                        lambda: pytest.fail("the model was called for a refused request"))


CANDIDATES = [{"id": "7400000000000000001", "about": "A creamy mushroom risotto in 20 minutes."},
              {"id": "7400000000000000002", "about": "A leg-day routine at the gym."},
              {"id": "7400000000000000003", "about": "Crispy tofu stir-fry\nwith peppers."}]


def post(json_body):
    with TestClient(app) as client:
        return client.post("/v1/search", json=json_body)


# ------------------------------------------------------------------ the happy path


def test_picks_come_back_as_ids_in_haikus_order(store, haiku):
    haiku.state["reply"] = answer([3, 1])
    r = post({"query": "quick vegetarian dinner", "candidates": CANDIDATES})
    assert r.status_code == 200
    assert r.json() == {"ids": ["7400000000000000003", "7400000000000000001"]}


def test_a_number_that_names_no_candidate_is_dropped_and_a_repeat_counts_once(store, haiku):
    haiku.state["reply"] = answer([2, 0, 4, 2, -1, 1])
    r = post({"query": "gym", "candidates": CANDIDATES})
    assert r.json() == {"ids": ["7400000000000000002", "7400000000000000001"]}


def test_nothing_fits_is_an_empty_answer_not_an_error(store, haiku):
    haiku.state["reply"] = answer([])
    assert post({"query": "car repair", "candidates": CANDIDATES}).json() == {"ids": []}


def test_what_haiku_is_asked(store, haiku):
    post({"query": "  quick vegetarian dinner ", "candidates": CANDIDATES})
    call = haiku[0]
    assert call["model"] == "anthropic.claude-haiku-5-5"
    assert call["system"] == search_api.SEARCH_SYSTEM_PROMPT
    assert call["output_config"]["effort"] == "low"
    assert call["output_config"]["format"]["schema"] == search_api.PICKS_SCHEMA
    # Numbered, one line each (a newline inside an about-text would start a fake entry), and the
    # ids never reach the prompt.
    assert call["messages"] == [{"role": "user", "content": (
        "Request: quick vegetarian dinner\n\nSaved videos:\n"
        "1: A creamy mushroom risotto in 20 minutes.\n"
        "2: A leg-day routine at the gym.\n"
        "3: Crispy tofu stir-fry with peppers.")}]
    assert "7400000000000000001" not in json.dumps(call)
    # No temperature, top_p or prefill: Haiku 5.5 answers those with a 400.
    assert not {"temperature", "top_p", "top_k"} & call.keys()


def test_at_most_max_picks_come_back(store, haiku):
    many = [{"id": f"v{n}", "about": f"Save {n}."} for n in range(1, 31)]
    haiku.state["reply"] = answer(list(range(1, 31)))
    ids = post({"query": "anything", "candidates": many}).json()["ids"]
    assert ids == [f"v{n}" for n in range(1, search_api.MAX_PICKS + 1)]


# ------------------------------------------------------------------ shape


@pytest.mark.parametrize("body", [
    {"query": "  ", "candidates": CANDIDATES},
    {"query": "x" * (search_api.MAX_QUERY_CHARS + 1), "candidates": CANDIDATES},
    {"query": "x", "candidates": []},
    {"query": "x", "candidates": [{"id": "a", "about": "b"}] * (search_api.MAX_CANDIDATES + 1)},
    {"query": "x", "candidates": [{"id": "a", "about": "я" * search_api.MAX_ABOUT_BYTES}]},
])
def test_a_bad_shape_is_a_422_that_costs_nothing(store, monkeypatch, body):
    refuse(monkeypatch)
    assert post(body).status_code == 422
    assert store.table.get_item(Key={"PK": store.partition, "SK": "SEARCHCAP"}).get("Item") is None


# ------------------------------------------------------------------ money


def test_each_request_charges_one_unit_of_its_own_counter(store, haiku):
    post({"query": "a", "candidates": CANDIDATES})
    post({"query": "b", "candidates": CANDIDATES})
    item = store.table.get_item(Key={"PK": store.partition, "SK": "SEARCHCAP"})["Item"]
    assert item["usedToday"] == 2
    assert store.table.get_item(Key={"PK": store.partition, "SK": "ABOUTCAP"}).get("Item") is None


def test_the_cap_is_a_429_before_the_model(store, haiku, monkeypatch):
    monkeypatch.setenv("SEARCH_DAILY_CAP", "1")
    assert post({"query": "a", "candidates": CANDIDATES}).status_code == 200
    r = post({"query": "b", "candidates": CANDIDATES})
    assert r.status_code == 429 and r.json()["detail"] == "search daily cap reached"
    assert 0 < int(r.headers["retry-after"]) <= 86_400
    assert len(haiku) == 1


# ------------------------------------------------------------------ failures


def status_error(cls, code):
    request = httpx.Request("POST", "https://bedrock-mantle.eu-central-1.api.aws/anthropic/v1/messages")
    return cls("x", response=httpx.Response(code, request=request), body=None)


@pytest.mark.parametrize("error", [
    status_error(anthropic.RateLimitError, 429),
    status_error(anthropic.InternalServerError, 500),
    anthropic.APITimeoutError(request=httpx.Request("POST", "https://example.invalid")),
])
def test_provider_trouble_is_a_503_with_retry_after(store, haiku, error):
    haiku.state["reply"] = error
    r = post({"query": "a", "candidates": CANDIDATES})
    assert r.status_code == 503 and r.headers["retry-after"] == str(search_api.UPSTREAM_RETRY_AFTER)


@pytest.mark.parametrize("reply", [
    answer(stop_reason="refusal", text=""),
    answer(stop_reason="max_tokens", text='{"picks": [1, '),
    answer(text="not json"),
    answer(text='{"other": []}'),
])
def test_an_answer_that_is_not_one_is_a_502(store, haiku, reply):
    haiku.state["reply"] = reply
    r = post({"query": "a", "candidates": CANDIDATES})
    assert r.status_code == 502 and r.json()["detail"] == "search unavailable"


def test_a_request_haiku_turns_down_is_a_502_not_a_503(store, haiku):
    haiku.state["reply"] = status_error(anthropic.BadRequestError, 400)
    assert post({"query": "a", "candidates": CANDIDATES}).status_code == 502
