#!/usr/bin/env bash
#
# Installs Claude Usage Monitor as a per-user Launch Agent so it starts
# automatically every time you log in (the correct trigger for a menu-bar app —
# GUI agents run in the Aqua session, not before login).
#
# Idempotent: safe to re-run to update the installed binary.
set -euo pipefail

APP_NAME="ClaudeUsageMonitor"
LABEL="com.jhkoo.claude-usage-monitor"
INSTALL_DIR="$HOME/Library/Application Support/ClaudeUsageMonitor"
BIN="$INSTALL_DIR/$APP_NAME"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "› Building release binary…"
swift build -c release --product "$APP_NAME" --package-path "$REPO_DIR" >/dev/null
RELEASE_BIN="$(swift build -c release --product "$APP_NAME" --package-path "$REPO_DIR" --show-bin-path)/$APP_NAME"

echo "› Installing to $BIN"
mkdir -p "$INSTALL_DIR"
# Stop any running instance (installed or dev) before replacing the binary.
launchctl unload "$PLIST" 2>/dev/null || true
pkill -f "$BIN" 2>/dev/null || true
cp -f "$RELEASE_BIN" "$BIN"
chmod +x "$BIN"

echo "› Writing Launch Agent $PLIST"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
</dict>
</plist>
EOF

echo "› Loading Launch Agent"
launchctl load -w "$PLIST"

echo "✓ Installed. Claude Usage Monitor will now launch automatically at login."
echo "  It has also been started now — look for it in the menu bar."
echo "  (First run may ask to authorize Keychain access — click 'Always Allow'.)"
echo "  To remove: scripts/uninstall-login-item.sh"
