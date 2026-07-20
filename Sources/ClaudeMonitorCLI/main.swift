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
            if m.isMetered {
                // Pay-as-you-go: there is no quota bar — show spend to date, and the rate.
                let rate = m.pricing.map {
                    " (in $\(nf($0.inputPerMillion))/M, out $\(nf($0.outputPerMillion))/M)"
                } ?? ""
                print("  \(name) \(m.spendText ?? "$0.00") spent\(rate)\(active)")
            } else {
                print("  \(name) \(bar(m.fractionUsed)) \(m.percentUsed)% used\(active)")
            }
        }
        if let spend = s.meteredSpend {
            print("Metered spend: \(ModelPricing.formatUSD(spend))")
        }
        if let reset = s.nextReset {
            print("Next reset: \(ISO8601DateFormatter().string(from: reset))")
        }
    }

    /// Compact decimal (drops trailing `.0`), for rate display like `$10/M`.
    static func nf(_ d: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 2
        return f.string(from: NSDecimalNumber(decimal: d)) ?? "\(d)"
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

        // Fable pay-as-you-go pricing: $10 / 1M input, $50 / 1M output.
        let breakdown = ModelPricing.fable.cost(inputTokens: 1_000_000, outputTokens: 1_000_000)
        check("Fable 1M in + 1M out = $60", breakdown.total == Decimal(60))
        check("Fable input component = $10", breakdown.inputCost == Decimal(10))
        check("Fable output component = $50", breakdown.outputCost == Decimal(50))
        check("Fable 500K in = $5", ModelPricing.fable.cost(inputTokens: 500_000, outputTokens: 0).total == Decimal(5))
        check("pricing lookup is case-insensitive", ModelPricing.forModel("fable") == .fable)
        check("non-metered model has no pricing", ModelPricing.forModel("Opus") == nil)

        // A Fable model-scoped limit is now metered — surfaced as spend, not a quota %.
        let fable = UsageLimit(group: "weekly", kind: "weekly_scoped", percent: nil,
            resetsAt: nil, isActive: true, severity: "normal",
            scope: .init(model: .init(displayName: "Fable", id: nil), surface: nil),
            usedDollars: 12.34)
        let quota = RateLimitWindow(utilization: 88, remaining: nil, resetsAt: nil)
        let usage = UsageResponse(
            fiveHour: quota, sevenDay: nil, sevenDayOpus: nil, overage: nil, limits: [
                UsageLimit(group: "session", kind: "session", percent: 88, resetsAt: nil,
                           isActive: false, severity: "normal", scope: nil),
                fable
            ])
        let snap = UsageSnapshot(capturedAt: Date(), account: nil, usage: usage)
        check("Fable metric is metered", snap.metric(forModel: "fable")?.isMetered == true)
        check("Fable spend surfaced", snap.metric(forModel: "fable")?.spendText == "$12.34")
        check("metered metric excluded from headline", snap.percentUsed == 88)
        check("metered spend total", snap.meteredSpend == 12.34)
        check("severity for 12% remaining = orange", snap.severity == .orange)

        print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) FAILED.")
        return failures == 0
    }
}

exit(await CLI.run())
