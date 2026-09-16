"""Spend guards on the /v1 routes.

The analyzer proxy is quota-metered: charge for work done, never for failure. The transcript
and download routes are not — they serve the deep pass over a library that already cost a
quota unit per video at import — so what bounds them is a per-user daily cap instead.
"""

import base64
import json
import os
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

import api_v1
import stash_auth
from app import app
from cloud_import_models import INITIAL_LIMIT, MONTH_LIMIT, TRIAL_LIMIT

# Everything a fresh row can spend, across trial, lifetime and month buckets.
EVERYTHING = TRIAL_LIMIT + INITIAL_LIMIT + MONTH_LIMIT
from cloud_import_store import DynamoImportStore
from conftest import ConditionalTable

URL = "https://www.tiktok.com/@x/video/123"
VIDEO_ID = "1234567890"


@pytest.fixture
def store(monkeypatch):
    monkeypatch.setenv("OPENROUTER_API_KEY", "test-openrouter-key")
    subject = DynamoImportStore(table=ConditionalTable(), user_id="user-a")
    app.dependency_overrides[stash_auth.current_user] = lambda: "user-a"
    app.dependency_overrides[stash_auth.user_store] = lambda: subject
    # The metered routes take `entitled_store`, not `user_store` — same object,
    # plus the subscription check. Overriding only one leaves the real one calling
    # Dynamo. The paywall has its own tests in test_stash_auth.py.
    app.dependency_overrides[stash_auth.entitled_store] = lambda: subject
    yield subject
    app.dependency_overrides.clear()


def drain(store):
    store.reserve_quota(EVERYTHING)


def fake_download(monkeypatch, *, succeeds=True):
    """Stand in for yt-dlp, writing the file it would have produced."""
    def run(args, **_kwargs):
        if succeeds:
            target = args[args.index("-o") + 1].replace("%(ext)s", "m4a")
            with open(target, "wb") as handle:
                handle.write(b"\x00" * 16)
        return SimpleNamespace(returncode=0 if succeeds else 1, stdout=b"", stderr=b"")
    monkeypatch.setattr(api_v1.subprocess, "run", run)


def stt_reply(monkeypatch, status=200, payload=None):
    monkeypatch.setattr(api_v1.requests, "post", lambda *a, **k: SimpleNamespace(
        status_code=status, headers={},
        json=lambda: payload or {"segments": [], "duration": 3.0}, text=""))


# ------------------------------------------------------------------ transcript


def test_transcript_costs_no_quota_and_echoes_the_balance(store, monkeypatch):
    """The video was paid for at import; reading it deeply must not cost as much again."""
    fake_download(monkeypatch)
    stt_reply(monkeypatch)
    with TestClient(app) as client:
        response = client.post("/v1/videos/transcript", json={"url": URL})

    assert response.status_code == 200
    assert response.json()["quota"]["trialRemaining"] == TRIAL_LIMIT
    assert store.get_quota().initial_remaining == INITIAL_LIMIT


def test_an_unavailable_video_is_not_billable(store, monkeypatch):
    fake_download(monkeypatch, succeeds=False)
    with TestClient(app) as client:
        response = client.post("/v1/videos/transcript", json={"url": URL})

    assert response.json()["unavailable"] is True
    assert store.get_quota().initial_remaining == INITIAL_LIMIT


@pytest.mark.parametrize("status", [429, 502])
def test_a_provider_failure_is_not_billable(store, monkeypatch, status):
    fake_download(monkeypatch)
    stt_reply(monkeypatch, status=status)
    with TestClient(app) as client:
        response = client.post("/v1/videos/transcript", json={"url": URL})

    assert response.status_code in (429, 502)
    assert store.get_quota().initial_remaining == INITIAL_LIMIT


def test_a_spent_budget_no_longer_blocks_the_deep_pass(store, monkeypatch):
    """A library imported on the last of the month is caption-only until the 1st otherwise —
    and nothing about deepening it spends the counter that ran out."""
    drain(store)
    fake_download(monkeypatch)
    stt_reply(monkeypatch)
    with TestClient(app) as client:
        assert client.post("/v1/videos/transcript", json={"url": URL}).status_code == 200
        assert client.get(f"/v1/tiktok/download/{VIDEO_ID}").status_code == 200


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
    # The body is mp4 bytes, so the quota rides along in a header instead — unmoved, because
    # the download is deep-pass work on a video the import already charged for.
    assert json.loads(response.headers["x-stash-quota"])["trialRemaining"] == TRIAL_LIMIT
    assert store.get_quota().initial_remaining == INITIAL_LIMIT


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


