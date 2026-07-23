import SwiftUI
import AppKit
import ClaudeUsageCore

struct MenuContentView: View {
    @ObservedObject var model: MenuBarViewModel
    @ObservedObject var updates: UpdateManager
    @StateObject private var loginItem = LoginItemManager()
    @State private var showSettings = false
    @State private var showAnalytics = false
    @State private var loginError: String?

    private let intervals: [(String, TimeInterval)] = [
        ("1m", 60), ("5m", 300), ("10m", 600), ("15m", 900), ("30m", 1800),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            updateBanner
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
            Task { await model.loadTokens() }
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

    // MARK: Update banner

    /// Shown when a newer GitHub release exists: version, key changes, and actions.
    @ViewBuilder
    private var updateBanner: some View {
        if let r = updates.available {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
                    Text("\(r.tagName) available").font(.caption).bold()
                    Spacer()
                    if updates.isInstalling {
                        ProgressView().controlSize(.mini)
                    }
                }
                if let status = updates.installStatus {
                    Text(status).font(.caption2).foregroundStyle(.secondary)
                } else {
                    // Key changes from the release notes.
                    ForEach(r.highlights(max: 3), id: \.self) { line in
                        Text("• \(line)")
                            .font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 8) {
                        Button("Update now") { Task { await updates.install(r) } }
                            .controlSize(.small)
                        Button("Release notes") {
                            if let url = r.htmlURL { NSWorkspace.shared.open(url) }
                        }
                        .controlSize(.small)
                        Button("Skip") { updates.skip(r) }
                            .controlSize(.small)
                    }
                }
            }
            .padding(8)
            .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: Loaded

    private func loaded(_ s: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            hero(s)

            trend

            VStack(alignment: .leading, spacing: 10) {
                ForEach(s.metrics) { metricRow($0) }
            }

            tokensSection

            if model.detailed {
                Divider()
                detailSection(s)
            }
        }
    }

