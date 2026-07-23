import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ClaudeUsageCore

/// Loads the token breakdown for the selected window (5h / 24h / 7d).
@MainActor
final class TokenBreakdownViewModel: ObservableObject {
    enum Window: String, CaseIterable {
        case fiveHours = "5h", day = "24h", week = "7d"
        var hours: Double {
            switch self {
            case .fiveHours: return 5
            case .day: return 24
            case .week: return 24 * 7
            }
        }
    }

    @Published var window: Window = .fiveHours { didSet { reload() } }
    @Published private(set) var breakdown: TokenBreakdown?
    @Published private(set) var isLoading = false

    private let reader = TokenUsageReader()
    private var task: Task<Void, Never>?

    func reloadIfNeeded() { if breakdown == nil { reload() } }

    func reload() {
        task?.cancel()
        let hours = window.hours
        isLoading = true
        task = Task { [weak self, reader] in
            let result = await reader.breakdown(hours: hours)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.breakdown = result
                self?.isLoading = false
            }
        }
    }
}

/// Analytics tab — session usage & forecast chart, then token breakdowns by model and by
/// source for the selected window, with export actions. Sized to fit without scrolling.
struct AnalyticsTab: View {
    @ObservedObject var model: MenuBarViewModel
    @StateObject private var tokens = TokenBreakdownViewModel()
    @StateObject private var insights = AnalyticsViewModel()
    @State private var section: Section = .tokens
    @State private var exportNote: String?

    /// Lower region of the tab. Only one shows at a time, so the tab never needs to scroll.
    enum Section: String, CaseIterable { case tokens = "Tokens", stats = "Stats", models = "Models" }

