import Foundation

/// One entry of the `limits` array in the `/api/oauth/usage` response — the modern,
/// authoritative representation of a rate-limit window.
///
/// Verified live schema:
/// ```json
/// { "group": "weekly", "kind": "weekly_scoped", "is_active": true,
///   "percent": 8, "resets_at": "2026-07-22T12:59:59Z", "severity": "normal",
///   "scope": { "model": { "display_name": "Fable", "id": null }, "surface": null } }
/// ```
///
/// `weekly_scoped` entries carry a `scope.model.display_name` (e.g. **Fable**, Opus),
/// which is how per-model usage such as Fable is surfaced.
public struct UsageLimit: Codable, Sendable, Hashable, Identifiable {
    /// Coarse grouping: `session` or `weekly`.
    public let group: String?
    /// Fine kind: `session`, `weekly_all`, `weekly_scoped`, …
    public let kind: String?
    /// Percentage consumed, `0...100`.
    public let percent: Double?
    public let resetsAt: Date?
    /// Whether this is the currently binding limit for its group.
    public let isActive: Bool?
    /// Server-provided severity string (`normal`, `warning`, `critical`, …).
    public let severity: String?
    public let scope: Scope?

    public init(group: String?, kind: String?, percent: Double?, resetsAt: Date?,
                isActive: Bool?, severity: String?, scope: Scope?) {
        self.group = group
        self.kind = kind
        self.percent = percent
        self.resetsAt = resetsAt
        self.isActive = isActive
        self.severity = severity
        self.scope = scope
    }

    enum CodingKeys: String, CodingKey {
        case group, kind, percent, severity, scope
        case resetsAt = "resets_at"
        case isActive = "is_active"
    }

    public struct Scope: Codable, Sendable, Hashable {
        public let model: Model?
        public let surface: String?

        public init(model: Model?, surface: String?) {
            self.model = model
            self.surface = surface
        }

        public struct Model: Codable, Sendable, Hashable {
            public let displayName: String?
            public let id: String?

            public init(displayName: String?, id: String?) {
                self.displayName = displayName
                self.id = id
            }

            enum CodingKeys: String, CodingKey {
                case displayName = "display_name"
                case id
            }
        }
    }

    /// A stable identifier for SwiftUI lists.
    public var id: String {
        [group, kind, scope?.model?.displayName].compactMap { $0 }.joined(separator: ":")
    }

    /// Model name this limit is scoped to, if any (e.g. "Fable", "Opus").
    public var modelName: String? { scope?.model?.displayName }

    public var fractionUsed: Double {
        min(max((percent ?? 0) / 100.0, 0), 1)
    }

    public var percentUsed: Int { Int(fractionUsed * 100) }
    public var percentRemaining: Int { 100 - percentUsed }

    /// Human-readable label for the menu, e.g. "Session (5h)", "Weekly (all)",
    /// "Fable (weekly)".
    public var displayLabel: String {
        if let model = modelName {
            return "\(model) (weekly)"
        }
        switch kind {
        case "session":      return "Session (5h)"
        case "weekly_all":   return "Weekly (all models)"
        case "weekly_scoped": return "Weekly (scoped)"
        default:
            return (kind ?? group ?? "Limit")
                .replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
