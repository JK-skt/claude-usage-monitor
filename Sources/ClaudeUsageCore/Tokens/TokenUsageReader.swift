import Foundation

/// Aggregated token counts (a running tally you can add samples into).
public struct TokenTotals: Sendable, Equatable, Codable {
    public var messages = 0
    public var input = 0
    public var output = 0
    public var cacheCreation = 0
    public var cacheRead = 0

    public init() {}

    /// Fresh, non-cached tokens the model actually produced/consumed.
    public var inputPlusOutput: Int { input + output }
    /// Everything, including cache creation/read.
    public var grandTotal: Int { input + output + cacheCreation + cacheRead }

    public mutating func add(_ s: TokenSample) {
        messages += 1
        input += s.input
        output += s.output
        cacheCreation += s.cacheCreation
        cacheRead += s.cacheRead
    }
}

public struct TokenSample: Sendable {
    public let timestamp: Date
    public let model: String?
    public let project: String?
    /// Which application produced these tokens (derived from the log `entrypoint`),
    /// e.g. "Claude Code (VS Code)", "Claude Code (CLI)".
    public let source: String
    public let input: Int
    public let output: Int
    public let cacheCreation: Int
    public let cacheRead: Int
    /// The conversation/session this sample belongs to (log `sessionId`, else the log
    /// file's name) — used to count distinct sessions in analytics.
    public let sessionID: String?

    public init(timestamp: Date, model: String?, project: String?, source: String,
                input: Int, output: Int, cacheCreation: Int, cacheRead: Int,
                sessionID: String? = nil) {
        self.timestamp = timestamp
        self.model = model
        self.project = project
        self.source = source
        self.input = input
        self.output = output
        self.cacheCreation = cacheCreation
        self.cacheRead = cacheRead
        self.sessionID = sessionID
    }

    /// Maps a Claude Code `entrypoint` to a human-readable application/source label.
    public static func sourceName(entrypoint: String?) -> String {
        switch entrypoint {
        case "cli": return "Claude Code (CLI)"
        case "claude-vscode", "vscode": return "Claude Code (VS Code)"
        case "claude-desktop", "desktop": return "Claude Code (Desktop)"
        case .some(let e) where e.contains("jetbrains") || e.contains("intellij"):
            return "Claude Code (JetBrains)"
        case .some(let e) where !e.isEmpty: return "Claude Code (\(e))"
        default: return "Claude Code"
        }
    }
}

public struct NamedTotals: Sendable, Codable, Identifiable {
    public let name: String
    public let totals: TokenTotals
    public var id: String { name }
}

/// A token-usage report over a recent window, plus a "today" subset and breakdowns.
public struct TokenReport: Sendable, Codable {
    public let generatedAt: Date
    public let windowDays: Int
    public let window: TokenTotals
    public let today: TokenTotals
    public let byModel: [NamedTotals]
    public let byProject: [NamedTotals]
    /// Token totals grouped by originating application (Claude Code entrypoint).
    public let bySource: [NamedTotals]
    public let byDay: [NamedTotals]
}

/// Token totals over an arbitrary recent window (hours), split by model and by source.
/// Backs the Analytics tab's 5h / 24h / 7d segments.
public struct TokenBreakdown: Sendable, Codable {
    public let hours: Double
    public let total: TokenTotals
    public let byModel: [NamedTotals]
    public let bySource: [NamedTotals]

    public var isEmpty: Bool { total.messages == 0 }
}

