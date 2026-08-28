"""The embeddings route: authenticated, capped by shape, and free.

Free is the interesting property. Every other route that reaches a provider is bounded by a
counter — quota for the analyzer, a daily cap for the deep pass — and this one is bounded only
by how much text a single request may carry, so those caps are what the tests are about.
"""

import json
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

import embeddings_api
import stash_auth
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


@pytest.fixture
def bedrock(monkeypatch):
    """Stand in for bedrock-runtime, recording every inputText it was handed."""
    calls = []

    def invoke_model(*, modelId, body):
        payload = json.loads(body)
        calls.append({"modelId": modelId, "body": payload})
        vector = [0.0] * embeddings_api.EMBEDDING_DIMS
        vector[0] = 1.0
        return {"body": SimpleNamespace(read=lambda: json.dumps({"embedding": vector}).encode())}

    monkeypatch.setattr(embeddings_api, "_runtime", lambda: SimpleNamespace(invoke_model=invoke_model))
    return calls


def refuse(monkeypatch):
    monkeypatch.setattr(embeddings_api, "_runtime",
                        lambda: pytest.fail("bedrock was called for a refused request"))


# ------------------------------------------------------------------ the happy path


def test_one_vector_per_text_in_order(store, bedrock):
    with TestClient(app) as client:
        response = client.post("/v1/embeddings", json={"texts": ["a recipe", "an album"]})

    assert response.status_code == 200
    body = response.json()
    assert len(body["vectors"]) == 2
    assert all(len(vector) == embeddings_api.EMBEDDING_DIMS for vector in body["vectors"])
    assert body["model"] == embeddings_api.EMBEDDING_MODEL
    assert body["dims"] == embeddings_api.EMBEDDING_DIMS
    assert [call["body"]["inputText"] for call in bedrock] == ["a recipe", "an album"]


def test_the_vector_size_is_asked_for_not_assumed(store, bedrock):
    """`dims` in the answer has to be the number Titan was told to produce, or the client packs
    a 1024-float vector into a store it sized for 256."""
    with TestClient(app) as client:
        client.post("/v1/embeddings", json={"texts": ["x"]})

    assert bedrock[0]["body"]["dimensions"] == embeddings_api.EMBEDDING_DIMS
    assert bedrock[0]["body"]["normalize"] is True
    assert bedrock[0]["modelId"] == embeddings_api.EMBEDDING_MODEL


def test_a_blank_text_never_reaches_bedrock(store, bedrock):
    """Titan rejects an empty inputText, and one blank save in a batch of 32 would fail the
    other 31 with it."""
    with TestClient(app) as client:
        response = client.post("/v1/embeddings", json={"texts": ["", "   "]})

    assert response.status_code == 200
    assert response.json()["vectors"] == [[0.0] * embeddings_api.EMBEDDING_DIMS] * 2
    assert bedrock == []


# ------------------------------------------------------------------ caps


def test_more_than_the_batch_cap_is_refused(store, monkeypatch):
    refuse(monkeypatch)
    with TestClient(app) as client:
        response = client.post(
            "/v1/embeddings", json={"texts": ["x"] * (embeddings_api.MAX_TEXTS + 1)})
    assert response.status_code == 422


def test_the_batch_cap_itself_is_allowed(store, bedrock):
    with TestClient(app) as client:
        response = client.post("/v1/embeddings", json={"texts": ["x"] * embeddings_api.MAX_TEXTS})
    assert response.status_code == 200
    assert len(response.json()["vectors"]) == embeddings_api.MAX_TEXTS


def test_an_oversized_text_is_refused(store, monkeypatch):
    """Measured in bytes, not characters: a Cyrillic transcript is two bytes a letter, and this
    is a cap on what we send Bedrock, not on how it reads."""
    refuse(monkeypatch)
    with TestClient(app) as client:
        response = client.post(
            "/v1/embeddings", json={"texts": ["я" * embeddings_api.MAX_TEXT_BYTES]})
    assert response.status_code == 422


def test_an_empty_request_is_refused(store, monkeypatch):
    refuse(monkeypatch)
    with TestClient(app) as client:
        assert client.post("/v1/embeddings", json={"texts": []}).status_code == 422


# ------------------------------------------------------------------ auth and money


def test_a_caller_without_a_session_is_refused():
    """No dependency overrides here, so the real `current_user` answers — and it answers 401
    before anything reaches Dynamo or Bedrock."""
    with TestClient(app) as client:
        assert client.post("/v1/embeddings", json={"texts": ["x"]}).status_code == 401


def test_embedding_costs_no_quota(store, bedrock):
    """A save the import already paid for has to stay findable for the rest of the month."""
    with TestClient(app) as client:
        assert client.post("/v1/embeddings", json={"texts": ["x"] * 8}).status_code == 200
    assert store.get_quota().initial_remaining == INITIAL_LIMIT


def test_an_exhausted_account_can_still_search(store, bedrock):
    store.reserve_quota(INITIAL_LIMIT + 100)
    with TestClient(app) as client:
        assert client.post("/v1/embeddings", json={"texts": ["x"]}).status_code == 200


def test_an_upstream_failure_is_a_502(store, monkeypatch):
    def boom(*, modelId, body):
        raise RuntimeError("bedrock said no")

    monkeypatch.setattr(embeddings_api, "_runtime", lambda: SimpleNamespace(invoke_model=boom))
    with TestClient(app) as client:
        assert client.post("/v1/embeddings", json={"texts": ["x"]}).status_code == 502
