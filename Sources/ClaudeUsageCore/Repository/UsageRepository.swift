import Foundation

/// Orchestrates the full read path:
/// Keychain credentials → `/api/oauth/usage` → merge with local account context
/// → ``UsageSnapshot``.
///
/// This is the single seam the UI, CLI, and exporters all depend on.
public protocol UsageRepositoryProtocol: Sendable {
    func currentUsage() async throws -> UsageSnapshot
}

public actor UsageRepository: UsageRepositoryProtocol {
    private let credentialProvider: CredentialProviding
    private let client: UsageAPIClient
    private let accountReader: LocalAccountReader

    /// In-memory credential cache. Reading the secret from the Keychain can be
    /// comparatively expensive (and may involve an ACL check), so we hold the token in
    /// memory and only re-read when it's missing or close to expiring.
    private var cachedCredentials: OAuthCredentials?

    public init(
        credentials: CredentialProviding = KeychainCredentialStore(),
        client: UsageAPIClient = UsageAPIClient(),
        accountReader: LocalAccountReader = LocalAccountReader()
    ) {
        self.credentialProvider = credentials
        self.client = client
        self.accountReader = accountReader
    }

    public func currentUsage() async throws -> UsageSnapshot {
        let creds = try loadCredentials()

        if creds.isExpired() {
            cachedCredentials = nil
            throw APIError.unauthorized
        }

        do {
            let result = try await client.fetchUsage(accessToken: creds.accessToken)
            let account = accountReader.read()
            return UsageSnapshot(capturedAt: Date(), account: account, usage: result.usage)
        } catch APIError.unauthorized {
            // The token may have been rotated by Claude Code out from under us.
            // Drop the cache so the next poll re-reads the (refreshed) Keychain value.
            cachedCredentials = nil
            throw APIError.unauthorized
        }
    }

    /// Returns cached credentials when still comfortably valid, otherwise re-reads them.
    private func loadCredentials() throws -> OAuthCredentials {
        if let cached = cachedCredentials, !cached.isExpired(leeway: 120) {
            return cached
        }
        let fresh = try credentialProvider.loadCredentials()
        cachedCredentials = fresh
        return fresh
    }
}
