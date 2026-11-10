"""The search route: a model picks which of the app's candidates answer a request.

What these pin is the mapping back from the model's numbers to the app's ids (in its order, never
an id it did not send, never twice), what the model is asked, and the money: one unit of a daily
counter of its own, charged after the shape check and before the model.
"""

import pytest
import requests
from fastapi.testclient import TestClient

import api_v1
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


@pytest.fixture(autouse=True)
def token(monkeypatch):
    """No test reaches for AWS: a missing credential would raise inside the route and pass every
    502 assertion for the wrong reason."""
    monkeypatch.setattr(api_v1, "_bedrock_token", lambda: "test-bedrock-token")


@pytest.fixture
def model(monkeypatch):
    """Stand in for the one network call, recording what it was handed and answering `reply`."""
    calls = type("Calls", (list,), {})()  # a list that can also carry the reply
    calls.reply = "1"

    def fake(url, model, token, system, content, max_tokens, timeout):
        calls.append({"url": url, "model": model, "token": token, "system": system,
                      "content": content, "max_tokens": max_tokens, "timeout": timeout})
        if isinstance(calls.reply, Exception):
            raise calls.reply
        return calls.reply

    monkeypatch.setattr(search_api, "_chat", fake)
    return calls


def refuse(monkeypatch):
    monkeypatch.setattr(search_api, "_chat",
                        lambda *a, **k: pytest.fail("the model was called for a refused request"))


CANDIDATES = [{"id": "7400000000000000001", "about": "A creamy mushroom risotto in 20 minutes."},
              {"id": "7400000000000000002", "about": "A leg-day routine at the gym."},
              {"id": "7400000000000000003", "about": "Crispy tofu stir-fry\nwith peppers."}]


def post(json_body):
    with TestClient(app) as client:
        return client.post("/v1/search", json=json_body)


# ------------------------------------------------------------------ the happy path


def test_picks_come_back_as_ids_in_the_models_order(store, model):
    model.reply = "3, 1"
    r = post({"query": "quick vegetarian dinner", "candidates": CANDIDATES})
    assert r.status_code == 200
    assert r.json() == {"ids": ["7400000000000000003", "7400000000000000001"]}


def test_a_number_that_names_no_candidate_is_dropped_and_a_repeat_counts_once(store, model):
    model.reply = "2, 0, 4, 2, 1"
    assert post({"query": "gym", "candidates": CANDIDATES}).json() == {
        "ids": ["7400000000000000002", "7400000000000000001"]}


@pytest.mark.parametrize("reply", ["none", "None.", "I'm sorry, I can't help with that."])
def test_nothing_fits_or_a_refusal_is_an_empty_answer_not_an_error(store, model, reply):
    """Empty is what the app reads as "keep your own ranking"."""
    model.reply = reply
    assert post({"query": "car repair", "candidates": CANDIDATES}).json() == {"ids": []}


def test_what_the_model_is_asked(store, model):
    post({"query": "  quick vegetarian dinner ", "candidates": CANDIDATES})
    call = model[0]
    # Gemma on Bedrock Frankfurt, the about-texts' own model and endpoint: no new processor.
    assert (call["url"], call["model"]) == (api_v1.BEDROCK_URL, api_v1.BEDROCK_MODEL)
    assert call["token"] == "test-bedrock-token"
    assert call["system"] == search_api.SEARCH_SYSTEM_PROMPT
    assert call["timeout"] == search_api.SEARCH_TIMEOUT
    # Numbered, one line each (a newline inside an about-text would start a fake entry), and the
    # ids never reach the prompt.
    assert call["content"] == (
        "Request: quick vegetarian dinner\n\nSaved videos:\n"
        "1: A creamy mushroom risotto in 20 minutes.\n"
        "2: A leg-day routine at the gym.\n"
        "3: Crispy tofu stir-fry with peppers.")
    assert "7400000000000000001" not in call["content"]


def test_at_most_max_picks_come_back(store, model):
    many = [{"id": f"v{n}", "about": f"Save {n}."} for n in range(1, 31)]
    model.reply = ", ".join(str(n) for n in range(1, 31))
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


def test_each_request_charges_one_unit_of_its_own_counter(store, model):
    post({"query": "a", "candidates": CANDIDATES})
    post({"query": "b", "candidates": CANDIDATES})
    item = store.table.get_item(Key={"PK": store.partition, "SK": "SEARCHCAP"})["Item"]
    assert item["usedToday"] == 2
    assert store.table.get_item(Key={"PK": store.partition, "SK": "ABOUTCAP"}).get("Item") is None


def test_the_cap_is_a_429_before_the_model(store, model, monkeypatch):
    monkeypatch.setenv("SEARCH_DAILY_CAP", "1")
    assert post({"query": "a", "candidates": CANDIDATES}).status_code == 200
    r = post({"query": "b", "candidates": CANDIDATES})
    assert r.status_code == 429 and r.json()["detail"] == "search daily cap reached"
    assert 0 < int(r.headers["retry-after"]) <= 86_400
    assert len(model) == 1


# ------------------------------------------------------------------ failures


def http_error(status):
    response = requests.Response()
    response.status_code = status
    return requests.HTTPError(f"about model {status}", response=response)


@pytest.mark.parametrize("error", [http_error(429), http_error(503), requests.Timeout("slow")])
def test_provider_trouble_is_a_503_with_retry_after(store, model, error):
    model.reply = error
    r = post({"query": "a", "candidates": CANDIDATES})
    assert r.status_code == 503 and r.headers["retry-after"] == str(search_api.UPSTREAM_RETRY_AFTER)


@pytest.mark.parametrize("error", [http_error(400), KeyError("choices")])
def test_a_request_the_provider_turns_down_is_a_502(store, model, error):
    model.reply = error
    r = post({"query": "a", "candidates": CANDIDATES})
    assert r.status_code == 502 and r.json()["detail"] == "search unavailable"
