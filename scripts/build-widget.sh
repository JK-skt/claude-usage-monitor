#!/usr/bin/env bash
#
# Compiles the WidgetKit extension and assembles it as a .appex bundle, using the
# Xcode toolchain directly (no Xcode project needed). The result is embedded into the
# app bundle by build-app.sh when Xcode is available.
#
# Output: dist/ClaudeUsageWidget.appex
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EXT_NAME="ClaudeUsageWidget"
BUNDLE_ID="com.jhkoo.claude-usage-monitor.widget"
VERSION="${VERSION:-0.2.0}"
BUILD="$(git -C "$REPO_DIR" rev-list --count HEAD 2>/dev/null || echo 1)"
TARGET="arm64-apple-macos14.0"

DIST="$REPO_DIR/dist"
APPEX="$DIST/$EXT_NAME.appex"
CONTENTS="$APPEX/Contents"

echo "› Building ClaudeUsageCore (release)…"
swift build -c release --product claude-monitor --package-path "$REPO_DIR" >/dev/null
BIN="$(swift build -c release --package-path "$REPO_DIR" --show-bin-path)"

echo "› Compiling widget extension…"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
swiftc "$REPO_DIR/Widget/$EXT_NAME.swift" \
    -I "$BIN/Modules" \
    "$BIN/ClaudeUsageCore.build/"*.o \
    -framework WidgetKit -framework SwiftUI \
    -target "$TARGET" \
    -parse-as-library -O \
    -o "$CONTENTS/MacOS/$EXT_NAME"

echo "› Assembling .appex bundle…"
sed -e "s/@VERSION@/$VERSION/" -e "s/@BUILD@/$BUILD/" \
    "$REPO_DIR/Widget/Info.plist" > "$CONTENTS/Info.plist" 2>/dev/null \
    || cp "$REPO_DIR/Widget/Info.plist" "$CONTENTS/Info.plist"
# Ensure the executable name is present in Info.plist.
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $EXT_NAME" "$CONTENTS/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string $EXT_NAME" "$CONTENTS/Info.plist"
printf 'XPC!????' > "$CONTENTS/PkgInfo"

# Sign (Developer ID if provided + App Group entitlement, else ad-hoc).
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
ENT="$REPO_DIR/Widget/$EXT_NAME.entitlements"
if [ "$SIGN_IDENTITY" = "-" ]; then
    echo "› Signing widget (ad-hoc + sandbox entitlement)…"
    # Widgets must be sandboxed for the system to register them; apply the entitlement
    # even ad-hoc. (The App Group container itself only works once properly signed.)
    codesign --force --sign - --identifier "$BUNDLE_ID" --entitlements "$ENT" --timestamp=none "$CONTENTS/MacOS/$EXT_NAME"
    codesign --force --sign - --identifier "$BUNDLE_ID" --entitlements "$ENT" --timestamp=none "$APPEX"
else
    echo "› Signing widget (Developer ID + App Group): $SIGN_IDENTITY"
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" \
        --identifier "$BUNDLE_ID" --entitlements "$ENT" "$CONTENTS/MacOS/$EXT_NAME"
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" \
        --identifier "$BUNDLE_ID" --entitlements "$ENT" "$APPEX"
fi

codesign --verify --strict --verbose=1 "$APPEX" 2>&1 | sed 's/^/  /' || true
echo "✓ Built $APPEX"
