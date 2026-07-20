# macOS Widget

`Widget/` contains a complete WidgetKit widget (Small / Medium / Large) showing remaining
Claude quota, per-window usage, and reset time. It reads the latest snapshot the menu-bar
app publishes through a shared **App Group** (`SharedSnapshotStore`).

## Build (no Xcode project needed)

`scripts/build-widget.sh` compiles the extension with `swiftc` (against the SwiftPM-built
`ClaudeUsageCore`) and assembles a signed `.appex`. `scripts/build-app.sh` then embeds it
into `ClaudeUsageMonitor.app/Contents/PlugIns/` automatically — so a normal app build
produces the widget too:

```bash
scripts/build-app.sh          # builds the app *and* embeds the widget (if Xcode is present)
```

Requires **full Xcode** (WidgetKit is absent from the Command-Line-Tools SDK); with CLT
only, the embed step is skipped and the app builds without the widget. After installing
the app and launching it once, the widget appears in the desktop / Notification Center
gallery as **“Claude Usage.”**

## Alternative: add it to an Xcode project

## Files
- `Widget/ClaudeUsageWidget.swift` — provider, timeline, and Small/Medium/Large views.
- `Widget/Info.plist` — `NSExtensionPointIdentifier = com.apple.widgetkit-extension`.
- `Widget/ClaudeUsageWidget.entitlements` — sandbox + App Group.
- `packaging/ClaudeUsageMonitor.entitlements` — the **app** side of the same App Group.

## Add it to an Xcode project
1. Create a macOS **App** target from the existing sources (or open the SwiftPM package in
   Xcode and add an app target), then **File ▸ New ▸ Target… ▸ Widget Extension** named
   `ClaudeUsageWidget`. Replace its generated files with those in `Widget/`.
2. Add the **ClaudeUsageCore** package/library as a dependency of **both** the app and the
   widget targets (the widget imports it for `UsageSnapshot` / `SharedSnapshotStore`).
3. **Signing & Capabilities** → add **App Groups** to both targets and enable
   `group.com.jhkoo.claude-usage-monitor`. Point each target at the matching entitlements
   file above.
4. Build & run the app once (it writes the shared snapshot on each refresh and calls
   `WidgetCenter.shared.reloadAllTimelines()`), then add the widget from the desktop /
   Notification Center gallery.

## Requirements & limitations
- App Groups are honored by the sandbox only for **properly signed** apps (a Developer ID
  or development team). With ad-hoc signing the shared container may not be created, so the
  widget can show its placeholder until you sign with a real identity. See
  [`docs/SIGNING.md`](SIGNING.md).
- The app already publishes data for the widget unconditionally; no app code changes are
  needed to adopt the widget beyond the Xcode target + App Group setup above.
