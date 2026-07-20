import Foundation
import ClaudeUsageCore

// `claude-monitor` — Claude usage from your local Claude Code session.

struct CLI {
    static func run() async -> Int32 {
        let args = Array(CommandLine.arguments.dropFirst())

        if args.contains("--help") || args.contains("-h") { printUsage(); return 0 }
        if args.contains("--selftest") { return runSelfTest() ? 0 : 1 }
        if args.contains("--raw") { return await runRaw() }
        if args.contains("--history") { return await runHistory(args) }
        if args.contains("--watch") { return await runWatch(args) }
        if args.contains("--serve") { return await runServe(args) }

        // Default: one-shot current usage.
        let repo = makeRepo(args)
        do {
            let snapshot = try await repo.currentUsage()
            try? await UsageHistoryStore().record(snapshot)
            if args.contains("--json") { printJSON(snapshot) }
            else if args.contains("--csv") { printCSV([UsageRecord(from: snapshot)]) }
            else { printHuman(snapshot) }
            return 0
        } catch {
            fail(error); return 2
        }
    }

    // MARK: Commands

    static func runRaw() async -> Int32 {
        do {
            let creds = try KeychainCredentialStore().loadCredentials()
            let data = try await UsageAPIClient().fetchRawUsage(accessToken: creds.accessToken)
            if let obj = try? JSONSerialization.jsonObject(with: data),
               let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
                print(String(data: pretty, encoding: .utf8) ?? "")
            } else {
                print(String(data: data, encoding: .utf8) ?? "")
            }
            return 0
        } catch { fail(error); return 2 }
    }

    static func runHistory(_ args: [String]) async -> Int32 {
        let limit = intArg(args, after: "--history")
        let records = (try? await UsageHistoryStore().load(limit: limit)) ?? []
        if records.isEmpty {
            FileHandle.standardError.write(Data("No history yet. Run with --watch/--serve, or let the app run.\n".utf8))
            return 0
        }
        if args.contains("--json") {
            printEncodable(records)
        } else if args.contains("--csv") {
            printCSV(records)
        } else {
            print("timestamp                 plan        remain%  used%   spend")
            for r in records {
                let ts = ISO8601DateFormatter().string(from: r.timestamp)
                let spend = r.meteredSpend.map { ModelPricing.formatUSD($0) } ?? "-"
                print("\(ts)  \(pad(r.plan, 10))  \(pad("\(r.percentRemaining)%", 6))  \(pad("\(r.percentUsed)%", 6)) \(spend)")
            }
            if let p = UsagePredictor.predict(records) { printPrediction(p) }
        }
        return 0
    }

    static func runWatch(_ args: [String]) async -> Int32 {
        let interval = Double(intArg(args, after: "--watch") ?? 60)
        let repo = makeRepo(args)
        let history = UsageHistoryStore()
        while !Task.isCancelled {
            do {
                let s = try await repo.currentUsage()
                try? await history.record(s)
                let recs = (try? await history.load(limit: 500)) ?? []
                print("\u{1B}[2J\u{1B}[H", terminator: "") // clear screen
                printHuman(s)
                if let p = UsagePredictor.predict(recs) { printPrediction(p) }
                print("\nUpdating every \(Int(interval))s — Ctrl-C to stop.")
            } catch {
                fail(error)
            }
            try? await Task.sleep(for: .seconds(interval))
        }
        return 0
    }

    static func runServe(_ args: [String]) async -> Int32 {
        let port = UInt16(intArg(args, after: "--serve") ?? 9090)
        let interval = Double(intArg(args, after: "--interval") ?? 60)
        let repo = makeRepo(args)
        let history = UsageHistoryStore()
        let shared = SharedSnapshotStore()
        let cache = ServeCache()

        let server = LocalHTTPServer(port: port) { path in cache.respond(path) }
        do { try server.start() } catch {
            FileHandle.standardError.write(Data("Failed to start server on \(port): \(error)\n".utf8))
            return 2
        }
        print("""
        Serving on http://127.0.0.1:\(port)
          GET /metrics   Prometheus metrics (for Grafana)
          GET /usage     current usage (JSON)
          GET /history   recent history (JSON)
          GET /status    health/status (JSON)
        Refreshing every \(Int(interval))s — Ctrl-C to stop.
        """)

        while !Task.isCancelled {
            do {
                let s = try await repo.currentUsage()
                try? await history.record(s)
                shared.save(s)
                let recs = (try? await history.load(limit: 500)) ?? []
                cache.update(snapshot: s, prediction: UsagePredictor.predict(recs), history: recs)
            } catch {
                cache.setError((error as? LocalizedError)?.errorDescription ?? "\(error)")
            }
            try? await Task.sleep(for: .seconds(interval))
        }
        server.stop()
        return 0
    }

    // MARK: Rendering

    static func printHuman(_ s: UsageSnapshot) {
        func bar(_ frac: Double, width: Int = 20) -> String {
            let filled = Int((frac * Double(width)).rounded())
            return "[" + String(repeating: "█", count: filled)
                       + String(repeating: "·", count: max(0, width - filled)) + "]"
        }
        print("Plan:      \(s.planName)")
        print("Remaining: \(s.percentRemaining)%   (\(s.severity.rawValue))")
        let width = (s.metrics.map { $0.label.count }.max() ?? 10)
        for m in s.metrics {
            let name = m.label.padding(toLength: width, withPad: " ", startingAt: 0)
            let active = m.isActive ? " ←active" : ""
            if m.isMetered {
                let rate = m.pricing.map { " (in $\(nf($0.inputPerMillion))/M, out $\(nf($0.outputPerMillion))/M)" } ?? ""
                print("  \(name) \(m.spendText ?? "$0.00") spent\(rate)\(active)")
            } else {
                print("  \(name) \(bar(m.fractionUsed)) \(m.percentUsed)% used\(active)")
            }
        }
        if let spend = s.meteredSpend { print("Metered spend: \(ModelPricing.formatUSD(spend))") }
        if let reset = s.nextReset { print("Next reset: \(ISO8601DateFormatter().string(from: reset))") }
    }

    static func printPrediction(_ p: UsagePrediction) {
        print(String(format: "Burn rate: %.1f%%/h  (%.0f%%/day) — from %d samples", p.ratePerHour, p.ratePerDay, p.sampleCount))
        if let at = p.exhaustionAt, let h = p.hoursUntilExhaustion {
            let when = DateFormatter.localizedString(from: at, dateStyle: .short, timeStyle: .short)
            print("Projected exhaustion: \(when) (~\(String(format: "%.1f", h))h)")
        } else {
            print("Projected exhaustion: not at the current rate")
        }
    }

    static func printCSV(_ records: [UsageRecord]) {
        print("timestamp,plan,remaining_percent,used_percent,metered_spend_usd,next_reset")
        let iso = ISO8601DateFormatter()
        for r in records {
            let reset = r.nextReset.map { iso.string(from: $0) } ?? ""
            let spend = r.meteredSpend.map { String(format: "%.2f", $0) } ?? ""
            print("\(iso.string(from: r.timestamp)),\(csv(r.plan)),\(r.percentRemaining),\(r.percentUsed),\(spend),\(reset)")
        }
    }

    static func printJSON(_ s: UsageSnapshot) { printEncodable(s) }

    static func printEncodable<T: Encodable>(_ value: T) {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        if let data = try? e.encode(value), let str = String(data: data, encoding: .utf8) { print(str) }
    }

    // MARK: Helpers

    static func makeRepo(_ args: [String]) -> UsageRepository {
        UsageRepository(credentials: KeychainCredentialStore(allowInteraction: !args.contains("--no-ui")))
    }

    static func intArg(_ args: [String], after flag: String) -> Int? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return Int(args[i + 1])
    }

    static func fail(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
    }

    static func pad(_ s: String, _ n: Int) -> String { s.padding(toLength: max(n, s.count), withPad: " ", startingAt: 0) }
    static func csv(_ s: String) -> String { s.contains(",") ? "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\"" : s }

    static func nf(_ d: Decimal) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        f.minimumFractionDigits = 0; f.maximumFractionDigits = 2
        return f.string(from: NSDecimalNumber(decimal: d)) ?? "\(d)"
    }

    static func printUsage() {
        print("""
        claude-monitor — Claude usage from your local session

        USAGE:
          claude-monitor                 Print current usage (human-readable)
          claude-monitor --json          Current usage as JSON
          claude-monitor --csv           Current usage as one CSV row
          claude-monitor --watch [secs]  Live-refreshing view (default 60s)
          claude-monitor --history [N]   Print stored history (+ --json / --csv)
          claude-monitor --serve [port]  Prometheus + REST server (default 9090)
                                         /metrics /usage /history /status
          claude-monitor --raw           Raw /api/oauth/usage body
          claude-monitor --no-ui         Never show a Keychain dialog (cron/CI)
          claude-monitor --selftest      Offline logic checks (no network)
          claude-monitor --help          Show this help
        """)
    }

    // MARK: Offline self-test

    static func runSelfTest() -> Bool {
        var failures = 0
        func check(_ name: String, _ condition: Bool) {
            print("  \(condition ? "✓" : "✗") \(name)"); if !condition { failures += 1 }
        }

        check("utilization percent → percentUsed",
              RateLimitWindow(utilization: 42, remaining: nil, resetsAt: nil).percentUsed == 42)
        check("plan display name = Max 20×",
              AccountInfo(accountUuid: nil, organizationUuid: nil, emailAddress: nil, displayName: nil,
                organizationName: nil, organizationType: "claude_max",
                organizationRateLimitTier: "default_claude_max_20x", billingType: nil,
                hasExtraUsageEnabled: nil).planDisplayName == "Max 20×")
        check("enveloped credentials decode",
              (try? OAuthCredentials.decode(from: Data("{\"claudeAiOauth\":{\"accessToken\":\"sk\",\"expiresAt\":1777385989340}}".utf8)))?.accessToken == "sk")
        check("Fable 1M in + 1M out = $60",
              ModelPricing.fable.cost(inputTokens: 1_000_000, outputTokens: 1_000_000).total == Decimal(60))

        // Prediction: a rising run should project exhaustion in the future.
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let recs = (0..<5).map { i in
            UsageRecord(timestamp: base.addingTimeInterval(Double(i) * 3600),
                        plan: "Max", percentRemaining: 100 - i * 10, percentUsed: i * 10,
                        meteredSpend: nil, nextReset: nil, metrics: [])
        }
        let pred = UsagePredictor.predict(recs, now: base.addingTimeInterval(4 * 3600))
        check("predict rate ≈ 10%/h", pred.map { abs($0.ratePerHour - 10) < 0.5 } ?? false)
        check("predict exhaustion is set", pred?.hoursUntilExhaustion != nil)

        // Reset detection: a drop starts a new run.
        let withReset = recs + [UsageRecord(timestamp: base.addingTimeInterval(5 * 3600),
            plan: "Max", percentRemaining: 95, percentUsed: 5, meteredSpend: nil, nextReset: nil, metrics: [])]
        check("current run resets after a drop", UsagePredictor.currentRun(withReset).count == 1)

        // Prometheus exporter shape.
        let snap = UsageSnapshot(capturedAt: base, account: nil,
            usage: UsageResponse(fiveHour: RateLimitWindow(utilization: 8, remaining: nil, resetsAt: nil),
                                 sevenDay: nil, sevenDayOpus: nil, overage: nil, limits: []))
        let metrics = PrometheusExporter.format(snap)
        check("prometheus has remaining gauge", metrics.contains("claude_usage_remaining_percent 92"))
        check("prometheus has TYPE line", metrics.contains("# TYPE claude_usage_used_percent gauge"))

        // HTTP request parsing.
        check("HTTP path parse", LocalHTTPServer.parsePath("GET /metrics?x=1 HTTP/1.1\r\nHost: x\r\n") == "/metrics")

        print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) FAILED.")
        return failures == 0
    }
}

