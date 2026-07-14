#!/usr/bin/env bash
# Archive + export + upload the current build to TestFlight, headless, using the
# App Store Connect API key (no Xcode GUI, no password). Signing is cloud-managed
# via -allowProvisioningUpdates, so no local Distribution cert is needed.
#
# Usage:  ISSUER_ID=<your-asc-issuer-id> scripts/release-testflight.sh
# Find the issuer id: App Store Connect -> Users and Access -> Integrations -> App Store Connect API.
set -euo pipefail

ISSUER_ID="${ISSUER_ID:?set ISSUER_ID to your App Store Connect API issuer id}"
KEY_ID="${KEY_ID:-8L6SFDBBSN}"
KEY_PATH="${KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8}"
[ -f "$KEY_PATH" ] || { echo "API key not found at $KEY_PATH" >&2; exit 1; }

cd "$(dirname "$0")/../App"
xcodegen generate

AUTH=(-allowProvisioningUpdates
      -authenticationKeyID "$KEY_ID"
      -authenticationKeyIssuerID "$ISSUER_ID"
      -authenticationKeyPath "$KEY_PATH")

rm -rf build/Stash.xcarchive build/export
xcodebuild -project Stash.xcodeproj -scheme Stash -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/Stash.xcarchive \
  "${AUTH[@]}" archive
xcodebuild -exportArchive -archivePath build/Stash.xcarchive \
  -exportOptionsPlist exportOptions.plist -exportPath build/export "${AUTH[@]}"
xcrun altool --upload-app -f build/export/*.ipa -t ios \
  --apiKey "$KEY_ID" --apiIssuer "$ISSUER_ID"

echo ">>> Uploaded to TestFlight. Processing takes a few minutes; then update Stash on your phone."
