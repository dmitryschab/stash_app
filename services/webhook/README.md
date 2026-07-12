# Stash webhook receiver

FastAPI service that receives TikTok Data Portability "archive ready" webhooks,
verifies the signature, and durably logs each event. Runs as a systemd service on
the AWS box (eu-north-1), bound to `127.0.0.1:8000` behind Caddy, which terminates
TLS and also serves the public site. Live at **https://stash.dmitrijs.dev**
(Let's Encrypt).

## Endpoints
- `GET  /health` — liveness + whether signature verification is on
- `POST /webhook/tiktok` — receives events, verifies HMAC (when a secret is set), logs to `/var/lib/stash-webhook/events.jsonl`, returns 200
- `POST /v1/imports` — authenticated, accepts up to 50 normalized bookmarks and returns immediately with an import ID
- `GET  /v1/imports/{id}` — authenticated cloud-import progress
- `GET  /v1/imports/{id}/results` — authenticated paginated compact results
- `POST /v1/videos/transcript` — existing direct transcript endpoint
- `POST /v1/chat/completions` — existing analysis proxy
- `GET  /v1/tiktok/download/{id}` — existing keep-offline endpoint

## Deploy / redeploy
From this directory:
```sh
KEY=../../infra/aws-box/stash-box-key.pem ; IP=13.50.196.28
ssh -i $KEY ubuntu@$IP 'mkdir -p /tmp/stash-webhook'
scp -i $KEY *.py *.service requirements.txt deploy.sh ubuntu@$IP:/tmp/stash-webhook/
ssh -i $KEY ubuntu@$IP 'bash /tmp/stash-webhook/deploy.sh'
```
`deploy.sh` is idempotent, runs the backend tests and self-checks, and installs both the API and independent import worker services.

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
sudo systemctl status stash-import-worker
sudo journalctl -u stash-import-worker -f
```

## Serving (current)
Caddy (`/etc/caddy/Caddyfile`) terminates TLS for `stash.dmitrijs.dev`, proxies `/webhook/*` and `/health` to `127.0.0.1:8000`, and file-serves the static site (`site/` → `/var/www/stash`). Public pages: `/` (landing), `/privacy`, `/terms`.

## Cloud import worker configuration

The environment file is server-side only and must contain `STASH_API_TOKEN`,
`STASH_IMPORT_TABLE`, `STASH_IMPORT_QUEUE_URL`, and `AWS_REGION` in addition to
any existing webhook/provider settings. The Terraform outputs provide the table
name and queue URL after infrastructure approval. The worker does not store raw
exports, captions, transcripts, or permanent audio.

The local smoke gate reads `STASH_BASE_URL`, `STASH_API_TOKEN`, and a path in
`STASH_IMPORT_BOOKMARKS_FILE` (or a positional JSON file), then submits exactly 50
normalized bookmarks and polls until 50 unique results are returned:

```sh
python smoke_cloud_import.py
```
