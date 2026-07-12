#!/usr/bin/env bash
# Runs ON the box (copied to /tmp/stash-webhook, invoked over SSH). Idempotent.
set -euo pipefail
cd "$(dirname "$0")"

echo ">>> system deps"
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3-venv python3-pip >/dev/null

id stash >/dev/null 2>&1 || sudo useradd --system --home-dir /opt/stash-webhook --shell /usr/sbin/nologin stash
sudo mkdir -p /opt/stash-webhook
sudo cp app.py /opt/stash-webhook/app.py

[ -d /opt/stash-webhook/venv ] || sudo python3 -m venv /opt/stash-webhook/venv
sudo /opt/stash-webhook/venv/bin/pip install --quiet --upgrade pip
sudo /opt/stash-webhook/venv/bin/pip install --quiet -r requirements.txt

echo ">>> self-check"
sudo /opt/stash-webhook/venv/bin/python test_app.py

sudo chown -R stash:stash /opt/stash-webhook
sudo cp stash-webhook.service /etc/systemd/system/stash-webhook.service
sudo systemctl daemon-reload
sudo systemctl enable --now stash-webhook
sleep 2

echo ">>> status"
sudo systemctl is-active stash-webhook
curl -fsS http://127.0.0.1/health && echo
