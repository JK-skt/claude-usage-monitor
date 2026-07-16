import Foundation

/// OAuth credentials as stored by Claude Code in the macOS Keychain under the
/// generic-password item `Claude Code-credentials` (account = current macOS user).
///
/// Observed JSON shape:
/// ```json
/// { "claudeAiOauth": {
///     "accessToken": "…",
///     "refreshToken": "…",
///     "expiresAt": 1777385989340,   // epoch milliseconds
///     "scopes": ["user:inference", "user:profile"],
///     "subscriptionType": "max"
/// } }
/// ```
public struct OAuthCredentials: Codable, Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String?
    /// Expiry as epoch milliseconds (Claude Code stores ms, not seconds).
    public let expiresAtMillis: Double?
    public let scopes: [String]?
    public let subscriptionType: String?

    enum CodingKeys: String, CodingKey {
        case accessToken
        case refreshToken
        case expiresAtMillis = "expiresAt"
        case scopes
        case subscriptionType
    }

    /// Wrapper matching the on-disk/Keychain top-level `{ "claudeAiOauth": { … } }`.
    struct Envelope: Codable {
        let claudeAiOauth: OAuthCredentials
    }

    public var expiresAt: Date? {
        guard let expiresAtMillis else { return nil }
        return Date(timeIntervalSince1970: expiresAtMillis / 1000.0)
    }

    /// True when the access token is expired or within `leeway` of expiring.
    public func isExpired(now: Date = Date(), leeway: TimeInterval = 60) -> Bool {
        guard let expiresAt else { return false } // unknown expiry → assume usable
        return now.addingTimeInterval(leeway) >= expiresAt
    }

    /// Decodes credentials from raw Keychain data, tolerating both the enveloped
    /// (`{ "claudeAiOauth": {…} }`) and bare (`{ "accessToken": … }`) forms.
    public static func decode(from data: Data) throws -> OAuthCredentials {
        let decoder = JSONDecoder()
        if let env = try? decoder.decode(Envelope.self, from: data) {
            return env.claudeAiOauth
        }
        return try decoder.decode(OAuthCredentials.self, from: data)
    }
}
