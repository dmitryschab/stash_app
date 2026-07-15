# Stash webhook receiver

FastAPI service that receives TikTok Data Portability "archive ready" webhooks,
verifies the signature, and durably logs each event. Runs as a systemd service on
the AWS box (eu-north-1), bound to `127.0.0.1:8000` behind Caddy, which terminates
TLS and also serves the public site. Live at **https://stash.dmitrijs.dev**
(Let's Encrypt).

## Endpoints
- `GET  /health` — liveness + whether signature verification is on
- `POST /webhook/tiktok` — receives events, verifies HMAC (when a secret is set), logs to `/var/lib/stash-webhook/events.jsonl`, returns 200
- `/v1/*` — the pipeline API (transcript, analyze proxy, keep-offline, Spotify lookup); see `api_v1.py`

## Enable Spotify track links
The app resolves Apple Music from iTunes Search and Tidal from Odesli on its own, but
Odesli returns no Spotify match for an Apple-seeded lookup — so Spotify goes through
Spotify's own Web API, whose client secret can't ship in the app binary. Without these
vars set, `/v1/music/spotify` returns 503 and the app simply shows the other services.

The API is free, but Spotify requires the app owner to hold **Spotify Premium**, and
[since May 2025](https://developer.spotify.com/documentation/web-api/concepts/quota-modes)
only registered organisations with 250k+ MAU can leave Development Mode. That's fine
here: the client-credentials flow authenticates no users, so the 5-user dev-mode cap
never applies — only the rate limit, which one lookup per imported video won't reach.

Create an app at https://developer.spotify.com/dashboard, then on the box:
```sh
sudo tee -a /etc/stash-webhook/env <<'EOF'
SPOTIFY_CLIENT_ID=<from the dashboard>
SPOTIFY_CLIENT_SECRET=<from the dashboard>
EOF
sudo systemctl restart stash-webhook
```
No redirect URI is needed — client-credentials is server-to-server.

## Deploy / redeploy
From this directory:
```sh
KEY=../../infra/aws-box/stash-box-key.pem ; IP=13.50.196.28
ssh -i $KEY ubuntu@$IP 'mkdir -p /tmp/stash-webhook'
scp -i $KEY app.py api_v1.py requirements.txt stash-webhook.service deploy.sh test_app.py ubuntu@$IP:/tmp/stash-webhook/
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
