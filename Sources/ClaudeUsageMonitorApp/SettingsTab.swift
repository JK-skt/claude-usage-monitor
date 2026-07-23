import SwiftUI
import AppKit
import ClaudeUsageCore

/// Settings tab — the former accordion, reorganized into four labelled groups
/// (handoff §03) with About pinned at the bottom.
struct SettingsTab: View {
    @ObservedObject var model: MenuBarViewModel
    @ObservedObject var updates: UpdateManager
    @ObservedObject var loginItem: LoginItemManager
    @State private var loginError: String?

    private let intervals: [(String, TimeInterval)] = [
        ("1m", 60), ("5m", 300), ("10m", 600), ("15m", 900), ("30m", 1800),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            general
            Divider()
            display
            Divider()
            notifications
            Divider()
            updatesGroup
            Divider()
            about
        }
    }

    // MARK: Groups

    private var general: some View {
        group("GENERAL") {
            toggleRow("Launch at login", isOn: Binding(
                get: { loginItem.isEnabled },
                set: { loginError = loginItem.setEnabled($0) }
            ))

            if loginItem.needsApproval {
                Text("Approve in System Settings › Login Items")
                    .font(.caption2).foregroundStyle(.orange)
            }
            if let loginError {
                Text(loginError).font(.caption2).foregroundStyle(.red)
            }

            HStack {
                Text("Refresh every").font(.system(size: 11.5))
                Spacer(minLength: 8)
                chipGroup(intervals, selection: model.refreshInterval) { model.refreshInterval = $0 }
            }
        }
    }

    private var display: some View {
        group("DISPLAY") {
            HStack {
                HStack(spacing: 4) {
                    Text("Main usage").font(.system(size: 11.5))
                    Text("drives menu bar %").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                Spacer()
                Picker("", selection: $model.headlineMetricID) {
                    ForEach(headlineOptions, id: \.id) { opt in
                        Text(opt.label).tag(opt.id)
                    }
                }
                .labelsHidden().controlSize(.small).frame(width: 150)
            }
            toggleRow("Show all details", isOn: $model.detailed)
            toggleRow("Detailed usage analytics", isOn: $model.analyticsEnabled)
        }
    }

    private var notifications: some View {
        group("NOTIFICATIONS") {
            toggleRow("Low-usage alerts", caption: "at 20 / 10 / 5 / 1% + reset",
                      isOn: Binding(get: { model.notificationsEnabled },
                                    set: { model.notificationsEnabled = $0 }))
        }
    }

    private var updatesGroup: some View {
        group("UPDATES") {
            toggleRow("Check for updates", isOn: $updates.autoCheck)
            toggleRow("Install automatically", isOn: $updates.autoInstall,
                      disabled: !updates.autoCheck)
            HStack {
                Button {
                    Task { await updates.check(userInitiated: true) }
                } label: {
                    HStack(spacing: 4) {
                        if updates.isChecking { ProgressView().controlSize(.mini) }
                        Text("Check now").font(.callout)
                    }
                }
                .controlSize(.small)
                Spacer()
                if let checked = updates.lastChecked {
                    Text("checked \(agoText(checked))")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            if updates.available == nil, updates.lastChecked != nil, !updates.isChecking {
                Text("Up to date — \(appVersionText)")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            if let err = updates.lastError {
                Text(err).font(.caption2).foregroundStyle(.red)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 3) {
            row("Version", appVersionText)
            row("License", licenseText)
            HStack {
                Text("Source").font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
                Button("github.com/JK-skt/claude-usage-monitor") {
                    if let url = URL(string: "https://github.com/JK-skt/claude-usage-monitor") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link).font(.system(size: 10))
            }
        }
    }

    /// Label left, switch pinned right — matching the prototype. A bare `Toggle` puts the
    /// switch immediately after its label, which reads as broken alignment.
    private func toggleRow(_ title: String, caption: String? = nil,
                           isOn: Binding<Bool>, disabled: Bool = false) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.system(size: 11.5))
            if let caption {
                Text(caption).font(.system(size: 10)).foregroundStyle(.tertiary)
                    .lineLimit(1).minimumScaleFactor(0.85)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                .disabled(disabled)
        }
        .opacity(disabled ? 0.45 : 1)
    }

    /// Segmented chips grouped in a single rounded container.
    private func chipGroup<T: Hashable>(_ items: [(String, T)], selection: T,
                                        onSelect: @escaping (T) -> Void) -> some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.1) { label, value in
                Button(label) { onSelect(value) }
                    .buttonStyle(MiniSegmentStyle(selected: selection == value))
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: Building blocks

    private func group<Content: View>(_ title: String,
                                      @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 9, weight: .bold)).tracking(0.8).foregroundStyle(.tertiary)
            content()
        }
    }

    private func row(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(key).font(.system(size: 10)).foregroundStyle(.tertiary)
            Spacer()
            Text(value).font(.system(size: 10)).foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var headlineOptions: [(id: String, label: String)] {
        var opts: [(id: String, label: String)] = [("", "Most used (auto)")]
        if case .loaded(let s) = model.state {
            opts += s.metrics.filter { $0.hasQuota }.map { ($0.id, $0.label) }
        } else if !model.headlineMetricID.isEmpty {
            opts.append((model.headlineMetricID, model.headlineMetricID))
        }
        return opts
    }

    private var appVersionText: String {
        guard AppVersion.isBundledApp else { return "dev (unbundled)" }
        let v = AppVersion.current
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        return build.map { "\(v) (build \($0))" } ?? v
    }

    private var licenseText: String {
        "MIT · unofficial, not affiliated with Anthropic"
    }

    private func agoText(_ date: Date) -> String {
        let secs = Int(Date().timeIntervalSince(date))
        if secs < 60 { return "just now" }
        if secs < 3600 { return "\(secs / 60)m ago" }
        return "\(secs / 3600)h ago"
    }
}
