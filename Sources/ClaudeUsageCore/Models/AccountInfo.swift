import Foundation

/// Static account context read from `~/.claude.json` (`oauthAccount`) — no network,
/// no secrets. Provides plan/organization identity to display alongside live usage.
public struct AccountInfo: Codable, Sendable, Hashable {
    public let accountUuid: String?
    public let organizationUuid: String?
    public let emailAddress: String?
    public let displayName: String?
    public let organizationName: String?
    /// e.g. `claude_max`, `claude_pro`, `claude_team`.
    public let organizationType: String?
    /// e.g. `default_claude_max_20x` — the concrete rate-limit tier.
    public let organizationRateLimitTier: String?
    public let billingType: String?
    public let hasExtraUsageEnabled: Bool?

    public init(
        accountUuid: String?,
        organizationUuid: String?,
        emailAddress: String?,
        displayName: String?,
        organizationName: String?,
        organizationType: String?,
        organizationRateLimitTier: String?,
        billingType: String?,
        hasExtraUsageEnabled: Bool?
    ) {
        self.accountUuid = accountUuid
        self.organizationUuid = organizationUuid
        self.emailAddress = emailAddress
        self.displayName = displayName
        self.organizationName = organizationName
        self.organizationType = organizationType
        self.organizationRateLimitTier = organizationRateLimitTier
        self.billingType = billingType
        self.hasExtraUsageEnabled = hasExtraUsageEnabled
    }

    enum CodingKeys: String, CodingKey {
        case accountUuid
        case organizationUuid
        case emailAddress
        case displayName
        case organizationName
        case organizationType
        case organizationRateLimitTier
        case billingType
        case hasExtraUsageEnabled
    }

    /// Human-friendly plan label, e.g. "Max 20×", "Pro", "Team".
    public var planDisplayName: String {
        let type = (organizationType ?? "").replacingOccurrences(of: "claude_", with: "")
        let base: String
        switch type {
        case "max": base = "Max"
        case "pro": base = "Pro"
        case "team": base = "Team"
        case "enterprise": base = "Enterprise"
        case "": base = "Claude"
        default: base = type.capitalized
        }
        if let tier = organizationRateLimitTier,
           let multiplier = Self.multiplier(from: tier) {
            return "\(base) \(multiplier)"
        }
        return base
    }

    /// Extracts a "20×"-style multiplier from a tier string like `default_claude_max_20x`.
    static func multiplier(from tier: String) -> String? {
        guard let range = tier.range(of: #"(\d+)x"#, options: .regularExpression) else {
            return nil
        }
        return tier[range].replacingOccurrences(of: "x", with: "×")
    }
}
