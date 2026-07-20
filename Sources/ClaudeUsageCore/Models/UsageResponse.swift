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
    /// Metered (pay-as-you-go) spend to date, when the account has usage-based billing.
    /// This is where Fable's per-token charges surface once the server reports them.
    public let spend: Spend?

    public init(
        fiveHour: RateLimitWindow?,
        sevenDay: RateLimitWindow?,
        sevenDayOpus: RateLimitWindow?,
        overage: Overage?,
        limits: [UsageLimit] = [],
        spend: Spend? = nil
    ) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.sevenDayOpus = sevenDayOpus
        self.overage = overage
        self.limits = limits
        self.spend = spend
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fiveHour = try c.decodeIfPresent(RateLimitWindow.self, forKey: .fiveHour)
        sevenDay = try c.decodeIfPresent(RateLimitWindow.self, forKey: .sevenDay)
        sevenDayOpus = try c.decodeIfPresent(RateLimitWindow.self, forKey: .sevenDayOpus)
        overage = try c.decodeIfPresent(Overage.self, forKey: .overage)
        limits = try c.decodeIfPresent([UsageLimit].self, forKey: .limits) ?? []
        spend = try c.decodeIfPresent(Spend.self, forKey: .spend)
    }

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case overage
        case limits
        case spend
    }

    /// The `spend` object: accrued metered charges (e.g. usage credits) and any cap.
    /// Amounts are minor-unit encoded (`amount_minor` + `exponent`), e.g. 1234 with
    /// exponent 2 → $12.34.
    public struct Spend: Codable, Sendable, Hashable {
        public let enabled: Bool?
        public let percent: Double?
        public let severity: String?
        public let used: Money?
        public let limit: Money?

        public init(enabled: Bool?, percent: Double?, severity: String?,
                    used: Money?, limit: Money?) {
            self.enabled = enabled
            self.percent = percent
            self.severity = severity
            self.used = used
            self.limit = limit
        }

        /// Spend to date in dollars, if reported.
        public var usedDollars: Double? { used?.dollars }
        /// Spend cap in dollars, if set.
        public var limitDollars: Double? { limit?.dollars }

        public struct Money: Codable, Sendable, Hashable {
            public let amountMinor: Double?
            public let currency: String?
            public let exponent: Int?

            public init(amountMinor: Double?, currency: String?, exponent: Int?) {
                self.amountMinor = amountMinor
                self.currency = currency
                self.exponent = exponent
            }

            enum CodingKeys: String, CodingKey {
                case amountMinor = "amount_minor"
                case currency, exponent
            }

            /// Minor units converted to the major unit (dollars), e.g. 1234@exp2 → 12.34.
            public var dollars: Double? {
                guard let amountMinor else { return nil }
                return amountMinor / pow(10.0, Double(exponent ?? 2))
            }
        }
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