/// Reads Claude Code's local session transcripts (`~/.claude/projects/**/*.jsonl`) and
/// aggregates real token usage. This is a *different* data source from the usage API
/// (which reports only percentages/dollars, never token counts).
public actor TokenUsageReader {
    private let projectsDir: URL

    public init(projectsDir: URL? = nil) {
        self.projectsDir = projectsDir
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    /// Token totals over the last `hours`, grouped by model and by originating app.
    /// Hour-granular (unlike ``report(now:windowDays:)``) so the UI can offer 5h / 24h / 7d.
    public func breakdown(hours: Double, now: Date = Date()) -> TokenBreakdown {
        let since = now.addingTimeInterval(-hours * 3600)
        let samples = readSamples(since: since).filter { $0.timestamp >= since }

        var total = TokenTotals()
        var models: [String: TokenTotals] = [:]
        var sources: [String: TokenTotals] = [:]
        for s in samples {
            total.add(s)
            models[ModelDisplayName.pretty(s.model), default: TokenTotals()].add(s)
            sources[s.source, default: TokenTotals()].add(s)
        }
        func ranked(_ d: [String: TokenTotals]) -> [NamedTotals] {
            d.map { NamedTotals(name: $0.key, totals: $0.value) }
                .filter { $0.totals.grandTotal > 0 }
                .sorted { $0.totals.inputPlusOutput > $1.totals.inputPlusOutput }
        }
        return TokenBreakdown(hours: hours, total: total,
                              byModel: ranked(models), bySource: ranked(sources))
    }

    /// Raw samples for an analytics range (`nil` days = all history), then folded into a
    /// full ``UsageAnalytics`` report. Reading + aggregation both run on this actor,
    /// off the main thread.
    public func analytics(range: AnalyticsRange, now: Date = Date()) -> UsageAnalytics {
        let cal = Calendar.current
        let since: Date? = range.days.map {
            let start = cal.startOfDay(for: now)
            return cal.date(byAdding: .day, value: -($0 - 1), to: start) ?? start
        }
        let samples = readSamples(since: since)
        return UsageAnalyticsBuilder.build(from: samples, range: range, now: now, calendar: cal)
    }

    public func report(now: Date = Date(), windowDays: Int = 7) -> TokenReport {
        let cal = Calendar.current
        let startToday = cal.startOfDay(for: now)
        let windowStart = cal.date(byAdding: .day, value: -(windowDays - 1), to: startToday) ?? startToday
        let samples = readSamples(since: windowStart)

        var window = TokenTotals(), today = TokenTotals()
        var models: [String: TokenTotals] = [:]
        var projects: [String: TokenTotals] = [:]
        var sources: [String: TokenTotals] = [:]
        var days: [String: TokenTotals] = [:]
        let dayFmt = DateFormatter()
        dayFmt.dateFormat = "yyyy-MM-dd"
        dayFmt.calendar = cal
        dayFmt.timeZone = cal.timeZone

        for s in samples {
            window.add(s)
            if s.timestamp >= startToday { today.add(s) }
            models[s.model ?? "unknown", default: TokenTotals()].add(s)
            projects[s.project ?? "unknown", default: TokenTotals()].add(s)
            sources[s.source, default: TokenTotals()].add(s)
            days[dayFmt.string(from: s.timestamp), default: TokenTotals()].add(s)
        }

        func ranked(_ dict: [String: TokenTotals], limit: Int? = nil) -> [NamedTotals] {
            let sorted = dict.map { NamedTotals(name: $0.key, totals: $0.value) }
                .filter { $0.totals.grandTotal > 0 }   // drop synthetic/empty entries
                .sorted { $0.totals.inputPlusOutput > $1.totals.inputPlusOutput }
            return limit.map { Array(sorted.prefix($0)) } ?? sorted
        }

        return TokenReport(
            generatedAt: now,
            windowDays: windowDays,
            window: window,
            today: today,
            byModel: ranked(models),
            byProject: ranked(projects, limit: 8),
            bySource: ranked(sources),
            byDay: days.map { NamedTotals(name: $0.key, totals: $0.value) }.sorted { $0.name < $1.name }
        )
    }

    /// Parses assistant messages with a `usage` block, keeping samples at/after `since`.
    /// Skips whole files whose modification time predates `since`.
    func readSamples(since: Date?) -> [TokenSample] {
        guard let files = try? FileManager.default.subpathsOfDirectory(atPath: projectsDir.path) else {
            return []
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]

        var out: [TokenSample] = []
        for rel in files where rel.hasSuffix(".jsonl") {
            let url = projectsDir.appendingPathComponent(rel)
            if let since,
               let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let mtime = attrs[.modificationDate] as? Date,
               mtime < since {
                continue
            }
            guard let data = try? Data(contentsOf: url) else { continue }
            for line in data.split(separator: 0x0A) where !line.isEmpty {
                guard
                    let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                    (obj["type"] as? String) == "assistant",
                    let message = obj["message"] as? [String: Any],
                    let usage = message["usage"] as? [String: Any]
                else { continue }

                let tsString = obj["timestamp"] as? String ?? ""
                let ts = iso.date(from: tsString) ?? isoPlain.date(from: tsString) ?? Date.distantPast
                if let since, ts < since { continue }

                func i(_ k: String) -> Int { (usage[k] as? Int) ?? 0 }
                let cwd = obj["cwd"] as? String
                // Session identity: the log's own sessionId, else the file name (each
                // Claude Code transcript file is one session).
                let sessionID = (obj["sessionId"] as? String)
                    ?? (rel as NSString).lastPathComponent.replacingOccurrences(of: ".jsonl", with: "")
                out.append(TokenSample(
                    timestamp: ts,
                    model: message["model"] as? String,
                    project: cwd.map { URL(fileURLWithPath: $0).lastPathComponent },
                    source: TokenSample.sourceName(entrypoint: obj["entrypoint"] as? String),
                    input: i("input_tokens"),
                    output: i("output_tokens"),
                    cacheCreation: i("cache_creation_input_tokens"),
                    cacheRead: i("cache_read_input_tokens"),
                    sessionID: sessionID
                ))
            }
        }
        return out
    }
}
