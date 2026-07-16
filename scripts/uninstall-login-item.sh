#!/usr/bin/env bash
#
# Removes the Claude Usage Monitor Launch Agent and stops the running instance.
set -euo pipefail

APP_NAME="ClaudeUsageMonitor"
LABEL="com.jhkoo.claude-usage-monitor"
INSTALL_DIR="$HOME/Library/Application Support/ClaudeUsageMonitor"
BIN="$INSTALL_DIR/$APP_NAME"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

echo "› Unloading Launch Agent"
launchctl unload "$PLIST" 2>/dev/null || true
pkill -f "$BIN" 2>/dev/null || true

echo "› Removing files"
rm -f "$PLIST"
rm -rf "$INSTALL_DIR"

echo "✓ Uninstalled. Claude Usage Monitor will no longer launch at login."
