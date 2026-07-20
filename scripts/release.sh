#!/usr/bin/env bash
#
# One-shot signed + notarized release build:
#   build .app (Developer ID, hardened runtime) → DMG → notarize → staple.
#
# Env:
#   SIGN_IDENTITY   "Developer ID Application: Your Name (TEAMID)"  (required)
#   NOTARY_PROFILE  stored notarytool profile   (default: claude-usage-monitor-notary)
#   VERSION         release version             (default: 0.2.0)
#   SKIP_NOTARIZE   set to 1 to sign only (no notarization)
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:-0.2.0}"
DMG="$REPO_DIR/dist/ClaudeUsageMonitor-$VERSION.dmg"

if [ "${SIGN_IDENTITY:--}" = "-" ]; then
    echo "✗ SIGN_IDENTITY is required for a release build (Developer ID)." >&2
    echo '  e.g. SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/release.sh' >&2
    exit 1
fi

echo "=== Building signed DMG ($VERSION) ==="
VERSION="$VERSION" bash "$REPO_DIR/scripts/make-dmg.sh"

if [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
    echo "⚠︎ SKIP_NOTARIZE=1 — signed but NOT notarized."
    exit 0
fi

echo "=== Notarizing ==="
bash "$REPO_DIR/scripts/notarize.sh" "$DMG"

echo "✓ Release artifact ready: $DMG"
echo "  Attach to a GitHub release, or:  gh release upload vX.Y.Z \"$DMG\""
