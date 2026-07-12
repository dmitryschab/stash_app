#!/bin/sh
# Generates App/Sources/Generated/BoxToken.swift from the gitignored secrets file.
cd "$(dirname "$0")/.."
TOKEN=$(grep '^stash_api_token=' secrets | cut -d= -f2)
[ -z "$TOKEN" ] && { echo "no stash_api_token in secrets"; exit 1; }
mkdir -p App/Sources/Generated
cat > App/Sources/Generated/BoxToken.swift <<SWIFT
// GENERATED from the repo-root 'secrets' file — gitignored, never commit.
// Regenerate: ./scripts/gen-box-token.sh
enum BoxToken {
    static let value = "$TOKEN"
}
SWIFT
echo "BoxToken.swift generated"