    /// Token counts from local Claude Code logs, grouped by originating app.
    @ViewBuilder
    private var tokensSection: some View {
        if let r = model.tokenReport, r.today.inputPlusOutput > 0 || !r.bySource.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Label("Tokens today", systemImage: "number")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(tok(r.today.input + r.today.output)) in+out")
                        .font(.caption).monospacedDigit()
                }
                ForEach(r.bySource) { s in
                    HStack {
                        Text(s.name).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                        Spacer()
                        Text("\(tok(s.totals.input + s.totals.output)) · 7d")
                            .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                    }
                }
                Text("Claude Code only — desktop chat is server-side")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
    }

    /// Compact token count, e.g. 3.2M, 924K.
    private func tok(_ n: Int) -> String {
        let d = Double(n)
        if d >= 1_000_000 { return String(format: "%.1fM", d / 1_000_000) }
        if d >= 1_000 { return String(format: "%.0fK", d / 1_000) }
        return "\(n)"
    }

    private func hero(_ s: UsageSnapshot) -> some View {
        let pinned = model.headlineMetricID
        let remaining = s.percentRemaining(pinnedID: pinned)
        let severity = s.severity(pinnedID: pinned)
        return HStack(spacing: 14) {
            ZStack {
                GaugeRing(fraction: Double(remaining) / 100.0,
                          color: color(severity), lineWidth: 8)
                    .frame(width: 62, height: 62)
                VStack(spacing: -1) {
                    Text("\(remaining)")
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("% left").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(s.planName).font(.headline)
                // Which window this headline reflects (auto = most-consumed, or pinned).
                if let m = s.headlineMetric(pinnedID: pinned) {
                    Label(
                        pinned.isEmpty ? "\(m.label) · most used" : "\(m.label) · pinned",
                        systemImage: pinned.isEmpty ? "chart.line.uptrend.xyaxis" : "pin.fill"
                    )
                    .font(.caption2).foregroundStyle(.secondary)
                }
                if let reset = s.nextReset {
                    Label(Formatting.relative(reset), systemImage: "clock.arrow.circlepath")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let p = model.prediction, p.ratePerHour > 0.05 {
                    Label(burnText(p), systemImage: "flame")
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

    /// Trend sparkline of recent used% for the headline window, annotated with the time
    /// range it covers and the sampling cadence — so it's clear whether the x-axis spans
    /// hours or days.
    @ViewBuilder
    private var trend: some View {
        let records = model.recentHistory
        let values = records.map { usedPercent(in: $0) }
        if values.count >= 3, let first = records.first?.timestamp, let last = records.last?.timestamp {
            let span = last.timeIntervalSince(first)
            let longSpan = span >= 36 * 3600           // ≥ ~1.5 days → label the axis by date
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("USAGE TREND").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                    Spacer()
                    // e.g. "past 5h · ~5m samples" — the unit of the graph at a glance.
                    Text("past \(durationText(span)) · ~\(durationText(sampleStep(records))) samples")
                        .font(.system(size: 9)).foregroundStyle(.tertiary).monospacedDigit()
                }
                Sparkline(values: values, color: .orange).frame(height: 28)
                HStack {
                    Text(axisLabel(first, longSpan: longSpan))
                    Spacer()
                    Text(longSpan ? axisLabel(last, longSpan: true) : "now")
                }
                .font(.system(size: 9)).foregroundStyle(.tertiary).monospacedDigit()
            }
        }
    }

    /// Used% for the headline window this record represents — honors the pinned metric
    /// so the trend matches the hero gauge; falls back to the record's headline used%.
    private func usedPercent(in r: UsageRecord) -> Double {
        let pinned = model.headlineMetricID
        if !pinned.isEmpty, let m = r.metrics.first(where: { $0.id == pinned }) {
            return (m.fractionUsed * 100).rounded()
        }
        return Double(r.percentUsed)
    }

    /// Median gap between consecutive samples — the graph's granularity.
    private func sampleStep(_ records: [UsageRecord]) -> TimeInterval {
        guard records.count >= 2 else { return 0 }
        let gaps = zip(records.dropFirst(), records).map { $0.timestamp.timeIntervalSince($1.timestamp) }
            .filter { $0 > 0 }.sorted()
        guard !gaps.isEmpty else { return 0 }
        return gaps[gaps.count / 2]
    }

    /// Compact duration: "45s", "5m", "5h 12m", "2d 3h".
    private func durationText(_ interval: TimeInterval) -> String {
        let s = Int(interval.rounded())
        if s < 60 { return "\(max(s, 1))s" }
        let m = s / 60, h = m / 60, d = h / 24
        if d >= 1 { let rh = h % 24; return rh > 0 ? "\(d)d \(rh)h" : "\(d)d" }
        if h >= 1 { let rm = m % 60; return rm > 0 ? "\(h)h \(rm)m" : "\(h)h" }
        return "\(m)m"
    }

    /// Axis endpoint label: a time (HH:mm) for short spans, a date for multi-day spans.
    private func axisLabel(_ date: Date, longSpan: Bool) -> String {
        let f = DateFormatter()
        if longSpan { f.setLocalizedDateFormatFromTemplate("MMMd") }
        else { f.setLocalizedDateFormatFromTemplate("Hmm") }
        return f.string(from: date)
    }

    private func burnText(_ p: UsagePrediction) -> String {
        if let at = p.exhaustionAt, p.hoursUntilExhaustion != nil {
            return String(format: "%.1f%%/h · runs out %@", p.ratePerHour, Formatting.relative(at))
        }
        return String(format: "%.1f%%/h burn rate", p.ratePerHour)
    }

    private func metricRow(_ m: UsageMetric) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if m.modelName != nil {
                    Image(systemName: m.pricing != nil ? "dollarsign.circle" : "cpu")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Text(m.label).font(.caption).foregroundStyle(.secondary)
                if m.isActive { ActiveBadge() }
                Spacer()
                // Right side: available quota and/or metered spend, together.
                HStack(spacing: 6) {
                    if m.hasQuota {
                        Text("\(m.percentRemaining)% left")
                            .font(.caption).monospacedDigit()
                            .foregroundStyle(color(forFraction: m.fractionUsed))
                    }
                    if m.isMetered {
                        Text(m.spendText ?? "$0.00")
                            .font(.caption).monospacedDigit().foregroundStyle(.primary)
                    }
                }
            }
            if m.hasQuota {
                // Fill = remaining capacity (a "fuel gauge"), matching the "% left" label.
                UsageBar(fraction: 1 - m.fractionUsed, color: color(forFraction: m.fractionUsed))
            }
            // Per-token rate — shown for priced models (Fable) as context; the rate is the
            // marginal cost once the window is metered.
            if let p = m.pricing, (m.isMetered || model.detailed) {
                Text("$\(rate(p.inputPerMillion))/M in · $\(rate(p.outputPerMillion))/M out")
                    .font(.caption2).foregroundStyle(.tertiary)
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

            Divider().padding(.vertical, 2)
            Text("ABOUT").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
            row("Version", appVersionText)
            row("License", licenseText)
            HStack {
                Text("Source").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("github.com/JK-skt/claude-usage-monitor") {
                    open("https://github.com/JK-skt/claude-usage-monitor")
                }
                .buttonStyle(.link).font(.caption)
            }
        }
    }

    /// e.g. "0.4.0 (build 11)" — or "dev" for unbundled `swift run` builds.
    private var appVersionText: String {
        guard AppVersion.isBundledApp else { return "dev (unbundled)" }
        let v = AppVersion.current
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        return build.map { "\(v) (build \($0))" } ?? v
    }

    /// License summary from the bundle's copyright string, falling back to the
    /// project's known license.
    private var licenseText: String {
        (Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String)
            ?? "MIT License. Unofficial — not affiliated with Anthropic."
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

            if model.analyticsEnabled {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showAnalytics.toggle() }
                } label: {
                    HStack {
                        Image(systemName: "chart.bar.xaxis").frame(width: 16)
                        Text("사용 분석")
                        Spacer()
                        Image(systemName: showAnalytics ? "chevron.up" : "chevron.down")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if showAnalytics {
                    AnalyticsSection()
                        .padding(.leading, 4).padding(.trailing, 2).padding(.top, 2)
                }
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

            Toggle(isOn: $model.analyticsEnabled) { Text("상세 사용 분석") }
                .toggleStyle(.switch).controlSize(.small)

            // Which window drives the headline % (menu bar, gauge, trend).
            HStack {
                Text("Main usage").font(.callout)
                Spacer()
                Picker("", selection: $model.headlineMetricID) {
                    ForEach(headlineOptions, id: \.id) { opt in
                        Text(opt.label).tag(opt.id)
                    }
                }
                .labelsHidden().controlSize(.small).frame(width: 150)
            }

            Toggle(isOn: Binding(
                get: { model.notificationsEnabled },
                set: { model.notificationsEnabled = $0 }
            )) { Text("Low-usage alerts") }
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

            Divider()

            // Software updates (GitHub Releases).
            Toggle(isOn: $updates.autoCheck) { Text("Check for updates") }
                .toggleStyle(.switch).controlSize(.small)
            Toggle(isOn: $updates.autoInstall) { Text("Install updates automatically") }
                .toggleStyle(.switch).controlSize(.small)
                .disabled(!updates.autoCheck)
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
        .padding(.leading, 24)
        .padding(.trailing, 4)
        .padding(.vertical, 2)
    }

    /// Picker options for the "Main usage" setting: "Most used (auto)" plus each quota
    /// window currently available. If a previously-pinned window is no longer present,
    /// it is still listed (marked unavailable) so the Picker keeps a valid selection.
    private var headlineOptions: [(id: String, label: String)] {
        var opts: [(id: String, label: String)] = [("", "Most used (auto)")]
        var candidates: [UsageMetric] = []
        if case .loaded(let s) = model.state { candidates = s.headlineCandidates }
        opts += candidates.map { (id: $0.id, label: $0.label) }
        let pinned = model.headlineMetricID
        if !pinned.isEmpty, !candidates.contains(where: { $0.id == pinned }) {
            opts.append((id: pinned, label: "\(pinned) (unavailable)"))
        }
        return opts
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
        let pinned = model.headlineMetricID
        var lines = ["Plan: \(s.planName)", "Remaining: \(s.percentRemaining(pinnedID: pinned))%"]
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