def test_a_failed_download_is_not_billable(store, monkeypatch):
    fake_download(monkeypatch, succeeds=False)
    with TestClient(app) as client:
        assert client.get(f"/v1/tiktok/download/{VIDEO_ID}").status_code == 502
    assert store.get_quota().initial_remaining == INITIAL_LIMIT


def test_a_photo_post_is_never_transcribed(store, monkeypatch):
    """Its audio is a licensed backing track, not speech. The app treats any non-empty
    transcript as the post's own content and re-analyses from text alone, which wiped the
    album picks the fast pass had just read off the picture."""
    def run(args, **_kwargs):
        target = args[args.index("-o") + 1]
        directory = os.path.dirname(target)
        with open(target.replace("%(ext)s", "m4a"), "wb") as handle:
            handle.write(b"\x00" * 16)
        with open(os.path.join(directory, "audio.info.json"), "w", encoding="utf-8") as handle:
            handle.write(json.dumps({"formats": [{"format_id": "audio", "vcodec": "none"}]}))
        return SimpleNamespace(returncode=0, stdout=b"", stderr=b"")

    monkeypatch.setattr(api_v1.subprocess, "run", run)
    monkeypatch.setattr(api_v1.requests, "post",
                        lambda *a, **k: pytest.fail("Whisper ran for a photo post"))
    with TestClient(app) as client:
        response = client.post("/v1/videos/transcript", json={"url": URL})

    assert response.status_code == 200
    assert response.json()["transcript"] is None
    assert store.get_quota().initial_remaining == INITIAL_LIMIT


def test_a_photo_post_is_refused_as_unreadable_not_as_a_failure(store, monkeypatch):
    """A photo post has no video track, so yt-dlp reports the format missing. 502 made that
    look retryable, and five in a row abort the app's whole visual backfill — 415 tells it to
    record the read as done and move on to the real videos behind it."""
    def run(args, **_kwargs):
        return SimpleNamespace(
            returncode=1, stdout=b"",
            stderr=b"ERROR: [TikTok] 123: Requested format is not available.")

    monkeypatch.setattr(api_v1.subprocess, "run", run)
    with TestClient(app) as client:
        assert client.get(f"/v1/tiktok/download/{VIDEO_ID}").status_code == 415
    assert store.get_quota().initial_remaining == INITIAL_LIMIT


def test_a_bad_video_id_is_refused(store):
    with TestClient(app) as client:
        assert client.get("/v1/tiktok/download/../etc/passwd").status_code in (400, 404)
        assert client.get("/v1/tiktok/download/12").status_code == 400


# ------------------------------------------------------------------ deep-pass daily cap


def deep_pass_calls(client):
    """The two routes the cap covers, as no-argument calls."""
    return (lambda: client.post("/v1/videos/transcript", json={"url": URL}),
            lambda: client.get(f"/v1/tiktok/download/{VIDEO_ID}"))


@pytest.mark.parametrize("route", [0, 1])
def test_the_daily_cap_429s_at_the_limit(store, monkeypatch, route):
    """Quota no longer bounds these two, so this is the only thing that does."""
    monkeypatch.setenv("DEEP_PASS_DAILY_CAP", "2")
    fake_download(monkeypatch)
    stt_reply(monkeypatch)
    with TestClient(app) as client:
        call = deep_pass_calls(client)[route]
        assert call().status_code == 200
        assert call().status_code == 200
        refused = call()

    assert refused.status_code == 429
    assert refused.json()["detail"] == "deep-pass daily cap reached"
    # The app backs off on any 429; Retry-After says how long — the next UTC midnight.
    assert 0 < int(refused.headers["retry-after"]) <= 86_400


def test_both_routes_draw_on_the_same_daily_counter(store, monkeypatch):
    """One counter per user, not one per route: a deep pass makes both calls per video, so
    a cap each would be twice the cap it says it is."""
    monkeypatch.setenv("DEEP_PASS_DAILY_CAP", "1")
    fake_download(monkeypatch)
    stt_reply(monkeypatch)
    with TestClient(app) as client:
        assert client.post("/v1/videos/transcript", json={"url": URL}).status_code == 200
        assert client.get(f"/v1/tiktok/download/{VIDEO_ID}").status_code == 429


