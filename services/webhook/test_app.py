"""Self-check for the public webhook: signature verification, body cap, secret loading."""
import asyncio
import hashlib
import hmac

import pytest

import app as m
import stash_secrets


def test_missing_secret_rejects_unless_dev_mode_is_explicit(monkeypatch):
    # The old behaviour returned True here, so "nobody configured the secret yet" was
    # indistinguishable from "the signature verified". Production is fail-closed now.
    monkeypatch.setattr(m, "CLIENT_SECRET", "")
    monkeypatch.delenv("STASH_DEV_MODE", raising=False)
    assert m.verify_signature(b"x", None) is False
    assert m.verify_signature(b"x", "anything") is False

    monkeypatch.setenv("STASH_DEV_MODE", "1")
    assert m.verify_signature(b"x", None) is True


def test_configured_secret_checks_the_hmac(monkeypatch):
    monkeypatch.setattr(m, "CLIENT_SECRET", "secret")
    monkeypatch.setenv("STASH_DEV_MODE", "1")  # never overrides a configured secret
    body = b'{"a":1}'
    good = hmac.new(b"secret", body, hashlib.sha256).hexdigest()
    assert m.verify_signature(body, good) is True
    assert m.verify_signature(body, "deadbeef") is False
    assert m.verify_signature(body, None) is False


def test_a_non_ascii_signature_is_rejected_not_raised(monkeypatch):
    """Headers arrive latin-1-decoded. hmac.compare_digest raises TypeError on a str with
    any codepoint above 0x7F, so one such byte used to turn this public, unauthenticated
    route into a 500 with a logged traceback instead of a 401."""
    monkeypatch.setattr(m, "CLIENT_SECRET", "secret")
    assert m.verify_signature(b'{"a":1}', "\xf1") is False
    assert m.verify_signature(b'{"a":1}', "deadbeefÿ") is False


class _Stream:
    """Minimal stand-in for the parts of Request that _read_capped touches."""

    def __init__(self, chunks):
        self._chunks = chunks

    async def _iter(self):
        for chunk in self._chunks:
            yield chunk

    def stream(self):
        return self._iter()


def read_capped(chunks, limit=m.WEBHOOK_MAX_BYTES):
    return asyncio.run(m._read_capped(_Stream(chunks), limit))


def test_a_body_within_the_cap_is_read_whole():
    assert read_capped([b'{"a":', b'1}']) == b'{"a":1}'


def test_an_oversized_body_is_dropped_before_it_is_buffered():
    """Chunked, so there is no Content-Length to check up front: the cap has to hold on
    the stream itself, or any caller can buffer a 1 GB box out of memory."""
    chunk = b"x" * 8192
    over = [chunk] * (m.WEBHOOK_MAX_BYTES // len(chunk) + 2)
    assert read_capped(over) is None


@pytest.mark.parametrize("limit", [0, 1])
def test_the_cap_is_exclusive_at_the_boundary(limit):
    assert read_capped([b"x" * limit], limit=limit) == b"x" * limit
    assert read_capped([b"x" * (limit + 1)], limit=limit) is None


def test_health_reports_missing_apple_revocation_credentials(monkeypatch):
    """Revocation degrades silently on purpose — sign-in must not break because the Apple
    key is absent — so /health is the only signal that guideline 5.1.1(v) is unenforceable.
    Every account created while this reads 'unconfigured' can never have its grant revoked."""
    monkeypatch.setattr(m, "_health_cache", {"checked_at": 0.0, "result": {}})
    monkeypatch.setattr("cloud_import_store.shared_table", lambda: type("T", (), {"table_status": "ACTIVE"})())
    monkeypatch.setattr("cloud_import_queue.SQSImportQueue", lambda: (_ for _ in ()).throw(RuntimeError("no sqs")))

    present = {"APPLE_TEAM_ID": "T", "APPLE_KEY_ID": "K", "APPLE_PRIVATE_KEY": "P"}
    monkeypatch.setattr(m.stash_secrets, "secret", lambda name: present.get(name, ""))
    assert m._dependency_health()["appleRevocation"] == "ok"

    for missing in present:
        partial = {k: v for k, v in present.items() if k != missing}
        monkeypatch.setattr(m.stash_secrets, "secret", lambda name, p=partial: p.get(name, ""))
        assert m._dependency_health()["appleRevocation"] == "unconfigured", missing


def test_a_failed_secrets_load_is_retried_not_cached_forever(monkeypatch):
    """Caching the failure pinned the process into 'STASH_JWT_SECRET is missing', which
    503s every authenticated route until someone restarts the units by hand."""
    monkeypatch.setenv("STASH_SECRETS_ID", "stash/app")
    monkeypatch.delenv("STASH_JWT_SECRET", raising=False)
    stash_secrets.reset_cache()

    calls = []

    class Client:
        def get_secret_value(self, SecretId):
            calls.append(SecretId)
            if len(calls) == 1:
                raise RuntimeError("secrets manager unreachable")
            return {"SecretString": '{"STASH_JWT_SECRET": "live-key"}'}

    monkeypatch.setattr("cloud_import_aws.instance_role_session",
                        lambda: type("S", (), {"client": lambda self, name: Client()})())

    assert stash_secrets.secret("STASH_JWT_SECRET") == ""      # outage
    assert stash_secrets.secret("STASH_JWT_SECRET") == "live-key"  # heals on the next call
    assert stash_secrets.secret("STASH_JWT_SECRET") == "live-key"  # and is cached after
    assert len(calls) == 2
    stash_secrets.reset_cache()
