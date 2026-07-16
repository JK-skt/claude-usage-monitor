import Foundation
import ClaudeUsageCore

// Minimal `claude-monitor` CLI. Grows into the full spec (--watch, --csv, --history);
// today it validates the core end-to-end and prints live usage.

struct CLI {
    static func run() async -> Int32 {
        let args = Array(CommandLine.arguments.dropFirst())

        if args.contains("--help") || args.contains("-h") {
            printUsage()
            return 0
        }
        if args.contains("--selftest") {
            return runSelfTest() ? 0 : 1
        }
        if args.contains("--raw") {
            do {
                let creds = try KeychainCredentialStore().loadCredentials()
                let data = try await UsageAPIClient().fetchRawUsage(accessToken: creds.accessToken)
                // Pretty-print for readability.
                if let obj = try? JSONSerialization.jsonObject(with: data),
                   let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
                    print(String(data: pretty, encoding: .utf8) ?? "")
                } else {
                    print(String(data: data, encoding: .utf8) ?? "")
                }
                return 0
            } catch {
                FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
                return 2
            }
        }

        let json = args.contains("--json")
        // CLIs shouldn't silently pop a GUI dialog in cron/CI; --no-ui fails fast instead.
        let interactive = !args.contains("--no-ui")
        let repo = UsageRepository(
            credentials: KeychainCredentialStore(allowInteraction: interactive)
        )
        do {
            let snapshot = try await repo.currentUsage()
            json ? printJSON(snapshot) : printHuman(snapshot)
            return 0
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
            return 2
        }
    }

    static func printUsage() {
        print("""
        claude-monitor — Claude usage from your local session

        USAGE:
          claude-monitor            Print current usage (human-readable)
          claude-monitor --json     Print current usage as JSON
          claude-monitor --no-ui    Never show a Keychain dialog (cron/CI); fail fast
          claude-monitor --selftest Run offline logic checks (no network)
          claude-monitor --help     Show this help
        """)
    }

    static func printHuman(_ s: UsageSnapshot) {
        func bar(_ frac: Double, width: Int = 20) -> String {
            let filled = Int((frac * Double(width)).rounded())
            return "[" + String(repeating: "█", count: filled)
                       + String(repeating: "·", count: width - filled) + "]"
        }
        print("Plan:      \(s.planName)")
        print("Remaining: \(s.percentRemaining)%   (\(s.severity.rawValue))")
        let width = (s.metrics.map { $0.label.count }.max() ?? 10)
        for m in s.metrics {
            let name = m.label.padding(toLength: width, withPad: " ", startingAt: 0)
            let active = m.isActive ? " ←active" : ""
            print("  \(name) \(bar(m.fractionUsed)) \(m.percentUsed)% used\(active)")
        }
        if let reset = s.nextReset {
            print("Next reset: \(ISO8601DateFormatter().string(from: reset))")
        }
    }

    static func printJSON(_ s: UsageSnapshot) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(s), let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    }

    // Offline logic checks — usable without Xcode/XCTest.
    static func runSelfTest() -> Bool {
        var failures = 0
        func check(_ name: String, _ condition: Bool) {
            print("  \(condition ? "✓" : "✗") \(name)")
            if !condition { failures += 1 }
        }

        check("utilization percent → percentUsed",
              RateLimitWindow(utilization: 42, remaining: nil, resetsAt: nil).percentUsed == 42)
        check("percentRemaining complements percentUsed",
              RateLimitWindow(utilization: 42, remaining: nil, resetsAt: nil).percentRemaining == 58)

        let account = AccountInfo(accountUuid: nil, organizationUuid: nil, emailAddress: nil,
            displayName: nil, organizationName: nil, organizationType: "claude_max",
            organizationRateLimitTier: "default_claude_max_20x", billingType: nil,
            hasExtraUsageEnabled: nil)
        check("plan display name = Max 20×", account.planDisplayName == "Max 20×")

        let enveloped = Data("""
        {"claudeAiOauth":{"accessToken":"sk","expiresAt":1777385989340}}
        """.utf8)
        check("enveloped credentials decode",
              (try? OAuthCredentials.decode(from: enveloped))?.accessToken == "sk")

        // A Fable-style model-scoped limit is surfaced via the `limits` array.
        let fable = UsageLimit(group: "weekly", kind: "weekly_scoped", percent: 88,
            resetsAt: nil, isActive: true, severity: "normal",
            scope: .init(model: .init(displayName: "Fable", id: nil), surface: nil))
        let usage = UsageResponse(fiveHour: RateLimitWindow(utilization: 42, remaining: nil, resetsAt: nil),
            sevenDay: nil, sevenDayOpus: nil, overage: nil, limits: [fable])
        let snap = UsageSnapshot(capturedAt: Date(), account: nil, usage: usage)
        check("Fable metric present via limits", snap.metric(forModel: "fable")?.percentUsed == 88)
        check("headline = most consumed (Fable 88%)", snap.percentUsed == 88)
        check("severity for 12% remaining = orange", snap.severity == .orange)

        print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) FAILED.")
        return failures == 0
    }
}

exit(await CLI.run())
