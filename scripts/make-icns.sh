#!/usr/bin/env bash
# Renders the app icon PNGs and compiles them into Resources/AppIcon.icns.
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)/AppIcon.iconset"
OUT="$REPO_DIR/Resources/AppIcon.icns"

mkdir -p "$REPO_DIR/Resources"
swift "$REPO_DIR/scripts/make-icon.swift" "$WORK"
iconutil -c icns "$WORK" -o "$OUT"
echo "✓ Wrote $OUT"
