# Stash webhook receiver

FastAPI service that receives TikTok Data Portability "archive ready" webhooks,
verifies the signature, and durably logs each event. Runs as a systemd service on
the AWS box (eu-north-1), bound to `127.0.0.1:8000` behind Caddy, which terminates
TLS and also serves the public site. Live at **https://stash.dmitrijs.dev**
(Let's Encrypt).

## Endpoints
Only `/health`, `/webhook/tiktok` and `/v1/auth/*` are reachable without a per-user
Stash JWT. Everything else resolves the caller through `stash_auth.current_user` and
answers 401 without one; there is no shared bearer token.

- `GET  /health` — liveness, dependency reachability, and whether signature verification is on
- `POST /webhook/tiktok` — receives events, verifies HMAC (fail-closed), logs to `/var/lib/stash-webhook/events.jsonl`, returns 200
- `POST /v1/auth/apple` — Sign in with Apple; open to anyone, a code is optional
- `POST /v1/auth/refresh` — rotates a refresh token for a new session
- `GET  /v1/me`, `DELETE /v1/me`, `GET /v1/me/export` — account, erasure, data export
- `POST /v1/imports` — accepts up to 1200 normalized bookmarks (a whole library) and returns immediately with an import ID; the box processes them in the background
- `GET  /v1/imports/{id}` — cloud-import progress
- `GET  /v1/imports/{id}/results` — paginated compact results
- `POST /v1/videos/transcript` — direct transcript endpoint (quota-metered)
- `POST /v1/chat/completions` — analysis proxy
- `GET  /v1/tiktok/download/{id}` — transient mp4 bytes for the visual-text backfill (quota-metered)

## Invite codes
No longer a gate — sign-up is open and the App Store price is what limits who arrives.
A code's only remaining job is `--demo`, which stamps `demo: true` on the account it
creates so App Review lands in a seeded library. Minted on the box, never over HTTP:
```sh
sudo bash -c 'set -a; . /etc/stash-webhook/env; set +a; \
  /opt/stash-webhook/venv/bin/python /opt/stash-webhook/manage_invites.py mint --uses 1'
sudo bash -c 'set -a; . /etc/stash-webhook/env; set +a; \
  /opt/stash-webhook/venv/bin/python /opt/stash-webhook/manage_invites.py list'
```

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
The client secret is NOT stored in this repo. It belongs in the Secrets Manager blob
alongside the other credentials, not in the env file — that file now also carries the
table/queue/secret-id settings, so a `tee` over it takes the service down:
```sh
./set-tiktok-secret.sh   # prompts with echo off, merges, restarts, prints /health
```
Use the script rather than a hand-written `put-secret-value`. The blob holds five other
keys — `STASH_JWT_SECRET`, `GROQ_API_KEY` and the Apple trio — and `put-secret-value`
**replaces** the whole thing, so spelling out a three-key JSON silently deletes the Apple
credentials. The service then still starts, still signs people in, and only fails when
`DELETE /v1/me` cannot revoke an Apple grant — a 5.1.1(v) rejection you find in review.
The script reads the current blob, adds one key, asserts nothing else moved, then writes.

Until a secret is set the webhook is fail-closed: it rejects every event with 401
unless `STASH_DEV_MODE=1` is explicitly present.

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

The environment file is server-side only and must contain `STASH_IMPORT_TABLE`,
`STASH_IMPORT_QUEUE_URL`, `AWS_REGION`, and `STASH_SECRETS_ID` (the `app_secret_id`
Terraform output). The Terraform outputs provide the table name and queue URL after
infrastructure approval. The worker does not store raw exports, captions, transcripts,
or permanent audio.

Credentials themselves live in that one Secrets Manager blob, not in the environment
file: `STASH_JWT_SECRET` (required — `deploy.sh` refuses to install without it),
`GROQ_API_KEY`, `TIKTOK_CLIENT_SECRET`, and the optional `APPLE_TEAM_ID` /
`APPLE_KEY_ID` / `APPLE_PRIVATE_KEY` used by `DELETE /v1/me` to revoke with Apple.
Rotation is a `put-secret-value` followed by
`sudo systemctl restart stash-webhook stash-import-worker` — the blob is read once
per process.

The local smoke gate reads `STASH_BASE_URL`, `STASH_JWT` (a session token from
`POST /v1/auth/apple`, not a shared token), and a path in
`STASH_IMPORT_BOOKMARKS_FILE` (or a positional JSON file), then submits exactly 50
normalized bookmarks and polls until 50 unique results are returned:

```sh
python smoke_cloud_import.py
```
