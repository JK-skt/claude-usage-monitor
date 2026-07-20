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
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()

            switch model.state {
            case .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading usage…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)
            case .failed(let message):
                failure(message)
            case .loaded(let snapshot):
                loaded(snapshot)
            }

            Divider()
            footer
        }
        .padding(14)
        .frame(width: 320)
        .onAppear {
            model.refreshIfStale()
            loginItem.refresh()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .foregroundStyle(.orange)
            Text("Claude Usage").font(.headline)
            Spacer()
            if model.isRefreshing {
                ProgressView().controlSize(.mini)
            } else if let updated = model.lastUpdated {
                Text(agoText(updated))
                    .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
            }
        }
    }

    // MARK: Loaded

    private func loaded(_ s: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            hero(s)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(s.metrics) { metricRow($0) }
            }

            if model.detailed {
                Divider()
                detailSection(s)
            }
        }
    }

    private func hero(_ s: UsageSnapshot) -> some View {
        HStack(spacing: 14) {
            ZStack {
                GaugeRing(fraction: Double(s.percentRemaining) / 100.0,
                          color: color(s.severity), lineWidth: 8)
                    .frame(width: 62, height: 62)
                VStack(spacing: -1) {
                    Text("\(s.percentRemaining)")
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("% left").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(s.planName).font(.headline)
                if let reset = s.nextReset {
                    Label(Formatting.relative(reset), systemImage: "clock.arrow.circlepath")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if model.lastError != nil {
                    Label("Showing last known values", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func metricRow(_ m: UsageMetric) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if m.modelName != nil {
                    Image(systemName: m.isMetered ? "dollarsign.circle" : "cpu")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Text(m.label).font(.caption).foregroundStyle(.secondary)
                if m.isActive { ActiveBadge() }
                Spacer()
                if m.isMetered {
                    Text(m.spendText ?? "$0.00")
                        .font(.caption).monospacedDigit().foregroundStyle(.primary)
                } else {
                    Text("\(m.percentUsed)%")
                        .font(.caption).monospacedDigit()
                        .foregroundStyle(color(forFraction: m.fractionUsed))
                }
            }
            if m.isMetered {
                // Pay-as-you-go: no quota bar. Show the per-token rate instead.
                if let p = m.pricing {
                    Text("$\(rate(p.inputPerMillion))/M in · $\(rate(p.outputPerMillion))/M out")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            } else {
                UsageBar(fraction: m.fractionUsed, color: color(forFraction: m.fractionUsed))
            }
            if model.detailed, let reset = m.resetsAt {
                Text("resets \(Formatting.relative(reset))")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private func rate(_ d: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 2
        return f.string(from: NSDecimalNumber(decimal: d)) ?? "\(d)"
    }

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

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                chip("Refresh", "arrow.clockwise") { Task { await model.refresh() } }
                chip("Copy", "doc.on.doc") { copyUsage() }
                chip("Claude", "safari") { open("https://claude.ai") }
            }

            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showSettings.toggle() }
            } label: {
                HStack {
                    Image(systemName: "gearshape").frame(width: 16)
                    Text("Settings")
                    Spacer()
                    Image(systemName: showSettings ? "chevron.up" : "chevron.down")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showSettings { settingsSection }

            Divider()
            Button { NSApp.terminate(nil) } label: {
                HStack {
                    Image(systemName: "power").frame(width: 16)
                    Text("Quit")
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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

    private func chip(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
    }

    private func agoText(_ date: Date) -> String {
        let secs = Int(Date().timeIntervalSince(date))
        if secs < 60 { return "just now" }
        if secs < 3600 { return "\(secs / 60)m ago" }
        return "\(secs / 3600)h ago"
    }

    private func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    private func copyUsage() {
        guard case .loaded(let s) = model.state else { return }
        var lines = ["Plan: \(s.planName)", "Remaining: \(s.percentRemaining)%"]
        for m in s.metrics {
            if m.isMetered {
                lines.append("\(m.label): \(m.spendText ?? "$0.00") spent")
            } else {
                lines.append("\(m.label): \(m.percentUsed)% used")
            }
        }
        if let spend = s.meteredSpend {
            lines.append("Metered spend: \(ModelPricing.formatUSD(spend))")
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