    /// Stats/Models come from the log-derived analytics, gated by "Detailed usage analytics".
    private var sections: [Section] {
        model.analyticsEnabled ? Section.allCases : [.tokens]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            forecastSection
            Divider()
            sectionPicker
            sectionBody
            actions
        }
        .onAppear {
            tokens.reloadIfNeeded()
            if model.analyticsEnabled { insights.reloadIfNeeded() }
        }
        .onChange(of: model.analyticsEnabled) { _, enabled in
            if enabled { insights.reloadIfNeeded() } else { section = .tokens }
        }
    }

    // MARK: Lower region

    @ViewBuilder
    private var sectionPicker: some View {
        if sections.count > 1 {
            HStack(spacing: 6) {
                ForEach(sections, id: \.self) { s in
                    Button(s.rawValue) { section = s }
                        .buttonStyle(MiniSegmentStyle(selected: section == s))
                }
                Spacer()
                // Range applies to the log-derived views only.
                if section != .tokens {
                    ForEach(AnalyticsRange.allCases, id: \.self) { r in
                        Button(r.label) { insights.range = r }
                            .buttonStyle(MiniSegmentStyle(selected: insights.range == r))
                    }
                }
                if insights.isLoading || tokens.isLoading {
                    ProgressView().controlSize(.mini)
                }
            }
        }
    }

    @ViewBuilder
    private var sectionBody: some View {
        switch section {
        case .tokens:
            tokenSections
        case .stats, .models:
            if let a = insights.analytics {
                if a.isEmpty {
                    Text("No usage recorded in this range")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                } else if section == .stats {
                    DetailedStatsView(a: a)
                } else {
                    DetailedModelsView(a: a)
                }
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Analyzing session logs…").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: Forecast

    private var forecastSection: some View {
        // The 5h / 24h / 7d segment drives this chart as well as the token breakdown.
        let cutoff = Date().addingTimeInterval(-tokens.window.hours * 3600)
        let windowed = model.recentHistory.filter { $0.timestamp >= cutoff }
        let records = windowed.count >= 2 ? windowed : model.recentHistory
        let points = records.map { (date: $0.timestamp, used: usedPercent(in: $0)) }
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Session usage & forecast").font(.system(size: 11, weight: .semibold))
                Spacer()
                ForEach(TokenBreakdownViewModel.Window.allCases, id: \.self) { w in
                    Button(w.rawValue) { tokens.window = w }
                        .buttonStyle(MiniSegmentStyle(selected: tokens.window == w))
                }
            }

            if points.count >= 2 {
                ForecastChart(history: points,
                              exhaustionAt: model.prediction?.exhaustionAt,
                              nextReset: currentSnapshot?.nextReset)
                    .frame(height: 90)
                // Axis: window start → now, plus the ceiling marker.
                HStack {
                    Text(axisLabel(points.first?.date))
                    Spacer()
                    Text(axisLabel(midpoint(points)))
                    Spacer()
                    Text("now").foregroundStyle(.secondary)
                    Spacer()
                    Text("100%").foregroundStyle(Color.red.opacity(0.8))
                }
                .font(.system(size: 9)).foregroundStyle(.tertiary).monospacedDigit()
            } else {
                Text("Collecting samples — the forecast appears once there's enough history.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .frame(height: 90, alignment: .center)
            }

            if let warning = exhaustionWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10)).foregroundStyle(.orange).lineLimit(2)
            }
        }
    }

    /// "100% at ~9:42 PM — 1h 18m before the 11:00 PM reset".
    private var exhaustionWarning: String? {
        guard let out = model.prediction?.exhaustionAt,
              let reset = currentSnapshot?.nextReset, out < reset else { return nil }
        let lead = reset.timeIntervalSince(out)
        let h = Int(lead) / 3600, m = (Int(lead) % 3600) / 60
        let gap = h > 0 ? "\(h)h \(m)m" : "\(m)m"
        return "100% at ~\(Formatting.time(out)) — \(gap) before the \(Formatting.time(reset)) reset"
    }

    // MARK: Tokens

    @ViewBuilder
    private var tokenSections: some View {
        if let b = tokens.breakdown {
            if b.isEmpty {
                Text("No local token usage in this window.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    tokenGroup("TOKENS BY MODEL · \(tokens.window.rawValue.uppercased())",
                               b.byModel, limit: 3, tint: .orange)
                    VStack(alignment: .leading, spacing: 5) {
                        tokenGroup("TOKENS BY SOURCE · \(tokens.window.rawValue.uppercased())",
                                   b.bySource, limit: 2, tint: .secondary)
                        Text("Claude Code sessions only — desktop chat is server-side")
                            .font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                }
            }
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Reading session logs…").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func tokenGroup(_ title: String, _ items: [NamedTotals],
                            limit: Int, tint: Color) -> some View {
        if !items.isEmpty {
            let maxV = max(items.map { $0.totals.inputPlusOutput }.max() ?? 1, 1)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 10, weight: .semibold)).tracking(0.4)
                    .foregroundStyle(.secondary)
                ForEach(items.prefix(limit)) { item in
                    HStack(spacing: 8) {
                        Text(item.name)
                            .font(.system(size: 10.5)).lineLimit(1)
                            .frame(width: 62, alignment: .leading)
                        UsageBar(fraction: Double(item.totals.inputPlusOutput) / Double(maxV),
                                 color: tint, height: 8)
                        Text(TokenBarRow.compact(item.totals.inputPlusOutput))
                            .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                            .frame(width: 42, alignment: .trailing)
                    }
                }
            }
        }
    }

    // MARK: Actions

    private var actions: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                actionChip("Export CSV", "arrow.down.doc") {
                    if let b = tokens.breakdown { exportCSV(b) }
                }
                .disabled(tokens.breakdown == nil)
                actionChip("Open Grafana", "chart.xyaxis.line") {
                    open("http://localhost:3000")
                }
                .help("Opens Grafana. Serve metrics with: claude-monitor --serve")
            }
            if let note = exportNote {
                Text(note).font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(2)
            }
        }
    }

    private func actionChip(_ title: String, _ icon: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9))
                Text(title).font(.system(size: 10.5))
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func exportCSV(_ b: TokenBreakdown) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "claude-usage-\(tokens.window.rawValue).csv"
        panel.allowedContentTypes = [UTType.commaSeparatedText]
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try UsageCSV.breakdown(b).write(to: url, atomically: true, encoding: .utf8)
            exportNote = "Saved to \(url.lastPathComponent)"
        } catch {
            exportNote = "Export failed: \(error.localizedDescription)"
        }
    }

    // MARK: Helpers

    private var currentSnapshot: UsageSnapshot? {
        if case .loaded(let s) = model.state { return s }
        return nil
    }

    /// Used% for the headline window, so the forecast matches the Overview gauge.
    private func usedPercent(in r: UsageRecord) -> Double {
        let pinned = model.headlineMetricID
        if !pinned.isEmpty, let m = r.metrics.first(where: { $0.id == pinned }) {
            return (m.fractionUsed * 100).rounded()
        }
        return Double(r.percentUsed)
    }

    private func axisLabel(_ date: Date?) -> String {
        guard let date else { return "" }
        return Formatting.axis(date, longSpan: Date().timeIntervalSince(date) >= 36 * 3600)
    }

    /// Midpoint of the plotted history, for the middle axis tick.
    private func midpoint(_ points: [(date: Date, used: Double)]) -> Date? {
        guard let first = points.first?.date, let last = points.last?.date else { return nil }
        return first.addingTimeInterval(last.timeIntervalSince(first) / 2)
    }

    private func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Compact segmented button used for the token window picker.
struct MiniSegmentStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 9))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(selected ? Color.primary.opacity(0.14) : .clear,
                        in: RoundedRectangle(cornerRadius: 5))
            .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .contentShape(Rectangle())
    }
}