/// Thread-safe response cache for `--serve`.
final class ServeCache: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: UsageSnapshot?
    private var prediction: UsagePrediction?
    private var records: [UsageRecord] = []
    private var error: String?

    func update(snapshot: UsageSnapshot, prediction: UsagePrediction?, history: [UsageRecord]) {
        lock.lock(); defer { lock.unlock() }
        self.snapshot = snapshot; self.prediction = prediction; self.records = history; self.error = nil
    }
    func setError(_ message: String) {
        lock.lock(); defer { lock.unlock() }; self.error = message
    }

    func respond(_ path: String) -> LocalHTTPServer.Response {
        lock.lock(); let snap = snapshot; let pred = prediction; let recs = records; let err = error; lock.unlock()

        switch path {
        case "/metrics":
            guard let snap else { return .init(body: "# no data yet\n") }
            return .init(body: PrometheusExporter.format(snap, prediction: pred))
        case "/usage":
            guard let snap else { return .json("null") }
            return .json(encode(snap))
        case "/history":
            return .json(encode(recs))
        case "/status":
            let updated = snap.map { ISO8601DateFormatter().string(from: $0.capturedAt) } ?? "null"
            let e = err.map { "\"\($0.replacingOccurrences(of: "\"", with: "'"))\"" } ?? "null"
            return .json("{\"ok\":\(snap != nil && err == nil),\"lastUpdated\":\"\(updated)\",\"error\":\(e)}")
        case "/":
            return .init(body: "claude-monitor — /metrics /usage /history /status\n")
        default:
            return .notFound()
        }
    }

    private func encode<T: Encodable>(_ v: T) -> String {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]
        return (try? e.encode(v)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }
}

exit(await CLI.run())
