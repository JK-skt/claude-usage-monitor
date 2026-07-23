import Foundation

/// Maps a raw Claude model id (e.g. "claude-fable-5", "claude-opus-4-8") to a short
/// display name ("Fable 5", "Opus 4.8"). Unknown ids are cleaned up best-effort.
public enum ModelDisplayName {
    public static func pretty(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty, raw != "unknown" else { return "Unknown" }
        var s = raw.lowercased()
        for p in ["claude-", "anthropic/"] where s.hasPrefix(p) { s.removeFirst(p.count) }
        // Drop a trailing date stamp like "-20250219".
        if let r = s.range(of: #"-20\d{6}$"#, options: .regularExpression) { s.removeSubrange(r) }

        let families = ["opus", "sonnet", "haiku", "fable"]
        guard let family = families.first(where: { s.contains($0) }) else {
            return raw // unrecognized — show as-is
        }
        // Everything after the family name is the version ("4-8" → "4.8").
        let tail = s.components(separatedBy: family).last ?? ""
        let version = tail
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_ "))
            .replacingOccurrences(of: "-", with: ".")
            .replacingOccurrences(of: "_", with: ".")
        let name = family.capitalized
        return version.isEmpty ? name : "\(name) \(version)"
    }
}

/// The time window an analytics report covers.
public enum AnalyticsRange: String, Sendable, CaseIterable, Codable {
    case all, thirtyDays, sevenDays

    /// Number of days back, or nil for "all history".
    public var days: Int? {
        switch self {
        case .all: return nil
        case .thirtyDays: return 30
        case .sevenDays: return 7
        }
    }

    public var label: String {
        switch self {
        case .all: return "All"
        case .thirtyDays: return "30d"
        case .sevenDays: return "7d"
        }
    }
}

/// One model's contribution to the total (for the model breakdown list + chart).
public struct ModelUsage: Sendable, Identifiable, Codable, Hashable {
    public let name: String        // display name, e.g. "Fable 5"
    public let input: Int
    public let output: Int
    public let fraction: Double     // 0...1 of the range's input+output total
    public var id: String { name }
    public var total: Int { input + output }
}

/// A single day's total input+output tokens, split per model — the stacked-bar datum.
public struct DailyModelTokens: Sendable, Identifiable, Codable, Hashable {
    public let day: Date
    public let model: String
    public let tokens: Int
    public var id: String { "\(day.timeIntervalSince1970)-\(model)" }
}

/// A cell in the GitHub-style activity heatmap: one calendar day.
public struct HeatCell: Sendable, Identifiable, Codable, Hashable {
    public let day: Date
    public let tokens: Int
    /// 0 (none) … 4 (most) intensity bucket, for coloring.
    public let level: Int
    public var id: TimeInterval { day.timeIntervalSince1970 }
}

/// The fully-computed analytics for a range — everything the Analytics window renders.
public struct UsageAnalytics: Sendable, Codable, Hashable {
    public let range: AnalyticsRange
    public let generatedAt: Date

    // Overview stat tiles.
    public let sessions: Int
    public let messages: Int
    public let totalTokens: Int          // input + output (excludes cache)
    public let activeDays: Int
    public let currentStreak: Int
    public let longestStreak: Int
    public let peakHour: Int?             // 0...23, or nil if no data
    public let favoriteModel: String?

    // Visualizations.
    public let heatmap: [HeatCell]
    public let models: [ModelUsage]
    public let daily: [DailyModelTokens]

