import Foundation

/// Forecast derived from recent history: how fast quota is being consumed and when it
/// will run out at the current rate.
public struct UsagePrediction: Sendable, Equatable {
    /// Percentage points of quota consumed per hour (headline window).
    public let ratePerHour: Double
    public let ratePerDay: Double
    public let ratePerWeek: Double
    /// Hours until the headline quota is exhausted at the current rate (`nil` if flat/declining).
    public let hoursUntilExhaustion: Double?
    /// Absolute time of predicted exhaustion (`nil` if not applicable).
    public let exhaustionAt: Date?
    /// Number of samples in the current (post-reset) run used for the fit.
    public let sampleCount: Int

    public var isActionable: Bool { hoursUntilExhaustion != nil }
}

public enum UsagePredictor {
    /// Predicts from history. Uses only the samples since the most recent reset (where
    /// `percentUsed` dropped), fitting a least-squares line of used% over time.
    public static func predict(_ history: [UsageRecord], now: Date = Date()) -> UsagePrediction? {
        let sorted = history.sorted { $0.timestamp < $1.timestamp }
        let run = currentRun(sorted)
        guard run.count >= 2 else { return nil }

        // x = hours since the run start; y = percentUsed.
        let t0 = run[0].timestamp
        let xs = run.map { $0.timestamp.timeIntervalSince(t0) / 3600.0 }
        let ys = run.map { Double($0.percentUsed) }
        guard let slope = leastSquaresSlope(xs: xs, ys: ys), slope.isFinite else { return nil }

        let ratePerHour = max(0, slope)
        let latest = run[run.count - 1]
        let remaining = Double(100 - latest.percentUsed)

        var hours: Double?
        var at: Date?
        if slope > 0.001 && remaining > 0 {
            let h = remaining / slope
            hours = h
            at = latest.timestamp.addingTimeInterval(h * 3600)
        }

        return UsagePrediction(
            ratePerHour: ratePerHour,
            ratePerDay: ratePerHour * 24,
            ratePerWeek: ratePerHour * 24 * 7,
            hoursUntilExhaustion: hours,
            exhaustionAt: at,
            sampleCount: run.count
        )
    }

    /// The trailing subsequence over which `percentUsed` is non-decreasing — i.e. the
    /// samples accumulated since the last quota reset.
    public static func currentRun(_ sorted: [UsageRecord]) -> [UsageRecord] {
        guard !sorted.isEmpty else { return [] }
        var start = sorted.count - 1
        while start > 0 {
            // A reset shows up as a drop: earlier used% greater than the following one.
            if sorted[start - 1].percentUsed <= sorted[start].percentUsed {
                start -= 1
            } else {
                break
            }
        }
        return Array(sorted[start...])
    }

    static func leastSquaresSlope(xs: [Double], ys: [Double]) -> Double? {
        let n = Double(xs.count)
        guard n >= 2 else { return nil }
        let sumX = xs.reduce(0, +)
        let sumY = ys.reduce(0, +)
        let sumXY = zip(xs, ys).reduce(0) { $0 + $1.0 * $1.1 }
        let sumXX = xs.reduce(0) { $0 + $1 * $1 }
        let denom = n * sumXX - sumX * sumX
        guard abs(denom) > 1e-9 else { return nil }
        return (n * sumXY - sumX * sumY) / denom
    }
}
