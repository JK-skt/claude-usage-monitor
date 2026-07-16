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
    private let credentials: CredentialProviding
    private let client: UsageAPIClient
    private let accountReader: LocalAccountReader

    public init(
        credentials: CredentialProviding = KeychainCredentialStore(),
        client: UsageAPIClient = UsageAPIClient(),
        accountReader: LocalAccountReader = LocalAccountReader()
    ) {
        self.credentials = credentials
        self.client = client
        self.accountReader = accountReader
    }

    public func currentUsage() async throws -> UsageSnapshot {
        let creds = try credentials.loadCredentials()

        // Token refresh is a documented follow-up (see docs/AUTH.md). For now we surface
        // an actionable error rather than silently returning stale data.
        if creds.isExpired() {
            throw APIError.unauthorized
        }

        let result = try await client.fetchUsage(accessToken: creds.accessToken)
        let account = accountReader.read()

        return UsageSnapshot(
            capturedAt: Date(),
            account: account,
            usage: result.usage
        )
    }
}
