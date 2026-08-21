#!/usr/bin/env bash
# Puts TIKTOK_CLIENT_SECRET into the Secrets Manager blob and turns webhook signature
# verification on. Run it from this directory; it prompts for the secret with the echo off,
# so the value never reaches your scrollback, this repo, or an agent transcript.
#
# It MERGES. The blob also holds STASH_JWT_SECRET, GROQ_API_KEY and the Apple trio, and a
# put-secret-value that dropped any of them takes the service down — every authenticated
# route 503s without the JWT key, and DELETE /v1/me can never revoke an Apple grant without
# the Apple three. So the old keys are read back, merged, and asserted present before write.
set -euo pipefail
cd "$(dirname "$0")"

SECRET_ID="${SECRET_ID:-stash-box/app}"
KEY="${KEY:-../../infra/aws-box/stash-box-key.pem}"
IP="${IP:-13.50.196.28}"

# Two ways in, both keeping the value out of scrollback. SECRET_FILE exists so an agent can run
# this end to end without the secret passing through its context: you write the file, it reads
# the path. The file is read once and shredded.
if [ -n "${SECRET_FILE:-}" ]; then
  [ -r "$SECRET_FILE" ] || { echo "cannot read $SECRET_FILE"; exit 1; }
  TIKTOK_CLIENT_SECRET=$(tr -d ' \t\r\n' < "$SECRET_FILE")
else
  read -rsp "TikTok client secret (developers.tiktok.com -> your app -> Basic information): " TIKTOK_CLIENT_SECRET
  echo
fi
[ -n "$TIKTOK_CLIENT_SECRET" ] || { echo "empty — nothing written"; exit 1; }

echo ">>> merging into $SECRET_ID"
merged=$(
  aws secretsmanager get-secret-value --secret-id "$SECRET_ID" --query SecretString --output text \
  | TIKTOK_CLIENT_SECRET="$TIKTOK_CLIENT_SECRET" python3 -c '
import json, os, sys
before = json.load(sys.stdin)
after = dict(before)
after["TIKTOK_CLIENT_SECRET"] = os.environ["TIKTOK_CLIENT_SECRET"]
missing = [k for k in before if k not in after or after[k] != before[k]]
if missing:                       # belt and braces: a merge that lost a key must not be written
    sys.exit("refusing to write, these keys would change: %s" % missing)
print(json.dumps(after))
'
)
# --secret-string is passed on stdin-fed argv here, so keep it out of shell history:
# this script is the only place the value is ever expanded.
aws secretsmanager put-secret-value --secret-id "$SECRET_ID" --secret-string "$merged" >/dev/null
unset merged TIKTOK_CLIENT_SECRET
[ -n "${SECRET_FILE:-}" ] && rm -f -- "$SECRET_FILE" && echo "    $SECRET_FILE removed"
echo "    written"

echo ">>> restarting the service so it re-reads the blob"
ssh -i "$KEY" ubuntu@"$IP" 'sudo systemctl restart stash-webhook && sleep 3 && systemctl is-active stash-webhook'

echo ">>> /health"
curl -fsS https://stash.dmitrijs.dev/health
echo
echo 'Expect "verify":true above. If it still says false, the service read the blob before the'
echo 'write landed — restart once more and re-check.'
