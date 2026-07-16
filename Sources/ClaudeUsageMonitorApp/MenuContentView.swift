import SwiftUI
import AppKit
import ClaudeUsageCore

struct MenuContentView: View {
    @ObservedObject var model: MenuBarViewModel
    @StateObject private var loginItem = LoginItemManager()
    @State private var showSettings = false
    @State private var loginError: String?

    private let intervals: [(String, TimeInterval)] = [
        ("1m", 60), ("5m", 300), ("10m", 600), ("15m", 900), ("30m", 1800),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()

            switch model.state {
            case .loading:
                Label("Loading usage…", systemImage: "hourglass")
                    .foregroundStyle(.secondary)
            case .failed(let message):
                failure(message)
            case .loaded(let snapshot):
                loaded(snapshot)
            }

            Divider()
            controls
        }
        .padding(14)
        .frame(width: 340)
    }

    // MARK: Sections

    private var header: some View {
        HStack {
            Image(systemName: "gauge.with.dots.needle.67percent")
            Text("Claude Usage").font(.headline)
            Spacer()
            if let updated = model.lastUpdated {
                Text(Formatting.time(updated))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func loaded(_ s: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(s.planName).font(.subheadline).bold()
                Spacer()
                Text("\(s.percentRemaining)% left")
                    .font(.subheadline)
                    .foregroundStyle(color(s.severity))
            }

            // Every window — session, weekly, and per-model (incl. Fable).
            ForEach(s.metrics) { metric in
                metricRow(metric, detailed: model.detailed)
            }

            if model.detailed {
                Divider()
                detailSection(s)
            } else if let reset = s.nextReset {
                row("Next reset", Formatting.relative(reset))
            }
        }
    }

    @ViewBuilder
    private func metricRow(_ m: UsageMetric, detailed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if m.modelName != nil {
                    Image(systemName: "cpu").font(.caption2).foregroundStyle(.secondary)
                }
                Text(m.label).font(.caption).foregroundStyle(.secondary)
                if m.isActive {
                    Text("active")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.18), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
                Spacer()
                Text("\(m.percentUsed)% used").font(.caption).monospacedDigit()
            }
            ProgressView(value: m.fractionUsed).tint(color(forFraction: m.fractionUsed))
            if detailed, let reset = m.resetsAt {
                Text("resets \(Formatting.relative(reset))  ·  \(Formatting.absolute(reset))")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    /// The full "show everything" block, shown when the detailed option is on.
    @ViewBuilder
    private func detailSection(_ s: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("DETAILS").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)

            if let reset = s.nextReset {
                row("Next reset", "\(Formatting.relative(reset))  ·  \(Formatting.absolute(reset))")
            }
            row("Severity", s.severity.rawValue.capitalized)

            if let a = s.account {
                if let org = a.organizationName { row("Organization", org) }
                if let name = a.displayName { row("Account", name) }
                if let email = a.emailAddress { row("Email", email) }
                if let tier = a.organizationRateLimitTier { row("Tier", tier) }
                if let billing = a.billingType { row("Billing", billing) }
                if let extra = a.hasExtraUsageEnabled { row("Extra usage", extra ? "on" : "off") }
            }

            if let overage = s.usage.overage, let status = overage.status {
                row("Overage", status)
            }
            row("Captured", Formatting.absolute(s.capturedAt))
        }
    }

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Couldn't load usage", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(message).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var controls: some View {
        VStack(spacing: 4) {
            button("Refresh", "arrow.clockwise") { Task { await model.refresh() } }
            button("Open Claude", "safari") { open("https://claude.ai") }
            button("Copy Usage", "doc.on.doc") { copyUsage() }

            // Inline settings — always reliable in the popover (no separate window).
            button("Settings", showSettings ? "chevron.down" : "chevron.right") {
                withAnimation(.easeInOut(duration: 0.15)) { showSettings.toggle() }
            }
            if showSettings { settingsSection }

            Divider().padding(.vertical, 2)
            button("Quit", "power") { NSApp.terminate(nil) }
        }
        .onAppear { loginItem.refresh() }
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { loginItem.isEnabled },
                set: { loginError = loginItem.setEnabled($0) }
            )) { Text("Launch at login") }
                .toggleStyle(.switch).controlSize(.small)

            if loginItem.needsApproval {
                Text("Approve in System Settings › Login Items")
                    .font(.caption2).foregroundStyle(.orange)
            }
            if let loginError {
                Text(loginError).font(.caption2).foregroundStyle(.red)
            }

            Toggle(isOn: $model.detailed) { Text("Show all details") }
                .toggleStyle(.switch).controlSize(.small)

            HStack {
                Text("Refresh every").font(.callout)
                Spacer()
                Picker("", selection: $model.refreshInterval) {
                    ForEach(intervals, id: \.1) { label, value in
                        Text(label).tag(value)
                    }
                }
                .labelsHidden().controlSize(.small).frame(width: 90)
            }
        }
        .padding(.leading, 24)
        .padding(.trailing, 4)
        .padding(.vertical, 2)
    }

    // MARK: Helpers

    private func row(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(key).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption).multilineTextAlignment(.trailing)
        }
    }

    private func button(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon).frame(width: 16)
                Text(title)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    private func copyUsage() {
        guard case .loaded(let s) = model.state else { return }
        var lines = ["Plan: \(s.planName)", "Remaining: \(s.percentRemaining)%"]
        for m in s.metrics {
            lines.append("\(m.label): \(m.percentUsed)% used")
        }
        lines.append("Next reset: \(Formatting.absolute(s.nextReset))")
        lines.append("Captured: \(Formatting.absolute(s.capturedAt))")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    private func color(_ severity: UsageSnapshot.Severity) -> Color {
        switch severity {
        case .green: return .green
        case .yellow: return .yellow
        case .orange: return .orange
        case .red, .critical: return .red
        }
    }

    private func color(forFraction f: Double) -> Color {
        switch Int(f * 100) {
        case ..<50: return .green
        case 50..<80: return .yellow
        case 80..<95: return .orange
        default: return .red
        }
    }
}
