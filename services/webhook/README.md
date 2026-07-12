# Stash webhook receiver

FastAPI service that receives TikTok Data Portability "archive ready" webhooks,
verifies the signature, and durably logs each event. Runs as a systemd service on
the AWS box (eu-north-1), bound to `127.0.0.1:8000` behind Caddy, which terminates
TLS and also serves the public site. Live at **https://stash.dmitrijs.dev**
(Let's Encrypt).

## Endpoints
- `GET  /health` — liveness + whether signature verification is on
- `POST /webhook/tiktok` — receives events, verifies HMAC (when a secret is set), logs to `/var/lib/stash-webhook/events.jsonl`, returns 200

## Deploy / redeploy
From this directory:
```sh
KEY=../../infra/aws-box/stash-box-key.pem ; IP=13.50.196.28
ssh -i $KEY ubuntu@$IP 'mkdir -p /tmp/stash-webhook'
scp -i $KEY app.py requirements.txt stash-webhook.service deploy.sh test_app.py ubuntu@$IP:/tmp/stash-webhook/
ssh -i $KEY ubuntu@$IP 'bash /tmp/stash-webhook/deploy.sh'
```
`deploy.sh` is idempotent and runs the signature self-check before installing.

## Enable signature verification (do this before going live)
The client secret is NOT stored in this repo. On the box:
```sh
sudo install -d /etc/stash-webhook
echo 'TIKTOK_CLIENT_SECRET=<from TikTok developer portal>' | sudo tee /etc/stash-webhook/env
sudo systemctl restart stash-webhook   # /health then shows "verify": true
```

## Service management
```sh
sudo systemctl status stash-webhook
sudo journalctl -u stash-webhook -f
```

## Serving (current)
Caddy (`/etc/caddy/Caddyfile`) terminates TLS for `stash.dmitrijs.dev`, proxies `/webhook/*` and `/health` to `127.0.0.1:8000`, and file-serves the static site (`site/` → `/var/www/stash`). Public pages: `/` (landing), `/privacy`, `/terms`.

## Still to do
- **Client secret:** set `TIKTOK_CLIENT_SECRET` on the box (see above) to turn on signature verification before going live.
- **Archive worker:** download the archive from the event, extract only Favourite Videos, hand off to the pipeline. Built once the API is approved and a real payload is available.