def test_a_capped_account_never_reaches_yt_dlp(store, monkeypatch):
    """The whole point is bounding what we spend, and yt-dlp is the spend."""
    monkeypatch.setenv("DEEP_PASS_DAILY_CAP", "0")
    monkeypatch.setattr(api_v1.subprocess, "run",
                        lambda *a, **k: pytest.fail("yt-dlp ran for a capped account"))
    with TestClient(app) as client:
        assert client.post("/v1/videos/transcript", json={"url": URL}).status_code == 429
        assert client.get(f"/v1/tiktok/download/{VIDEO_ID}").status_code == 429


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
    # No system message to substitute, so the messages go through untouched.
    assert sent["messages"] == [{"role": "user", "content": "hi"}]


def test_the_proxy_substitutes_its_own_analysis_prompt(store, monkeypatch):
    """The app's deep pass used to ship a second copy of the analysis rules, and the two copies
    drifted: a re-analysis answered to instructions the fast pass had never seen. The box owns
    the prompt now, so the client sends a placeholder and gets the canonical one."""
    sent = {}

    def capture(_url, headers=None, json=None, timeout=None):
        sent.update(json)
        return SimpleNamespace(content=b"{}", status_code=200)

    monkeypatch.setattr(api_v1, "_bedrock_token", lambda: "test-bedrock-token")
    monkeypatch.setattr(api_v1.requests, "post", capture)
    with TestClient(app) as client:
        response = client.post("/v1/chat/completions", json={"messages": [
            {"role": "system", "content": "analyze"},
            {"role": "user", "content": "Caption: five jungle albums"}]})

    assert response.status_code == 200
    assert sent["messages"][0] == {"role": "system", "content": api_v1.ANALYSIS_SYSTEM_PROMPT}
    # Only the system message is replaced; the caller's own context still reaches the model.
    assert sent["messages"][1] == {"role": "user", "content": "Caption: five jungle albums"}


@pytest.fixture
def analyzer_calls(monkeypatch):
    """Capture the outbound analyzer request without spending a provider call."""
    calls = []

    def capture(url, headers=None, json=None, timeout=None):
        calls.append({"url": url, "headers": headers, "body": json})
        return SimpleNamespace(
            status_code=200,
            json=lambda: {"choices": [{"message": {"content": '{"category":"music"}'}}]})

    monkeypatch.setattr(api_v1, "_bedrock_token", lambda: "test-bedrock-token")
    monkeypatch.setattr(api_v1.requests, "post", capture)
    return calls


def test_a_photo_post_goes_to_the_vision_model_with_its_picture(monkeypatch, analyzer_calls):
    """Bedrock's Gemma cannot recognise album artwork, so an album-grid post has to reach a
    model that can — with the picture attached, since its releases are only ever pixels."""
    monkeypatch.setattr(api_v1, "_openrouter_key", lambda: "test-openrouter-key")

    api_v1.analyze_metadata({"caption": "", "track": "Age of Consent",
                             "isPhotoPost": True, "images": [b"jpeg"]})
    call = analyzer_calls[-1]
    assert call["url"] == api_v1.OPENROUTER_URL
    assert call["body"]["model"] == api_v1.OPENROUTER_VISION_MODEL
    assert call["headers"]["Authorization"] == "Bearer test-openrouter-key"
    # A sixteen-album grid runs past the text ceiling; truncation loses the whole analysis.
    assert call["body"]["max_tokens"] == api_v1.VISION_MAX_OUTPUT_TOKENS
    content = call["body"]["messages"][1]["content"]
    assert [part["type"] for part in content] == ["text", "image_url"]
    assert content[1]["image_url"]["url"] == "data:image/jpeg;base64,anBlZw=="
    assert "photo post" in content[0]["text"]
    # The sleeve-reading rules ride on top of the one analysis prompt, never as a second copy.
    system = call["body"]["messages"][0]["content"]
    assert system.startswith(api_v1.ANALYSIS_SYSTEM_PROMPT)
    assert system.endswith(api_v1.PHOTO_SYSTEM_PROMPT_ADDENDUM)


