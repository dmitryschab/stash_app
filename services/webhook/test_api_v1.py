"""Quota behaviour of the /v1 media routes: charge for work done, never for failure."""

import json
import os
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

import api_v1
import stash_auth
from app import app
from cloud_import_models import INITIAL_LIMIT, MONTH_LIMIT
from cloud_import_store import DynamoImportStore
from conftest import ConditionalTable

URL = "https://www.tiktok.com/@x/video/123"
VIDEO_ID = "1234567890"


@pytest.fixture
def store(monkeypatch):
    monkeypatch.setenv("GROQ_API_KEY", "test-groq-key")
    subject = DynamoImportStore(table=ConditionalTable(), user_id="user-a")
    app.dependency_overrides[stash_auth.current_user] = lambda: "user-a"
    app.dependency_overrides[stash_auth.user_store] = lambda: subject
    yield subject
    app.dependency_overrides.clear()


def drain(store):
    store.reserve_quota(INITIAL_LIMIT + MONTH_LIMIT)


def fake_download(monkeypatch, *, succeeds=True):
    """Stand in for yt-dlp, writing the file it would have produced."""
    def run(args, **_kwargs):
        if succeeds:
            target = args[args.index("-o") + 1].replace("%(ext)s", "m4a")
            with open(target, "wb") as handle:
                handle.write(b"\x00" * 16)
        return SimpleNamespace(returncode=0 if succeeds else 1, stdout=b"", stderr=b"")
    monkeypatch.setattr(api_v1.subprocess, "run", run)


def groq_reply(monkeypatch, status=200, payload=None):
    monkeypatch.setattr(api_v1.requests, "post", lambda *a, **k: SimpleNamespace(
        status_code=status, headers={},
        json=lambda: payload or {"segments": [], "duration": 3.0}, text=""))


# ------------------------------------------------------------------ transcript


def test_transcript_charges_one_unit_and_echoes_quota(store, monkeypatch):
    fake_download(monkeypatch)
    groq_reply(monkeypatch)
    with TestClient(app) as client:
        response = client.post("/v1/videos/transcript", json={"url": URL})

    assert response.status_code == 200
    assert response.json()["quota"]["initialRemaining"] == INITIAL_LIMIT - 1
    assert store.get_quota().initial_remaining == INITIAL_LIMIT - 1


def test_an_unavailable_video_is_not_billable(store, monkeypatch):
    fake_download(monkeypatch, succeeds=False)
    with TestClient(app) as client:
        response = client.post("/v1/videos/transcript", json={"url": URL})

    assert response.json()["unavailable"] is True
    assert store.get_quota().initial_remaining == INITIAL_LIMIT


@pytest.mark.parametrize("status", [429, 502])
def test_a_provider_failure_is_not_billable(store, monkeypatch, status):
    fake_download(monkeypatch)
    groq_reply(monkeypatch, status=status)
    with TestClient(app) as client:
        response = client.post("/v1/videos/transcript", json={"url": URL})

    assert response.status_code in (429, 502)
    assert store.get_quota().initial_remaining == INITIAL_LIMIT


def test_transcript_402s_before_doing_any_work(store, monkeypatch):
    drain(store)
    monkeypatch.setattr(api_v1.subprocess, "run",
                        lambda *a, **k: pytest.fail("yt-dlp ran for an exhausted account"))
    with TestClient(app) as client:
        response = client.post("/v1/videos/transcript", json={"url": URL})

    assert response.status_code == 402
    assert response.json()["detail"] == "quota exhausted"
    assert response.json()["quota"]["monthRemaining"] == 0


def test_a_non_tiktok_url_is_refused(store):
    with TestClient(app) as client:
        assert client.post("/v1/videos/transcript",
                           json={"url": "https://evil.test/v/1"}).status_code == 400


# ------------------------------------------------------------------ transient media


def test_download_streams_bytes_and_reports_quota_in_a_header(store, monkeypatch):
    fake_download(monkeypatch)
    with TestClient(app) as client:
        response = client.get(f"/v1/tiktok/download/{VIDEO_ID}")

    assert response.status_code == 200
    assert response.headers["content-type"] == "video/mp4"
    assert response.content == b"\x00" * 16
    # The body is mp4 bytes, so the fresh quota rides along in a header instead.
    assert json.loads(response.headers["x-stash-quota"])["initialRemaining"] == INITIAL_LIMIT - 1
    assert store.get_quota().initial_remaining == INITIAL_LIMIT - 1


def test_download_cleans_up_its_temporary_file(store, monkeypatch):
    created = []
    inner = api_v1.tempfile.mkdtemp

    def tracking(**kwargs):
        path = inner(**kwargs)
        created.append(path)
        return path

    monkeypatch.setattr(api_v1.tempfile, "mkdtemp", tracking)
    fake_download(monkeypatch)
    with TestClient(app) as client:
        client.get(f"/v1/tiktok/download/{VIDEO_ID}")

    assert created and not any(os.path.exists(path) for path in created)


