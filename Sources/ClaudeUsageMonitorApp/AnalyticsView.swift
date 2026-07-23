import SwiftUI
import ClaudeUsageCore

/// Loads and holds the computed analytics for the selected range. Reading session logs
/// is I/O, so it happens on the `TokenUsageReader` actor, off the main thread.
@MainActor
final class AnalyticsViewModel: ObservableObject {
    @Published var range: AnalyticsRange = .sevenDays { didSet { reload() } }
    @Published private(set) var analytics: UsageAnalytics?
    @Published private(set) var isLoading = false

    private let reader = TokenUsageReader()
    private var task: Task<Void, Never>?

    func reloadIfNeeded() { if analytics == nil { reload() } }

    func reload() {
        task?.cancel()
        let range = self.range
        isLoading = true
        task = Task { [weak self, reader] in
            let result = await reader.analytics(range: range)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.analytics = result
                self?.isLoading = false
            }
        }
    }
}

/// Stat tiles + activity heatmap for a computed range — the "Stats" view of the
/// Analytics tab. Restored from 0.6.0; rendered only when "Detailed usage analytics" is on.
struct DetailedStatsView: View {
    let a: UsageAnalytics

    var body: some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 6), count: 2)
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: cols, spacing: 6) {
                StatTile(label: "Sessions", value: AnalyticsFormat.grouped(a.sessions))
                StatTile(label: "Messages", value: AnalyticsFormat.grouped(a.messages))
                StatTile(label: "Total tokens", value: AnalyticsFormat.compact(a.totalTokens))
                StatTile(label: "Active days", value: "\(a.activeDays)")
                StatTile(label: "Current streak", value: "\(a.currentStreak)d")
                StatTile(label: "Longest streak", value: "\(a.longestStreak)d")
                StatTile(label: "Peak hour", value: a.peakHour.map(AnalyticsFormat.hour) ?? "—")
                StatTile(label: "Top model", value: a.favoriteModel ?? "—")
            }
            Heatmap(cells: a.heatmap)
        }
    }
}

/// Per-day stacked token chart + model breakdown — the "Models" view of the Analytics tab.
struct DetailedModelsView: View {
    let a: UsageAnalytics

    var body: some View {
        let order = a.models.map(\.name)
        let palette = AnalyticsFormat.palette(for: order)
        let colorMap = Dictionary(uniqueKeysWithValues: zip(order, palette))
        VStack(alignment: .leading, spacing: 8) {
            StackedBarChart(daily: a.daily, order: order, colors: colorMap)
                .frame(height: 110)
            VStack(spacing: 4) {
                ForEach(Array(zip(a.models.prefix(4), palette)), id: \.0.id) { usage, color in
                    HStack(spacing: 7) {
                        RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
                        Text(usage.name).font(.system(size: 10.5))
                        Spacer()
                        Text("\(AnalyticsFormat.compact(usage.input))·\(AnalyticsFormat.compact(usage.output))")
                            .font(.system(size: 9)).foregroundStyle(.tertiary).monospacedDigit()
                        Text(AnalyticsFormat.percent(usage.fraction))
                            .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }
        }
    }
}

// MARK: - Compact stat tile

struct StatTile: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.callout).bold().lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
    }
}

/// GitHub-style activity grid: 7 rows (weekdays) × N week columns, colored by intensity.
struct Heatmap: View {
    let cells: [HeatCell]
    private let cell: CGFloat = 11
    private let gap: CGFloat = 3

    var body: some View {
        let rows = Array(repeating: GridItem(.fixed(cell), spacing: gap), count: 7)
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHGrid(rows: rows, spacing: gap) {
                ForEach(cells) { c in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color(for: c.level))
                        .frame(width: cell, height: cell)
                        .help(AnalyticsFormat.dayTooltip(c))
                }
            }
        }
        .frame(height: cell * 7 + gap * 6)
    }

    private func color(for level: Int) -> Color {
        switch level {
        case 1: return Color.accentColor.opacity(0.30)
        case 2: return Color.accentColor.opacity(0.50)
        case 3: return Color.accentColor.opacity(0.72)
        case 4: return Color.accentColor
        default: return Color.gray.opacity(0.18)
        }
    }
}

// MARK: - Hand-drawn stacked bar chart

/// A dependency-free stacked bar chart of daily tokens, split by model. One column per
/// active day (horizontally scrollable when there are many), with a Y grid + axis labels.
/// Hand-drawn on purpose — Swift Charts trapped on some real datasets.
struct StackedBarChart: View {
    let daily: [DailyModelTokens]
    let order: [String]              // model stacking order (bottom → top)
    let colors: [String: Color]

    private let yAxisWidth: CGFloat = 38
    private let barWidth: CGFloat = 12
    private let barGap: CGFloat = 5

