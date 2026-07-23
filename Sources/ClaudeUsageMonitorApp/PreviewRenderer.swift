import SwiftUI
import AppKit
import ClaudeUsageCore

/// Development/QA affordance: renders the menu's tabs to PNGs so layout can be checked
/// without opening the menu bar. Invoked via `ClaudeUsageMonitor --render-preview <dir>`.
///
/// It uses fixture data (not the Keychain/network) so the output is deterministic and it
/// can run headlessly.
@MainActor
enum PreviewRenderer {
    /// A repository that returns a fixed snapshot — realistic worst-case strings so the
    /// render exposes truncation and overlap.
    struct FixtureRepository: UsageRepositoryProtocol {
        let snapshot: UsageSnapshot
        func currentUsage() async throws -> UsageSnapshot { snapshot }
    }

    static func run(outputDir: String) {
        let dir = URL(fileURLWithPath: outputDir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let model = MenuBarViewModel(repository: FixtureRepository(snapshot: fixtureSnapshot()),
                                     previewMode: true)
        model.applyFixture(snapshot: fixtureSnapshot(),
                           prediction: fixturePrediction(),
                           history: fixtureHistory())
        let updates = UpdateManager()

        // Each tab, with the detail toggles both off and on.
        for detailed in [false, true] {
            model.detailed = detailed
            model.analyticsEnabled = true
            for tab in MenuTab.allCases {
                let view = MenuContentView(model: model, updates: updates, initialTab: tab)
                let name = "\(tab.rawValue.lowercased())\(detailed ? "-detailed" : "").png"
                render(view, to: dir.appendingPathComponent(name))
            }
        }
        print("Rendered previews to \(dir.path)")
    }

    private static func render(_ view: some View, to url: URL) {
        let renderer = ImageRenderer(content: view.frame(width: 360).background(Color(nsColor: .windowBackgroundColor)))
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("✗ failed to render \(url.lastPathComponent)")
            return
        }
        try? png.write(to: url)
        print("  ✓ \(url.lastPathComponent)  \(Int(image.size.width))×\(Int(image.size.height))")
    }

    // MARK: Fixtures

    static func fixtureSnapshot() -> UsageSnapshot {
        let now = Date()
        let limits: [UsageLimit] = [
            UsageLimit(group: "five_hour", kind: "session", percent: 63,
                       resetsAt: now.addingTimeInterval(4 * 3600 + 40 * 60),
                       isActive: true, severity: "warning", scope: nil,
                       usedDollars: nil, limitDollars: nil),
            UsageLimit(group: "seven_day", kind: "weekly_all", percent: 18,
                       resetsAt: now.addingTimeInterval(3 * 86400),
                       isActive: false, severity: "ok", scope: nil,
                       usedDollars: nil, limitDollars: nil),
            UsageLimit(group: "weekly", kind: "weekly_scoped", percent: 9,
                       resetsAt: now.addingTimeInterval(3 * 86400),
                       isActive: false, severity: "ok",
                       scope: .init(model: .init(displayName: "Opus 4.8", id: "claude-opus-4-8"), surface: nil),
                       usedDollars: nil, limitDollars: nil),
            // Metered window with a long trailing rate string — the crowded case.
            UsageLimit(group: "weekly", kind: "weekly_scoped", percent: nil,
                       resetsAt: now.addingTimeInterval(3 * 86400),
                       isActive: false, severity: "ok",
                       scope: .init(model: .init(displayName: "Fable", id: "claude-fable-5"), surface: nil),
                       usedDollars: 0.42, limitDollars: nil),
        ]
        let usage = UsageResponse(fiveHour: nil, sevenDay: nil, sevenDayOpus: nil,
                                  overage: nil, limits: limits, spend: nil)
        let account = AccountInfo(
            accountUuid: "acct-uuid",
            organizationUuid: "org-uuid",
            emailAddress: "a-fairly-long-address@sktelecom.example.com",
            displayName: "Jahon Koo",
            organizationName: "SK Telecom AI Infrastructure Division",
            organizationType: "claude_max",
            organizationRateLimitTier: "default_claude_max_20x",
            billingType: "subscription",
            hasExtraUsageEnabled: true)
        return UsageSnapshot(capturedAt: now, account: account, usage: usage)
    }

    /// Derived through the real predictor so the rendered forecast matches production logic.
    static func fixturePrediction() -> UsagePrediction? {
        UsagePredictor.predict(fixtureHistory())
    }

    static func fixtureHistory() -> [UsageRecord] {
        let now = Date()
        return (0..<24).map { i in
            let t = now.addingTimeInterval(Double(i - 23) * 900)
            let used = min(63, 10 + Int(Double(i) * 2.3))
            return UsageRecord(timestamp: t, plan: "Max 20×",
                               percentRemaining: 100 - used, percentUsed: used,
                               meteredSpend: 0.42,
                               nextReset: now.addingTimeInterval(4 * 3600 + 40 * 60),
                               metrics: [.init(id: "five_hour", label: "Session (5h)",
                                               fractionUsed: Double(used) / 100,
                                               isMetered: false, usedDollars: nil)])
        }
    }
}
