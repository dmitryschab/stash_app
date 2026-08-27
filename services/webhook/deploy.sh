#!/usr/bin/env bash
# Runs ON the box (copied to /tmp/stash-webhook, invoked over SSH). Idempotent.
set -euo pipefail
cd "$(dirname "$0")"

echo ">>> system deps"
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ffmpeg python3-venv python3-pip >/dev/null

id stash >/dev/null 2>&1 || sudo useradd --system --home-dir /opt/stash-webhook --shell /usr/sbin/nologin stash
sudo mkdir -p /opt/stash-webhook
sudo cp -- *.py /opt/stash-webhook/
sudo cp -- requirements.txt stash-webhook.service stash-import-worker.service /opt/stash-webhook/
# Not a .py, so the glob above misses it: stash_subscription.py reads this cert from its own
# directory to verify StoreKit's signed blobs. Without it every receipt fails to verify and
# the paywall locks out everyone who has paid.
sudo cp -- AppleRootCA-G3.cer /opt/stash-webhook/

[ -d /opt/stash-webhook/venv ] || sudo python3 -m venv /opt/stash-webhook/venv
sudo /opt/stash-webhook/venv/bin/pip install --quiet --upgrade pip
sudo /opt/stash-webhook/venv/bin/pip install --quiet -r requirements.txt
# yt-dlp is the one dependency that must float upward: TikTok changes its page every few weeks
# and a stale extractor returns no metadata at all, which this pipeline records as "unavailable"
# for every video in the import. `-r requirements.txt` leaves an already-installed unpinned
# package alone, so without this the box silently rots between deploys.
sudo /opt/stash-webhook/venv/bin/pip install --quiet --upgrade yt-dlp

echo ">>> self-check"
cd /opt/stash-webhook
# pytest now covers the signature path too, so test_app.py is no longer invoked directly.
sudo /opt/stash-webhook/venv/bin/python -m pytest -q
sudo /opt/stash-webhook/venv/bin/python api_v1.py
cd -

# Fail the deploy rather than serve traffic with no session-signing key: without it every
# authenticated route 503s, which is a much slower thing to discover from the app. The Apple
# trio is on the same list for the same reason one step later: without it `exchange_apple_code`
# stores no refresh token, so DELETE /v1/me can never revoke the Sign in with Apple grant and
# the app stays listed under Settings → Apple ID — an App Store 5.1.1(v) rejection that only
# shows up in review. Reads the systemd EnvironmentFile itself — that file is root-only and
# the deploy shell has neither it nor STASH_SECRETS_ID in its environment.
echo ">>> secret check"
sudo /opt/stash-webhook/venv/bin/python - <<'PY'
import os, sys
sys.path.insert(0, "/opt/stash-webhook")
try:
    with open("/etc/stash-webhook/env") as handle:
        for line in handle:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                name, _, value = line.partition("=")
                os.environ.setdefault(name.strip(), value.strip().strip('"').strip("'"))
except FileNotFoundError:
    pass
import stash_secrets
required = ("STASH_JWT_SECRET", "APPLE_TEAM_ID", "APPLE_KEY_ID", "APPLE_PRIVATE_KEY")
missing = [name for name in required if not stash_secrets.secret(name)]
if missing:
    sys.exit(f"missing required secret(s): {', '.join(missing)} — put them in AWS Secrets "
             "Manager (STASH_SECRETS_ID) or /etc/stash-webhook/env, then redeploy")
print("secrets present")
PY

sudo chown -R stash:stash /opt/stash-webhook
sudo cp stash-webhook.service /etc/systemd/system/stash-webhook.service
sudo cp stash-import-worker.service /etc/systemd/system/stash-import-worker.service
sudo systemctl daemon-reload
sudo systemctl enable stash-webhook stash-import-worker
sudo systemctl restart stash-webhook stash-import-worker
sleep 2

echo ">>> status"
sudo systemctl is-active stash-webhook
curl -fsS http://127.0.0.1/health && echo
