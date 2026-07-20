#!/usr/bin/env bash
#
# Assembles a distributable ClaudeUsageMonitor.app bundle from the SPM release build,
# embeds the icon + Info.plist, and ad-hoc code-signs it.
#
# Env overrides:  VERSION (default 0.2.0)   SIGN_IDENTITY (default "-" = ad-hoc)
#
# Output: dist/ClaudeUsageMonitor.app
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="ClaudeUsageMonitor"
VERSION="${VERSION:-0.2.0}"
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

# Embed the WidgetKit extension when the toolchain can build it (full Xcode present —
# WidgetKit is absent from the Command Line Tools SDK, in which case this is skipped).
if [ -f "$REPO_DIR/Widget/ClaudeUsageWidget.swift" ]; then
    if VERSION="$VERSION" SIGN_IDENTITY="$SIGN_IDENTITY" bash "$REPO_DIR/scripts/build-widget.sh" >/tmp/widget-build.log 2>&1; then
        echo "› Embedding widget extension (PlugIns/)…"
        mkdir -p "$CONTENTS/PlugIns"
        rm -rf "$CONTENTS/PlugIns/ClaudeUsageWidget.appex"
        cp -R "$DIST/ClaudeUsageWidget.appex" "$CONTENTS/PlugIns/"
    else
        echo "› Widget not embedded (WidgetKit unavailable — see /tmp/widget-build.log)"
    fi
fi

# Signing flags differ for ad-hoc vs Developer ID (notarization needs hardened
# runtime + a secure timestamp).
BUNDLE_ID="com.jhkoo.claude-usage-monitor"
if [ "$SIGN_IDENTITY" = "-" ]; then
    echo "› Code signing (ad-hoc — unnotarized; Gatekeeper will warn)…"
    CS_FLAGS=(--force --sign - --identifier "$BUNDLE_ID" --timestamp=none)
else
    if ! security find-identity -v -p codesigning | grep -qF "$SIGN_IDENTITY"; then
        echo "✗ Signing identity not found in keychain: $SIGN_IDENTITY" >&2
        echo "  Available code-signing identities:" >&2
        security find-identity -v -p codesigning >&2
        exit 1
    fi
    echo "› Code signing (Developer ID + hardened runtime): $SIGN_IDENTITY"
    CS_FLAGS=(--force --options runtime --timestamp --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID")
    # App Group entitlement (enables the widget's shared container) — only meaningful with
    # a real signing identity.
    ENTITLEMENTS="$REPO_DIR/packaging/ClaudeUsageMonitor.entitlements"
    if [ -f "$ENTITLEMENTS" ]; then
        CS_FLAGS+=(--entitlements "$ENTITLEMENTS")
    fi
fi

# Sign inner Mach-O first, then the bundle.
codesign "${CS_FLAGS[@]}" "$CONTENTS/MacOS/$APP_NAME"
codesign "${CS_FLAGS[@]}" "$APP"
codesign --verify --strict --verbose=2 "$APP" 2>&1 | sed 's/^/  /' || true

echo "✓ Built $APP"
