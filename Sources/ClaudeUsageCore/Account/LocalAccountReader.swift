import Foundation

/// Reads static account context from `~/.claude.json`'s `oauthAccount` object.
/// Pure local file read — no network, no secrets exposed.
public struct LocalAccountReader: Sendable {
    private let configURL: URL

    public init(configURL: URL? = nil) {
        self.configURL = configURL
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude.json")
    }

    /// Returns the account info, or `nil` if the file is missing / lacks `oauthAccount`.
    /// Never throws for a missing file — account context is best-effort enrichment.
    public func read() -> AccountInfo? {
        guard let data = try? Data(contentsOf: configURL) else { return nil }
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = root["oauthAccount"] as? [String: Any]
        else { return nil }

        let account = try? JSONSerialization.data(withJSONObject: oauth)
        guard let account else { return nil }
        return try? JSONDecoder().decode(AccountInfo.self, from: account)
    }
}
