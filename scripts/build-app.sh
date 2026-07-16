#!/usr/bin/env bash
#
# Assembles a distributable ClaudeUsageMonitor.app bundle from the SPM release build,
# embeds the icon + Info.plist, and ad-hoc code-signs it.
#
# Env overrides:  VERSION (default 0.1.0)   SIGN_IDENTITY (default "-" = ad-hoc)
#
# Output: dist/ClaudeUsageMonitor.app
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="ClaudeUsageMonitor"
VERSION="${VERSION:-0.1.0}"
BUILD="$(git -C "$REPO_DIR" rev-list --count HEAD 2>/dev/null || echo 1)"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

DIST="$REPO_DIR/dist"
APP="$DIST/$APP_NAME.app"
CONTENTS="$APP/Contents"

echo "› Building release binary ($APP_NAME $VERSION build $BUILD)…"
swift build -c release --product "$APP_NAME" --package-path "$REPO_DIR" >/dev/null
BIN="$(swift build -c release --product "$APP_NAME" --package-path "$REPO_DIR" --show-bin-path)/$APP_NAME"

echo "› Ensuring app icon exists…"
[ -f "$REPO_DIR/Resources/AppIcon.icns" ] || bash "$REPO_DIR/scripts/make-icns.sh"

echo "› Assembling bundle…"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN" "$CONTENTS/MacOS/$APP_NAME"
chmod +x "$CONTENTS/MacOS/$APP_NAME"
cp "$REPO_DIR/Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
sed -e "s/@VERSION@/$VERSION/" -e "s/@BUILD@/$BUILD/" \
    "$REPO_DIR/packaging/Info.plist" > "$CONTENTS/Info.plist"
printf 'APPL????' > "$CONTENTS/PkgInfo"

echo "› Code signing (identity: $SIGN_IDENTITY)…"
codesign --force --sign "$SIGN_IDENTITY" \
    --identifier com.jhkoo.claude-usage-monitor \
    --timestamp=none "$CONTENTS/MacOS/$APP_NAME"
codesign --force --sign "$SIGN_IDENTITY" \
    --identifier com.jhkoo.claude-usage-monitor \
    --timestamp=none "$APP"
codesign --verify --deep --strict --verbose=1 "$APP" 2>&1 | sed 's/^/  /' || true

echo "✓ Built $APP"
