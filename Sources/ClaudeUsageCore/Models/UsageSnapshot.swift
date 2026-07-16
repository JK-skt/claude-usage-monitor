import Foundation

/// A normalized, display-ready usage window (from either the modern `limits` array or
/// the legacy top-level windows). This is what the menu / CLI iterate over.
public struct UsageMetric: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let label: String
    /// `0...1` consumed.
    public let fractionUsed: Double
    public let resetsAt: Date?
    public let isActive: Bool
    /// Present when the metric is scoped to a specific model (e.g. "Fable").
    public let modelName: String?

    public init(id: String, label: String, fractionUsed: Double,
                resetsAt: Date?, isActive: Bool, modelName: String?) {
        self.id = id
        self.label = label
        self.fractionUsed = fractionUsed
        self.resetsAt = resetsAt
        self.isActive = isActive
        self.modelName = modelName
    }

    public var percentUsed: Int { Int((fractionUsed * 100).rounded()) }
    public var percentRemaining: Int { 100 - percentUsed }
}

/// The app-facing, fully-resolved view of usage at a point in time.
/// Combines live rate-limit data with static account context.
public struct UsageSnapshot: Sendable, Hashable, Codable {
    public let capturedAt: Date
    public let account: AccountInfo?
    public let usage: UsageResponse

    public init(capturedAt: Date, account: AccountInfo?, usage: UsageResponse) {
        self.capturedAt = capturedAt
        self.account = account
        self.usage = usage
    }

    /// All usage windows, normalized. Prefers the modern `limits` array; falls back to
    /// the legacy top-level windows only when `limits` is empty.
    public var metrics: [UsageMetric] {
        if !usage.limits.isEmpty {
            return usage.limits.map { limit in
                UsageMetric(
                    id: limit.id,
                    label: limit.displayLabel,
                    fractionUsed: limit.fractionUsed,
                    resetsAt: limit.resetsAt,
                    isActive: limit.isActive ?? false,
                    modelName: limit.modelName
                )
            }
        }
        var out: [UsageMetric] = []
        func add(_ id: String, _ label: String, _ w: RateLimitWindow?) {
            guard let w else { return }
            out.append(UsageMetric(id: id, label: label, fractionUsed: w.fractionUsed,
                                   resetsAt: w.resetsAt, isActive: false, modelName: nil))
        }
        add("five_hour", "Session (5h)", usage.fiveHour)
        add("seven_day", "Weekly (all models)", usage.sevenDay)
        add("seven_day_opus", "Opus (weekly)", usage.sevenDayOpus)
        return out
    }

    /// Metrics scoped to a specific model (e.g. Fable, Opus).
    public var modelMetrics: [UsageMetric] {
        metrics.filter { $0.modelName != nil }
    }

    /// Convenience lookup for a specific model's usage (case-insensitive).
    public func metric(forModel name: String) -> UsageMetric? {
        metrics.first { $0.modelName?.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// The window driving the headline: the most-consumed metric (the one the user
    /// will hit first).
    public var headlineMetric: UsageMetric? {
        metrics.max(by: { $0.fractionUsed < $1.fractionUsed })
    }

    public var percentRemaining: Int {
        headlineMetric?.percentRemaining ?? 100
    }

    public var percentUsed: Int {
        headlineMetric?.percentUsed ?? 0
    }

    /// Soonest reset across all windows.
    public var nextReset: Date? {
        metrics.compactMap { $0.resetsAt }.min()
    }

    public var planName: String {
        account?.planDisplayName ?? "Claude"
    }

    /// Severity bucket for menu-bar tinting and notification thresholds.
    public enum Severity: String, Sendable {
        case green, yellow, orange, red, critical
    }

    public var severity: Severity {
        switch percentRemaining {
        case 50...: return .green
        case 20..<50: return .yellow
        case 10..<20: return .orange
        case 5..<10: return .red
        default: return .critical
        }
    }
}