    var body: some View {
        let byDay = Dictionary(grouping: daily, by: \.day)
        let days = byDay.keys.sorted()
        let columns: [(day: Date, tokens: [String: Int], total: Int)] = days.map { d in
            let map = Dictionary(byDay[d]!.map { ($0.model, $0.tokens) }, uniquingKeysWith: +)
            return (d, map, map.values.reduce(0, +))
        }
        let maxTotal = max(columns.map(\.total).max() ?? 0, 1)
        let ticks = niceTicks(upTo: maxTotal)
        let axisMax = max(ticks.last ?? maxTotal, 1)

        return HStack(alignment: .top, spacing: 4) {
            yAxis(ticks: ticks, axisMax: axisMax)
            GeometryReader { geo in
                let plotH = geo.size.height - 16
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .bottom, spacing: barGap) {
                        ForEach(Array(columns.enumerated()), id: \.offset) { idx, col in
                            column(col, plotH: plotH, axisMax: axisMax,
                                   showLabel: labelStride(days.count, idx))
                        }
                    }
                    .frame(height: geo.size.height, alignment: .bottom)
                }
                .background(gridlines(ticks: ticks, axisMax: axisMax, plotH: plotH))
            }
        }
    }

    private func column(_ col: (day: Date, tokens: [String: Int], total: Int),
                        plotH: CGFloat, axisMax: Int, showLabel: Bool) -> some View {
        VStack(spacing: 3) {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                ForEach(order.reversed(), id: \.self) { m in
                    let t = col.tokens[m] ?? 0
                    if t > 0 {
                        Rectangle()
                            .fill(colors[m] ?? .gray)
                            .frame(width: barWidth,
                                   height: max(1, CGFloat(t) / CGFloat(axisMax) * plotH))
                    }
                }
            }
            .frame(width: barWidth, height: plotH, alignment: .bottom)
            .clipShape(RoundedRectangle(cornerRadius: 2))
            .help("\(AnalyticsFormat.dayLabel(col.day)) · \(AnalyticsFormat.compact(col.total))")

            Text(showLabel ? AnalyticsFormat.axisDate(col.day) : " ")
                .font(.system(size: 7)).foregroundStyle(.tertiary)
                .fixedSize().frame(width: barWidth).lineLimit(1)
        }
    }

    private func yAxis(ticks: [Int], axisMax: Int) -> some View {
        GeometryReader { geo in
            let plotH = geo.size.height - 16
            ForEach(ticks, id: \.self) { t in
                Text(AnalyticsFormat.compact(t))
                    .font(.system(size: 8)).foregroundStyle(.tertiary)
                    .frame(width: yAxisWidth, alignment: .trailing)
                    .offset(y: plotH - CGFloat(t) / CGFloat(axisMax) * plotH - 5)
            }
        }
        .frame(width: yAxisWidth)
    }

    private func gridlines(ticks: [Int], axisMax: Int, plotH: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(ticks, id: \.self) { t in
                Rectangle().fill(.quaternary.opacity(0.5)).frame(height: 1)
                    .offset(y: plotH - CGFloat(t) / CGFloat(axisMax) * plotH)
            }
        }
    }

    private func niceTicks(upTo maxValue: Int) -> [Int] {
        guard maxValue > 0 else { return [0] }
        let rough = Double(maxValue) / 3.0
        let mag = pow(10, floor(log10(rough)))
        let step = Int((rough / mag).rounded(.up) * mag)
        guard step > 0 else { return [0, maxValue] }
        var out: [Int] = []; var v = 0
        while v <= maxValue + step { out.append(v); v += step }
        return out
    }

    private func labelStride(_ count: Int, _ idx: Int) -> Bool {
        guard count > 1 else { return true }
        let stride = max(1, count / 4)
        return idx % stride == 0 || idx == count - 1
    }
}

// MARK: - Shared bits

private struct SegmentButtonStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(selected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(selected ? .primary : .secondary)
            .contentShape(Rectangle())
    }
}

/// Formatting + a deterministic model color palette, shared across the tabs.
enum AnalyticsFormat {
    static func grouped(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    static func compact(_ n: Int) -> String {
        let d = Double(n)
        if d >= 1_000_000 { return String(format: "%.1fM", d / 1_000_000) }
        if d >= 1_000 { return String(format: "%.1fK", d / 1_000) }
        return "\(n)"
    }

    static func percent(_ f: Double) -> String { String(format: "%.1f%%", f * 100) }

    /// 11 → "11 AM", 0 → "12 AM", 13 → "1 PM".
    static func hour(_ h: Int) -> String {
        let twelve = h % 12 == 0 ? 12 : h % 12
        return "\(twelve) \(h < 12 ? "AM" : "PM")"
    }

    static func dayTooltip(_ c: HeatCell) -> String {
        "\(dayLabel(c.day)) · \(compact(c.tokens)) tokens"
    }

    static func dayLabel(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    /// Short axis date, e.g. "Jul 21".
    static func axisDate(_ d: Date) -> String {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("MMMd")
        return f.string(from: d)
    }

    /// A stable blue/purple palette, assigned in the given order.
    static func palette(for names: [String]) -> [Color] {
        let base: [Color] = [
            Color(red: 0.42, green: 0.55, blue: 0.93),
            Color(red: 0.30, green: 0.40, blue: 0.85),
            Color(red: 0.58, green: 0.66, blue: 0.96),
            Color(red: 0.50, green: 0.36, blue: 0.80),
            Color(red: 0.36, green: 0.68, blue: 0.86),
            Color(red: 0.72, green: 0.58, blue: 0.92),
        ]
        return names.indices.map { base[$0 % base.count] }
    }
}
