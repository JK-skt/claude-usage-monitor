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
    private let pinFileURL: URL
    private let key = "latestSnapshot"
    private let pinKey = "headlineMetricID"

    public init(appGroupID: String = SharedSnapshotStore.appGroupID, fileURL: URL? = nil) {
        self.appGroupID = appGroupID
        self.fileURL = fileURL ?? AppPaths.supportDirectory.appendingPathComponent("latest-snapshot.json")
        self.pinFileURL = AppPaths.supportDirectory.appendingPathComponent("headline-pin.txt")
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

    /// Publishes the user's pinned headline metric id ("" = auto) so out-of-process
    /// readers (the widget) render the same "main usage" window as the app.
    public func saveHeadlinePin(_ id: String) {
        suite?.set(id, forKey: pinKey)
        AppPaths.ensureSupportDirectory()
        try? Data(id.utf8).write(to: pinFileURL, options: .atomic)
    }

    /// The pinned headline metric id, or "" (auto) when unset.
    public func loadHeadlinePin() -> String {
        if let id = suite?.string(forKey: pinKey) { return id }
        if let data = try? Data(contentsOf: pinFileURL), let id = String(data: data, encoding: .utf8) {
            return id
        }
        return ""
    }
}
