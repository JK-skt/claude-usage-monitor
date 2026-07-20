# Homebrew Cask for Claude Usage Monitor.
#
# Personal tap usage:
#   brew tap JK-skt/tap https://github.com/JK-skt/claude-usage-monitor
#   brew install --cask claude-usage-monitor
#
# The DMG is currently ad-hoc signed (unnotarized), so the cask uses `sha256 :no_check`
# and disables quarantine. Once releases are Developer ID signed + notarized, pin the
# real checksum here (`shasum -a 256 <dmg>`) and drop `no_quarantine`.
cask "claude-usage-monitor" do
  version "0.4.0"
  sha256 :no_check

  url "https://github.com/JK-skt/claude-usage-monitor/releases/download/v#{version}/ClaudeUsageMonitor-#{version}.dmg"
  name "Claude Usage Monitor"
  desc "Menu-bar app showing live Claude usage from your local Claude Code session"
  homepage "https://github.com/JK-skt/claude-usage-monitor"

  depends_on macos: ">= :sonoma"

  app "ClaudeUsageMonitor.app"

  # Ad-hoc build: skip Gatekeeper quarantine so it launches without a right-click.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/ClaudeUsageMonitor.app"],
                   sudo: false
  end

  uninstall quit: "com.jhkoo.claude-usage-monitor"

  zap trash: [
    "~/Library/Application Support/ClaudeUsageMonitor",
    "~/Library/LaunchAgents/com.jhkoo.claude-usage-monitor.plist",
  ]
end