def test_film_extraction_rules_reach_the_analyzer(analyzer_calls):
    """The shared analyzer contract must request only explicit movie titles, never TV padding."""
    api_v1.analyze_metadata({"caption": "five films to watch"})

    system = analyzer_calls[-1]["body"]["messages"][0]["content"]
    assert '"films"' in system
    assert "explicitly named" in system
    assert "TV series" in system


def test_every_slide_reaches_the_vision_model_in_order(monkeypatch, analyzer_calls):
    """A slideshow's list lives on its later slides; the model must see all of them, in the
    order the post shows them, or a seven-slide topster reads as a one-image meme."""
    monkeypatch.setattr(api_v1, "_openrouter_key", lambda: "test-openrouter-key")

    api_v1.analyze_metadata({"caption": "", "isPhotoPost": True,
                             "images": [b"one", b"two", b"three"]})
    call = analyzer_calls[-1]
    content = call["body"]["messages"][1]["content"]
    assert [part["type"] for part in content] == ["text", "image_url", "image_url", "image_url"]
    assert [part["image_url"]["url"] for part in content[1:]] == [
        "data:image/jpeg;base64," + base64.b64encode(raw).decode()
        for raw in (b"one", b"two", b"three")]
    assert "3 slides" in content[0]["text"]


def test_an_ordinary_video_still_goes_to_bedrock(monkeypatch, analyzer_calls):
    monkeypatch.setattr(api_v1, "_openrouter_key", lambda: "test-openrouter-key")

    api_v1.analyze_metadata({"caption": "a real video"})
    call = analyzer_calls[-1]
    assert call["url"] == api_v1.BEDROCK_URL
    assert isinstance(call["body"]["messages"][1]["content"], str)
    # No picture, so none of the photo rules — they describe an image that is not there.
    assert call["body"]["messages"][0]["content"] == api_v1.ANALYSIS_SYSTEM_PROMPT


def test_a_photo_post_falls_back_to_bedrock_without_a_vision_key(monkeypatch, analyzer_calls):
    """One missing credential must degrade to an unread picture, not turn every photo post
    in an import into an error."""
    monkeypatch.setattr(api_v1, "_openrouter_key", lambda: "")

    api_v1.analyze_metadata({"caption": "", "isPhotoPost": True, "images": [b"jpeg"]})
    call = analyzer_calls[-1]
    assert call["url"] == api_v1.BEDROCK_URL
    assert isinstance(call["body"]["messages"][1]["content"], str)


def test_a_photo_post_with_no_picture_says_so(monkeypatch, analyzer_calls):
    """TikTok would not serve the image. The prompt must still say it is a photo post, or the
    backing track is the only line in it and comes back as the recommendation."""
    monkeypatch.setattr(api_v1, "_openrouter_key", lambda: "test-openrouter-key")

    api_v1.analyze_metadata({"caption": "", "track": "Age of Consent", "isPhotoPost": True})
    call = analyzer_calls[-1]
    assert call["url"] == api_v1.BEDROCK_URL
    assert "could not be fetched" in call["body"]["messages"][1]["content"]


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
    # A new account is on the free trial, so that is the bucket the unit comes out of.
    assert json.loads(response.headers["x-stash-quota"])["trialRemaining"] == TRIAL_LIMIT - 1
    assert store.get_quota().trial_remaining == TRIAL_LIMIT - 1


def test_the_analyzer_402s_once_its_last_unit_is_spent(store, monkeypatch):
    bedrock_reply(monkeypatch)
    body = {"messages": [{"role": "user", "content": "hi"}]}
    store.reserve_quota(EVERYTHING - 1)  # one unit left
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


def test_an_instagram_shortcode_downloads_the_reel(store, monkeypatch):
    seen = []

    def run(args, **_kwargs):
        seen.append(args[-1])
        with open(args[args.index("-o") + 1], "wb") as handle:
            handle.write(b"\x00" * 16)
        return SimpleNamespace(returncode=0, stdout=b"", stderr=b"")

    monkeypatch.setattr(api_v1.subprocess, "run", run)
    with TestClient(app) as client:
        assert client.get("/v1/tiktok/download/DBL2NCuMkAo").status_code == 200
        assert client.get("/v1/tiktok/download/bad.id").status_code == 400
    assert seen == ["https://www.instagram.com/reel/DBL2NCuMkAo/"]
