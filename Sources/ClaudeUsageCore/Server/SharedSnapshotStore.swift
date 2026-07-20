import Foundation

/// Publishes the latest snapshot for out-of-process readers — chiefly the **WidgetKit
/// extension**, which is sandboxed and can only reach data via a shared **App Group**.
///
/// Primary channel: `UserDefaults(suiteName: appGroupID)` (works once both the app and
/// the widget carry the `com.apple.security.application-groups` entitlement). Fallback:
/// a JSON file in Application Support, so the app/CLI can round-trip even before the
/// entitlement is configured.
public struct SharedSnapshotStore: Sendable {
    public static let appGroupID = "group.com.jhkoo.claude-usage-monitor"

    private let appGroupID: String
    private let fileURL: URL
    private let key = "latestSnapshot"

    public init(appGroupID: String = SharedSnapshotStore.appGroupID, fileURL: URL? = nil) {
        self.appGroupID = appGroupID
        self.fileURL = fileURL ?? AppPaths.supportDirectory.appendingPathComponent("latest-snapshot.json")
    }

    /// The App Group defaults, when the entitlement is present (otherwise `nil`).
    private var suite: UserDefaults? { UserDefaults(suiteName: appGroupID) }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()

    public func save(_ snapshot: UsageSnapshot) {
        guard let data = try? Self.encoder.encode(snapshot) else { return }
        suite?.set(data, forKey: key)
        AppPaths.ensureSupportDirectory()
        try? data.write(to: fileURL, options: .atomic)
    }

    public func load() -> UsageSnapshot? {
        if let data = suite?.data(forKey: key),
           let snapshot = try? Self.decoder.decode(UsageSnapshot.self, from: data) {
            return snapshot
        }
        if let data = try? Data(contentsOf: fileURL) {
            return try? Self.decoder.decode(UsageSnapshot.self, from: data)
        }
        return nil
    }
}
