import Foundation

/// Raw decoded body of `GET https://api.anthropic.com/api/oauth/usage`.
///
/// Reverse-engineered field set (Claude Code 2.1.121):
/// `five_hour`, `seven_day`, `seven_day_opus`, `overage`.
///
/// All windows are optional: a given plan may not expose every window, and the
/// server may add or remove windows over time.
public struct UsageResponse: Codable, Sendable, Hashable {
    /// Rolling 5-hour session window (the primary short-term limit).
    public let fiveHour: RateLimitWindow?
    /// Rolling 7-day window (aggregate weekly limit).
    public let sevenDay: RateLimitWindow?
    /// Rolling 7-day window specific to Opus-class models.
    public let sevenDayOpus: RateLimitWindow?
    /// Overage / extra-usage state, when the account has it enabled.
    public let overage: Overage?
    /// The modern, authoritative `limits` array — includes per-model (scoped) windows
    /// such as Fable. Preferred over the legacy top-level windows when present.
    public let limits: [UsageLimit]

    public init(
        fiveHour: RateLimitWindow?,
        sevenDay: RateLimitWindow?,
        sevenDayOpus: RateLimitWindow?,
        overage: Overage?,
        limits: [UsageLimit] = []
    ) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.sevenDayOpus = sevenDayOpus
        self.overage = overage
        self.limits = limits
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fiveHour = try c.decodeIfPresent(RateLimitWindow.self, forKey: .fiveHour)
        sevenDay = try c.decodeIfPresent(RateLimitWindow.self, forKey: .sevenDay)
        sevenDayOpus = try c.decodeIfPresent(RateLimitWindow.self, forKey: .sevenDayOpus)
        overage = try c.decodeIfPresent(Overage.self, forKey: .overage)
        limits = try c.decodeIfPresent([UsageLimit].self, forKey: .limits) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case overage
        case limits
    }

    public struct Overage: Codable, Sendable, Hashable {
        public let status: String?
        public let resetsAt: Date?

        public init(status: String?, resetsAt: Date?) {
            self.status = status
            self.resetsAt = resetsAt
        }

        enum CodingKeys: String, CodingKey {
            case status
            case resetsAt = "resets_at"
        }
    }
}
