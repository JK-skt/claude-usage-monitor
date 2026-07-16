#!/usr/bin/env bash
#
# Notarizes and staples a signed artifact (DMG, ZIP, or PKG).
#
# Prerequisites:
#   1. The artifact must already be signed with a Developer ID identity using a
#      hardened runtime (scripts/build-app.sh with SIGN_IDENTITY set).
#   2. A stored notarytool credential profile (one-time):
#        xcrun notarytool store-credentials "$NOTARY_PROFILE" \
#          --apple-id "you@example.com" --team-id "TEAMID" \
#          --password "app-specific-password"
#
# Env:  NOTARY_PROFILE (default: claude-usage-monitor-notary)
# Usage: scripts/notarize.sh dist/ClaudeUsageMonitor-0.1.0.dmg
set -euo pipefail

TARGET="${1:?usage: notarize.sh <path-to-signed-dmg|zip|pkg>}"
PROFILE="${NOTARY_PROFILE:-claude-usage-monitor-notary}"

[ -e "$TARGET" ] || { echo "✗ Not found: $TARGET" >&2; exit 1; }

echo "› Submitting to Apple notary service (this can take a few minutes)…"
xcrun notarytool submit "$TARGET" --keychain-profile "$PROFILE" --wait

echo "› Stapling the notarization ticket…"
xcrun stapler staple "$TARGET"
xcrun stapler validate "$TARGET"

echo "› Gatekeeper assessment:"
if [[ "$TARGET" == *.dmg ]]; then
    spctl -a -t open --context context:primary-signature -vv "$TARGET" || true
else
    spctl -a -vv "$TARGET" || true
fi

echo "✓ Notarized and stapled: $TARGET"
