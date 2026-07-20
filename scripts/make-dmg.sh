#!/usr/bin/env bash
#
# Builds the .app and packages it into a compressed, drag-to-install DMG.
# Output: dist/ClaudeUsageMonitor-<version>.dmg
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="ClaudeUsageMonitor"
VERSION="${VERSION:-0.2.0}"
DIST="$REPO_DIR/dist"
APP="$DIST/$APP_NAME.app"
DMG="$DIST/$APP_NAME-$VERSION.dmg"
VOL="Claude Usage Monitor"

echo "› Building app…"
VERSION="$VERSION" bash "$REPO_DIR/scripts/build-app.sh" >/dev/null

echo "› Staging DMG contents…"
STAGE="$(mktemp -d)/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"   # drag-to-install target

echo "› Creating DMG…"
rm -f "$DMG"
hdiutil create -volname "$VOL" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

SIZE="$(du -h "$DMG" | cut -f1 | tr -d ' ')"
echo "✓ Built $DMG ($SIZE)"