def test_download_402s_before_fetching_anything(store, monkeypatch):
    drain(store)
    monkeypatch.setattr(api_v1.subprocess, "run",
                        lambda *a, **k: pytest.fail("yt-dlp ran for an exhausted account"))
    with TestClient(app) as client:
        response = client.get(f"/v1/tiktok/download/{VIDEO_ID}")
    assert response.status_code == 402


def test_a_failed_download_is_not_billable(store, monkeypatch):
    fake_download(monkeypatch, succeeds=False)
    with TestClient(app) as client:
        assert client.get(f"/v1/tiktok/download/{VIDEO_ID}").status_code == 502
    assert store.get_quota().initial_remaining == INITIAL_LIMIT


def test_a_bad_video_id_is_refused(store):
    with TestClient(app) as client:
        assert client.get("/v1/tiktok/download/../etc/passwd").status_code in (400, 404)
        assert client.get("/v1/tiktok/download/12").status_code == 400


# ------------------------------------------------------------------ analyzer proxy


def test_an_oversized_analyzer_body_is_refused(store, monkeypatch):
    monkeypatch.setattr(api_v1.requests, "post",
                        lambda *a, **k: pytest.fail("bedrock called for an oversized body"))
    with TestClient(app) as client:
        response = client.post("/v1/chat/completions",
                               json={"messages": [{"role": "user", "content": "x" * 40_000}]})
    assert response.status_code == 413


def test_the_analyzer_body_is_rebuilt_from_an_allowlist(store, monkeypatch):
    """Forwarding the client body verbatim made one account an unmetered LLM proxy: the size
    cap bounds input, while max_tokens and n bound what we actually pay for."""
    sent = {}

    def capture(_url, headers=None, json=None, timeout=None):
        sent.update(json)
        return SimpleNamespace(content=b"{}", status_code=200)

    monkeypatch.setattr(api_v1, "_bedrock_token", lambda: "test-bedrock-token")
    monkeypatch.setattr(api_v1.requests, "post", capture)
    with TestClient(app) as client:
        response = client.post("/v1/chat/completions", json={
            "model": "gpt-4o", "messages": [{"role": "user", "content": "hi"}],
            "max_tokens": 32_000, "n": 8, "stream": True, "temperature": 9.0,
            "response_format": {"type": "json_object"}})

    assert response.status_code == 200
    assert sent["model"] == api_v1.BEDROCK_MODEL
    assert sent["max_tokens"] == api_v1.CHAT_MAX_OUTPUT_TOKENS
    assert sent["temperature"] == 1.0
    assert set(sent) == {"model", "messages", "temperature", "max_tokens"}


def test_an_exhausted_account_cannot_drive_the_analyzer(store, monkeypatch):
    drain(store)
    monkeypatch.setattr(api_v1.requests, "post",
                        lambda *a, **k: pytest.fail("bedrock called for an exhausted account"))
    with TestClient(app) as client:
        response = client.post("/v1/chat/completions",
                               json={"messages": [{"role": "user", "content": "hi"}]})
    assert response.status_code == 402
    assert store.get_quota().initial_remaining == 0


def bedrock_reply(monkeypatch, status=200):
    monkeypatch.setattr(api_v1, "_bedrock_token", lambda: "test-bedrock-token")
    monkeypatch.setattr(api_v1.requests, "post", lambda *a, **k: SimpleNamespace(
        content=b'{"choices":[]}', status_code=status))


def test_the_analyzer_costs_a_unit_and_reports_the_balance_in_a_header(store, monkeypatch):
    """Authenticated but unmetered made one invited account an unbounded Bedrock bill."""
    bedrock_reply(monkeypatch)
    with TestClient(app) as client:
        response = client.post("/v1/chat/completions",
                               json={"messages": [{"role": "user", "content": "hi"}]})

    assert response.status_code == 200
    # The body is a verbatim OpenAI-shape pass-through, so the quota rides in the header.
    assert json.loads(response.headers["x-stash-quota"])["initialRemaining"] == INITIAL_LIMIT - 1
    assert store.get_quota().initial_remaining == INITIAL_LIMIT - 1


def test_the_analyzer_402s_once_its_last_unit_is_spent(store, monkeypatch):
    bedrock_reply(monkeypatch)
    body = {"messages": [{"role": "user", "content": "hi"}]}
    store.reserve_quota(INITIAL_LIMIT + MONTH_LIMIT - 1)  # one unit left
    with TestClient(app) as client:
        assert client.post("/v1/chat/completions", json=body).status_code == 200
        assert store.get_quota().month_remaining == 0
        assert client.post("/v1/chat/completions", json=body).status_code == 402


def test_a_bedrock_failure_is_not_billable(store, monkeypatch):
    bedrock_reply(monkeypatch, status=500)
    with TestClient(app) as client:
        assert client.post("/v1/chat/completions",
                           json={"messages": [{"role": "user", "content": "hi"}]}).status_code == 500
    assert store.get_quota().initial_remaining == INITIAL_LIMIT
