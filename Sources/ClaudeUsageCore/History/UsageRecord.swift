import Foundation

/// A compact, persisted point-in-time usage sample. One JSON object per line in the
/// history file (JSONL) — append-only, cheap to write, streamable to read.
public struct UsageRecord: Codable, Sendable, Hashable {
    public let timestamp: Date
    public let plan: String
    /// Headline quota remaining (0…100). `nil` when the account is fully metered.
    public let percentRemaining: Int
    public let percentUsed: Int
    public let meteredSpend: Double?
    public let nextReset: Date?
    public let metrics: [Metric]

    public struct Metric: Codable, Sendable, Hashable {
        public let id: String
        public let label: String
        public let fractionUsed: Double
        public let isMetered: Bool
        public let usedDollars: Double?

        public init(id: String, label: String, fractionUsed: Double,
                    isMetered: Bool, usedDollars: Double?) {
            self.id = id
            self.label = label
            self.fractionUsed = fractionUsed
            self.isMetered = isMetered
            self.usedDollars = usedDollars
        }
    }

    public init(timestamp: Date, plan: String, percentRemaining: Int, percentUsed: Int,
                meteredSpend: Double?, nextReset: Date?, metrics: [Metric]) {
        self.timestamp = timestamp
        self.plan = plan
        self.percentRemaining = percentRemaining
        self.percentUsed = percentUsed
        self.meteredSpend = meteredSpend
        self.nextReset = nextReset
        self.metrics = metrics
    }

    public init(from snapshot: UsageSnapshot) {
        self.init(
            timestamp: snapshot.capturedAt,
            plan: snapshot.planName,
            percentRemaining: snapshot.percentRemaining,
            percentUsed: snapshot.percentUsed,
            meteredSpend: snapshot.meteredSpend,
            nextReset: snapshot.nextReset,
            metrics: snapshot.metrics.map {
                Metric(id: $0.id, label: $0.label, fractionUsed: $0.fractionUsed,
                       isMetered: $0.isMetered, usedDollars: $0.usedDollars)
            }
        )
    }
}
