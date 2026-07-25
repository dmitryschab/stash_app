"""Secret material for the box: AWS Secrets Manager, with an environment fallback.

Every credential the API needs (STASH_JWT_SECRET, GROQ_API_KEY, TIKTOK_CLIENT_SECRET,
APPLE_TEAM_ID / APPLE_KEY_ID / APPLE_PRIVATE_KEY) is read through `secret(name)`.

Lookup order is environment first, then one Secrets Manager blob. Environment-first is
what keeps pytest and `python api_v1.py` from ever reaching for instance metadata off-box,
and it gives the operator a one-line override on the box. The Secrets Manager call only
happens when STASH_SECRETS_ID is set AND the name is absent from the environment, so a
laptop with no AWS credentials never blocks on IMDS.

ponytail: the blob is fetched once per process and cached forever — rotation means
`systemctl restart stash-webhook stash-import-worker`, not a live refresh. A TTL here
would buy nothing while secrets rotate by hand.

The module name is `stash_secrets`, not `secrets`: this package is flat on sys.path and a
module called `secrets.py` would shadow the standard library's `secrets` (which we use for
refresh-token entropy) for every other module in the process.
"""

from __future__ import annotations

import json
import logging
import os

log = logging.getLogger("stash-webhook")

# Set on the box (systemd EnvironmentFile). Unset = pure-environment mode, no AWS calls.
SECRETS_ID_ENV = "STASH_SECRETS_ID"

_blob: dict[str, str] | None = None


def _load_blob() -> dict[str, str]:
    """Fetch the JSON secret once and cache it. A *failed* fetch is deliberately not cached.

    Caching the failure was worse than the outage it was meant to survive: one unreachable
    Secrets Manager call at process start left STASH_JWT_SECRET permanently missing, so
    every authenticated route 503'd until an operator noticed and restarted the units by
    hand. Retrying costs one GetSecretValue per lookup for as long as the outage lasts,
    and the process heals itself the moment the call succeeds.
    """
    global _blob
    if _blob is not None:
        return _blob
    secret_id = os.environ.get(SECRETS_ID_ENV, "")
    if not secret_id:
        _blob = {}
        return _blob
    try:
        from cloud_import_aws import instance_role_session

        raw = instance_role_session().client("secretsmanager").get_secret_value(SecretId=secret_id)
        parsed = json.loads(raw.get("SecretString") or "{}")
    except Exception:  # unreachable / malformed / denied — never take the API down for it
        log.exception("secrets manager load failed for %s", secret_id)
        return {}
    _blob = {str(key): str(value) for key, value in parsed.items()} if isinstance(parsed, dict) else {}
    return _blob


def secret(name: str, default: str = "") -> str:
    value = os.environ.get(name)
    if value:
        return value
    return _load_blob().get(name, default)


def reset_cache() -> None:
    """Drop the cached blob. Test hook only."""
    global _blob
    _blob = None