    public var isEmpty: Bool { messages == 0 }
}

/// Builds ``UsageAnalytics`` from raw token samples. Pure/deterministic given its inputs.
public enum UsageAnalyticsBuilder {
    public static func build(from samples: [TokenSample],
                             range: AnalyticsRange,
                             now: Date = Date(),
                             calendar: Calendar = .current) -> UsageAnalytics {
        var cal = calendar
        cal.firstWeekday = 1 // Sunday-first, matching the GitHub-style grid

        // Filter to the range.
        let startDay = cal.startOfDay(for: now)
        let windowStart: Date? = range.days.map {
            cal.date(byAdding: .day, value: -($0 - 1), to: startDay) ?? startDay
        }
        let inRange = windowStart.map { start in samples.filter { $0.timestamp >= start } } ?? samples

        // Aggregate.
        var sessionIDs = Set<String>()
        var messages = 0
        var input = 0, output = 0
        var hourCounts = [Int](repeating: 0, count: 24)
        var modelTokens: [String: (Int, Int)] = [:]        // raw model → (in, out)
        var dayTokens: [Date: Int] = [:]                    // day → in+out
        var dayModel: [Date: [String: Int]] = [:]           // day → model → in+out
        var activeDaySet = Set<Date>()

        for s in inRange {
            messages += 1
            input += s.input
            output += s.output
            if let sid = s.sessionID { sessionIDs.insert(sid) }
            hourCounts[cal.component(.hour, from: s.timestamp)] += 1

            let io = s.input + s.output
            let model = ModelDisplayName.pretty(s.model)
            let cur = modelTokens[model] ?? (0, 0)
            modelTokens[model] = (cur.0 + s.input, cur.1 + s.output)

            let day = cal.startOfDay(for: s.timestamp)
            dayTokens[day, default: 0] += io
            dayModel[day, default: [:]][model, default: 0] += io
            activeDaySet.insert(day)
        }

        let totalIO = input + output

        // Peak hour (by message volume).
        let peakHour: Int? = hourCounts.contains(where: { $0 > 0 })
            ? hourCounts.firstIndex(of: hourCounts.max()!) : nil

        // Favorite model (by input+output).
        let favorite = modelTokens.max { ($0.value.0 + $0.value.1) < ($1.value.0 + $1.value.1) }?.key

        // Streaks over active days.
        let (current, longest) = streaks(activeDays: activeDaySet, today: startDay, calendar: cal)

        // Model breakdown, ranked.
        let models: [ModelUsage] = modelTokens
            .map { name, io in
                ModelUsage(name: name, input: io.0, output: io.1,
                           fraction: totalIO > 0 ? Double(io.0 + io.1) / Double(totalIO) : 0)
            }
            .filter { $0.total > 0 }
            .sorted { $0.total > $1.total }

        // Daily-by-model, for the stacked bar chart (chronological).
        let daily: [DailyModelTokens] = dayModel
            .flatMap { day, byModel in byModel.map { DailyModelTokens(day: day, model: $0.key, tokens: $0.value) } }
            .sorted { $0.day < $1.day }

        // Heatmap over the visible span (range window, or since first activity for "all"),
        // padded to whole weeks so the grid is rectangular.
        let heatmap = buildHeatmap(dayTokens: dayTokens, range: range,
                                   windowStart: windowStart, today: startDay, calendar: cal)

        return UsageAnalytics(
            range: range,
            generatedAt: now,
            sessions: sessionIDs.count,
            messages: messages,
            totalTokens: totalIO,
            activeDays: activeDaySet.count,
            currentStreak: current,
            longestStreak: longest,
            peakHour: peakHour,
            favoriteModel: favorite,
            heatmap: heatmap,
            models: models,
            daily: daily
        )
    }

    // MARK: Helpers

    /// Current (ending today or yesterday) and longest consecutive-day streaks.
    private static func streaks(activeDays: Set<Date>, today: Date,
                                calendar cal: Calendar) -> (current: Int, longest: Int) {
        guard !activeDays.isEmpty else { return (0, 0) }
        let sorted = activeDays.sorted()

        var longest = 1, run = 1
        for i in 1..<max(sorted.count, 1) {
            guard sorted.indices.contains(i) else { break }
            if let prevPlus1 = cal.date(byAdding: .day, value: 1, to: sorted[i - 1]),
               cal.isDate(prevPlus1, inSameDayAs: sorted[i]) {
                run += 1
            } else {
                run = 1
            }
            longest = max(longest, run)
        }
        if sorted.count == 1 { longest = 1 }

        // Current streak: count back from today (or yesterday) while days are present.
        var current = 0
        var cursor = today
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!
        if !activeDays.contains(today) {
            if activeDays.contains(yesterday) { cursor = yesterday } else { return (0, longest) }
        }
        while activeDays.contains(cursor) {
            current += 1
            cursor = cal.date(byAdding: .day, value: -1, to: cursor)!
        }
        return (current, longest)
    }

    private static func buildHeatmap(dayTokens: [Date: Int], range: AnalyticsRange,
                                     windowStart: Date?, today: Date,
                                     calendar cal: Calendar) -> [HeatCell] {
        // Determine the first day to show.
        let firstActivity = dayTokens.keys.min()
        let start: Date
        switch range {
        case .all:
            start = firstActivity ?? today
        case .thirtyDays, .sevenDays:
            start = windowStart ?? today
        }
        // Snap start back to the beginning of its week for a rectangular grid.
        let weekday = cal.component(.weekday, from: start) - cal.firstWeekday
        let gridStart = cal.date(byAdding: .day, value: -((weekday + 7) % 7), to: start) ?? start

        // Intensity thresholds from the non-zero token distribution.
        let values = dayTokens.values.filter { $0 > 0 }.sorted()
        func level(_ tokens: Int) -> Int {
            guard tokens > 0, !values.isEmpty else { return 0 }
            let q = { (p: Double) -> Int in values[min(values.count - 1, Int(Double(values.count) * p))] }
            switch tokens {
            case ..<q(0.25): return 1
            case ..<q(0.5): return 2
            case ..<q(0.9): return 3
            default: return 4
            }
        }

        var cells: [HeatCell] = []
        var day = gridStart
        while day <= today {
            let t = dayTokens[day] ?? 0
            cells.append(HeatCell(day: day, tokens: t, level: level(t)))
            day = cal.date(byAdding: .day, value: 1, to: day) ?? today.addingTimeInterval(86400)
            if cells.count > 400 { break } // safety bound (~14 months)
        }
        return cells
    }
}
