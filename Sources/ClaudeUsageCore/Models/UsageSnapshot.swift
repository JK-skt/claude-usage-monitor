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
    /// Known per-token pricing for the model, shown as context (e.g. Fable's rate).
    public let pricing: ModelPricing?
    /// USD spent so far, when the server bills this metric by usage.
    public let usedDollars: Double?
    /// Whether the metric currently has a percentage quota (a bounded available resource).
    public let hasQuota: Bool
    /// Whether the server is billing this metric by usage right now (reports dollars).
    public let isMetered: Bool

    public init(id: String, label: String, fractionUsed: Double,
                resetsAt: Date?, isActive: Bool, modelName: String?,
                pricing: ModelPricing? = nil, usedDollars: Double? = nil,
                hasQuota: Bool = true, isMetered: Bool = false) {
        self.id = id
        self.label = label
        self.fractionUsed = fractionUsed
        self.resetsAt = resetsAt
        self.isActive = isActive
        self.modelName = modelName
        self.pricing = pricing
        self.usedDollars = usedDollars
        self.hasQuota = hasQuota
        self.isMetered = isMetered
    }

    public var percentUsed: Int { Int((fractionUsed * 100).rounded()) }
    public var percentRemaining: Int { 100 - percentUsed }

    /// Spend to date rendered for display (e.g. "$0.00"), or `nil` if not metered / unknown.
    public var spendText: String? {
        guard isMetered else { return nil }
        return ModelPricing.formatUSD(usedDollars ?? 0)
    }
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
                    modelName: limit.modelName,
                    pricing: limit.pricing,
                    usedDollars: limit.usedDollars,
                    hasQuota: limit.hasQuota,
                    isMetered: limit.isMetered
                )
            }
        }
        var out: [UsageMetric] = []
        func add(_ id: String, _ label: String, _ w: RateLimitWindow?) {
            guard let w else { return }
            out.append(UsageMetric(id: id, label: label, fractionUsed: w.fractionUsed,
                                   resetsAt: w.resetsAt, isActive: false, modelName: nil,
                                   hasQuota: true, isMetered: false))
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

    /// Metered (pay-as-you-go) metrics, e.g. Fable under per-token billing.
    public var meteredMetrics: [UsageMetric] {
        metrics.filter { $0.isMetered }
    }

    /// Total metered spend to date across all usage-based metrics (USD), if any.
    public var meteredSpend: Double? {
        let dollars = meteredMetrics.compactMap { $0.usedDollars }
        return dollars.isEmpty ? nil : dollars.reduce(0, +)
    }

    /// Convenience lookup for a specific model's usage (case-insensitive).
    public func metric(forModel name: String) -> UsageMetric? {
        metrics.first { $0.modelName?.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Quota metrics eligible to drive the headline (metered/spend windows excluded —
    /// they have no "% remaining", only a dollar amount).
    public var headlineCandidates: [UsageMetric] {
        metrics.filter { $0.hasQuota }
    }

    /// The window driving the headline: the most-consumed *quota* metric (the one the
    /// user will hit first). Windows without a quota (pure metered spend) are excluded —
    /// their pressure is a dollar amount, surfaced via ``meteredSpend``.
    public var headlineMetric: UsageMetric? {
        headlineMetric(pinnedID: nil)
    }

    /// The headline metric honoring a user-pinned selection by metric `id`. When
    /// `pinnedID` is empty/nil or no longer present in the current snapshot, falls back
    /// to the most-consumed quota metric (the auto behavior).
    public func headlineMetric(pinnedID: String?) -> UsageMetric? {
        let candidates = headlineCandidates
        if let pinnedID, !pinnedID.isEmpty,
           let pinned = candidates.first(where: { $0.id == pinnedID }) {
            return pinned
        }
        return candidates.max(by: { $0.fractionUsed < $1.fractionUsed })
    }

    public var percentRemaining: Int {
        headlineMetric?.percentRemaining ?? 100
    }

    public var percentUsed: Int {
        headlineMetric?.percentUsed ?? 0
    }

    /// Headline "% remaining" for a pinned selection (see ``headlineMetric(pinnedID:)``).
    public func percentRemaining(pinnedID: String?) -> Int {
        headlineMetric(pinnedID: pinnedID)?.percentRemaining ?? 100
    }

    /// Headline "% used" for a pinned selection.
    public func percentUsed(pinnedID: String?) -> Int {
        headlineMetric(pinnedID: pinnedID)?.percentUsed ?? 0
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
        Self.severity(forRemaining: percentRemaining)
    }

    /// Severity for a pinned headline selection.
    public func severity(pinnedID: String?) -> Severity {
        Self.severity(forRemaining: percentRemaining(pinnedID: pinnedID))
    }

    /// Maps a "% remaining" value to a severity bucket.
    public static func severity(forRemaining remaining: Int) -> Severity {
        switch remaining {
        case 50...: return .green
        case 20..<50: return .yellow
        case 10..<20: return .orange
        case 5..<10: return .red
        default: return .critical
        }
    }
}
