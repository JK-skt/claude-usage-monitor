import Foundation

/// A single Claude usage rate-limit window as returned by `GET /api/oauth/usage`.
///
/// The endpoint returns several named windows (`five_hour`, `seven_day`,
/// `seven_day_opus`). Each window reports how much of the quota has been consumed
/// (`utilization`), when it resets (`resets_at`), and — when available — an absolute
/// `remaining` count.
///
/// - Note: The exact schema is undocumented (reverse-engineered from the Claude Code
///   2.1.x binary). Every field is therefore decoded defensively so a server-side
///   schema change degrades gracefully instead of crashing.
public struct RateLimitWindow: Codable, Sendable, Hashable {

    /// Percentage of the quota consumed in this window.
    ///
    /// Verified against the live `/api/oauth/usage` response: the API sends an integer
    /// **percentage** in `0...100` (e.g. `3` = 3% used). ``fractionUsed`` normalizes to
    /// `0...1`.
    public let utilization: Double?

    /// Absolute remaining allowance for the window, when the server provides it.
    public let remaining: Double?

    /// Timestamp at which this window's quota resets.
    public let resetsAt: Date?

    /// USD already spent in this window under pay-as-you-go billing, when the server
    /// reports it (`used_dollars`). Present for metered windows such as Fable.
    public let usedDollars: Double?

    /// USD ceiling / cap for this window (`limit_dollars`), when set.
    public let limitDollars: Double?

    /// USD budget still available (`remaining_dollars`), when set.
    public let remainingDollars: Double?

    public init(utilization: Double?, remaining: Double?, resetsAt: Date?,
                usedDollars: Double? = nil, limitDollars: Double? = nil,
                remainingDollars: Double? = nil) {
        self.utilization = utilization
        self.remaining = remaining
        self.resetsAt = resetsAt
        self.usedDollars = usedDollars
        self.limitDollars = limitDollars
        self.remainingDollars = remainingDollars
    }

    enum CodingKeys: String, CodingKey {
        case utilization
        case remaining
        case resetsAt = "resets_at"
        case usedDollars = "used_dollars"
        case limitDollars = "limit_dollars"
        case remainingDollars = "remaining_dollars"
    }

    /// Utilization normalized to `0...1`. The API sends an integer percentage (0...100).
    public var fractionUsed: Double {
        guard let utilization else { return 0 }
        return min(max(utilization / 100.0, 0), 1)
    }

    /// Percentage (0...100) of quota **remaining**.
    public var percentRemaining: Int {
        Int(((1.0 - fractionUsed) * 100).rounded())
    }

    /// Percentage (0...100) of quota **used**.
    public var percentUsed: Int {
        Int((fractionUsed * 100).rounded())
    }

    /// Time until the window resets, or `nil` if unknown / already elapsed.
    public func timeUntilReset(now: Date = Date()) -> TimeInterval? {
        guard let resetsAt else { return nil }
        let delta = resetsAt.timeIntervalSince(now)
        return delta > 0 ? delta : nil
    }
}
