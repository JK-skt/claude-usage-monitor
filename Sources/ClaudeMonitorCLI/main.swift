import Foundation
import ClaudeUsageCore

// `claude-monitor` — Claude usage from your local Claude Code session.

struct CLI {
    static func run() async -> Int32 {
        let args = Array(CommandLine.arguments.dropFirst())

        if args.contains("--help") || args.contains("-h") { printUsage(); return 0 }
        if args.contains("--selftest") { return runSelfTest() ? 0 : 1 }
        if args.contains("--check-update") { return await runCheckUpdate(args) }
        if args.contains("--analytics") { return await runAnalytics(args) }
        if args.contains("--raw") { return await runRaw() }
        if args.contains("--tokens") { return await runTokens(args) }
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

    static func runAnalytics(_ args: [String]) async -> Int32 {
        let range: AnalyticsRange = {
            switch stringArg(args, after: "--analytics") {
            case "7", "7d": return .sevenDays
            case "30", "30d": return .thirtyDays
            default: return .all
            }
        }()
        let a = await TokenUsageReader().analytics(range: range)
        if args.contains("--json") { printEncodable(a); return 0 }

        func c(_ n: Int) -> String { AnalyticsFormatCLI.compact(n) }
        print("Usage analytics (\(range.label)) — from local Claude Code session logs")
        if a.isEmpty { print("  (no usage recorded in this range)"); return 0 }
        print("  Sessions        \(a.sessions)")
        print("  Messages        \(AnalyticsFormatCLI.grouped(a.messages))")
        print("  Total tokens    \(c(a.totalTokens))  (input+output)")
        print("  Active days     \(a.activeDays)")
        print("  Current streak  \(a.currentStreak)d   Longest \(a.longestStreak)d")
        if let h = a.peakHour { print("  Peak hour       \(h):00") }
        if let m = a.favoriteModel { print("  Favorite model  \(m)") }
        if !a.models.isEmpty {
            print("  By model:")
            for m in a.models {
                print("    \(pad(m.name, 12)) \(pad(c(m.input), 8)) in · \(pad(c(m.output), 8)) out  \(String(format: "%.1f%%", m.fraction * 100))")
            }
        }
        return 0
    }

    /// Compact/grouped number formatting for the CLI analytics view.
    enum AnalyticsFormatCLI {
        static func compact(_ n: Int) -> String {
            let d = Double(n)
            if d >= 1_000_000 { return String(format: "%.1fM", d / 1_000_000) }
            if d >= 1_000 { return String(format: "%.1fK", d / 1_000) }
            return "\(n)"
        }
        static func grouped(_ n: Int) -> String {
            let f = NumberFormatter(); f.numberStyle = .decimal
            return f.string(from: NSNumber(value: n)) ?? "\(n)"
        }
    }

    static func runCheckUpdate(_ args: [String]) async -> Int32 {
        // Bare SPM binaries have no Info.plist; allow an explicit current version.
        let current = stringArg(args, after: "--current") ?? AppVersion.current
        do {
            let latest = try await UpdateChecker().latestRelease()
            let newer = SemanticVersion.isNewer(latest.version, than: current)
            print("Current: \(current)")
            print("Latest:  \(latest.tagName)\(latest.name.map { " — \($0)" } ?? "")")
            if newer {
                print("Update available.")
                let lines = latest.highlights(max: 5)
                if !lines.isEmpty {
                    print("Key changes:")
                    for l in lines { print("  • \(l)") }
                }
                if let dmg = latest.dmgAsset { print("DMG: \(dmg.browserDownloadURL)") }
                if let page = latest.htmlURL { print("Notes: \(page)") }
                return 10 // distinct exit code: update available (scriptable)
            }
            print("Up to date.")
            return 0
        } catch {
            fail(error); return 2
        }
    }

    static func stringArg(_ args: [String], after flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count,
              !args[i + 1].hasPrefix("--") else { return nil }
        return args[i + 1]
    }

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

    static func runTokens(_ args: [String]) async -> Int32 {
        let days = intArg(args, after: "--tokens") ?? 7
        let report = await TokenUsageReader().report(windowDays: days)
        if args.contains("--json") { printEncodable(report); return 0 }

        func fmt(_ n: Int) -> String {
            let f = NumberFormatter(); f.numberStyle = .decimal
            return f.string(from: NSNumber(value: n)) ?? "\(n)"
        }
        func line(_ label: String, _ t: TokenTotals) {
            print("  \(pad(label, 14)) in \(pad(fmt(t.input), 12)) out \(pad(fmt(t.output), 12)) cache \(fmt(t.cacheRead + t.cacheCreation))")
        }
        print("Token usage (from local Claude Code session logs)")
        line("Today", report.today)
        line("Last \(report.windowDays)d", report.window)
        if !report.bySource.isEmpty {
            print("By source (application):")
            for s in report.bySource { line(s.name, s.totals) }
        }
        if !report.byModel.isEmpty {
            print("By model:")
            for m in report.byModel { line(m.name, m.totals) }
        }
        if !report.byProject.isEmpty {
            print("By project (top):")
            for p in report.byProject.prefix(6) { line(p.name, p.totals) }
        }
        // Cost estimate only for metered models we price (e.g. Fable); others are
        // subscription-covered, so their token counts stand on their own.
        var estimated = Decimal(0)
        for m in report.byModel {
            if let p = ModelPricing.forModel(m.name) {
                estimated += p.cost(inputTokens: m.totals.input, outputTokens: m.totals.output).total
            }
        }
        if estimated > 0 {
            print("Estimated metered cost (last \(report.windowDays)d): \(ModelPricing.formatUSD(NSDecimalNumber(decimal: estimated).doubleValue))")
        }
        print("Note: counts cover Claude Code (all entrypoints). The Claude desktop chat app")
        print("      stores conversations server-side, so its tokens are not counted locally.")
        return 0
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
            var parts: [String] = []
            if m.hasQuota { parts.append("\(bar(1 - m.fractionUsed)) \(m.percentRemaining)% left") }
            if m.isMetered { parts.append("\(m.spendText ?? "$0.00") spent") }
            if parts.isEmpty { parts.append("—") }
            print("  \(name) \(parts.joined(separator: "  "))\(active)")
            if let p = m.pricing {
                print("  \(String(repeating: " ", count: width)) rate $\(nf(p.inputPerMillion))/M in · $\(nf(p.outputPerMillion))/M out")
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
          claude-monitor --tokens [days] Token counts from local session logs (default 7d)
          claude-monitor --analytics [all|30|7]  Usage analytics (+ --json)
          claude-monitor --raw           Raw /api/oauth/usage body
          claude-monitor --check-update  Check GitHub for a newer release
                                         (--current X.Y.Z to override; exit 10 = update)
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

        // Headline selection: auto picks the most-consumed quota window; a pin overrides it.
        let session = UsageLimit(group: "session", kind: "session", percent: 20, resetsAt: nil,
            isActive: true, severity: "normal", scope: nil)
        let weekly = UsageLimit(group: "weekly", kind: "weekly_all", percent: 60, resetsAt: nil,
            isActive: false, severity: "normal", scope: nil)
        let headSnap = UsageSnapshot(capturedAt: Date(), account: nil,
            usage: UsageResponse(fiveHour: nil, sevenDay: nil, sevenDayOpus: nil, overage: nil,
                                 limits: [session, weekly]))
        check("headline auto = most used (weekly 60%)", headSnap.percentUsed(pinnedID: "") == 60)
        check("headline pinned to session (20%)", headSnap.percentUsed(pinnedID: session.id) == 20)
        check("pinned session → 80% remaining", headSnap.percentRemaining(pinnedID: session.id) == 80)
        check("unknown pin falls back to auto", headSnap.percentUsed(pinnedID: "nope") == 60)

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

        // Token totals aggregation.
        var tt = TokenTotals()
        tt.add(TokenSample(timestamp: base, model: "m", project: "p", source: "s", input: 100, output: 50, cacheCreation: 10, cacheRead: 1000))
        tt.add(TokenSample(timestamp: base, model: "m", project: "p", source: "s", input: 20, output: 5, cacheCreation: 0, cacheRead: 500))
        check("token in+out sums", tt.inputPlusOutput == 175)
        check("token grand total incl. cache", tt.grandTotal == 1685)
        check("token message count", tt.messages == 2)
        check("entrypoint→source label", TokenSample.sourceName(entrypoint: "claude-vscode") == "Claude Code (VS Code)")

        // Update checker: version comparison, highlight extraction, asset selection.
        check("semver: 0.5.0 newer than 0.4.0", SemanticVersion.isNewer("0.5.0", than: "0.4.0"))
        check("semver: v-prefix ignored", SemanticVersion.isNewer("v0.10.0", than: "0.9.9"))
        check("semver: equal is not newer", !SemanticVersion.isNewer("0.4.0", than: "0.4.0"))
        check("semver: older is not newer", !SemanticVersion.isNewer("0.3.9", than: "0.4.0"))
        check("semver: 0.4.1 newer than 0.4", SemanticVersion.isNewer("0.4.1", than: "0.4"))
        let rel = ReleaseInfo(
            tagName: "v9.9.9", name: "Big one",
            body: """
            Intro paragraph, not a bullet.

            - **Widget** — small/medium/large, see [docs](https://x.y/docs)
            - `--serve` flag for Prometheus
            not a bullet either
            - Third change
            - Fourth change
            """,
            htmlURL: URL(string: "https://github.com/JK-skt/claude-usage-monitor/releases/tag/v9.9.9"),
            publishedAt: nil,
            assets: [.init(name: "ClaudeUsageMonitor-9.9.9.dmg", size: 1,
                           browserDownloadURL: URL(string: "https://github.com/x.dmg")!,
                           contentType: "application/x-apple-diskimage")])
        check("release version strips v", rel.version == "9.9.9")
        check("highlights take bullets only", rel.highlights(max: 3).count == 3)
        check("highlights strip markdown",
              rel.highlights(max: 1).first == "Widget — small/medium/large, see docs")
        check("dmg asset found", rel.dmgAsset?.name.hasSuffix(".dmg") == true)
        // CRLF release bodies (GitHub often serves \r\n) must still yield highlights.
        let crlf = ReleaseInfo(tagName: "v1.0.0", name: nil,
            body: "Intro\r\n\r\n- First change\r\n- Second change\r\n",
            htmlURL: nil, publishedAt: nil, assets: [])
        check("highlights handle CRLF bodies", crlf.highlights(max: 2) == ["First change", "Second change"])
        check("packaged version is 0.7.0", AppVersion.packaged == "0.7.0")

        // Analytics engine.
        check("model display name: fable", ModelDisplayName.pretty("claude-fable-5") == "Fable 5")
        check("model display name: opus", ModelDisplayName.pretty("claude-opus-4-8") == "Opus 4.8")
        check("model display name: dated", ModelDisplayName.pretty("claude-sonnet-4-6-20250219") == "Sonnet 4.6")
        do {
            let cal = Calendar(identifier: .gregorian)
            let now = Date(timeIntervalSince1970: 1_700_000_000) // fixed
            func day(_ offset: Int, _ model: String, _ inn: Int, _ out: Int, sid: String) -> TokenSample {
                let ts = cal.date(byAdding: .day, value: offset, to: now)!
                return TokenSample(timestamp: ts, model: model, project: "p", source: "Claude Code",
                                   input: inn, output: out, cacheCreation: 0, cacheRead: 0, sessionID: sid)
            }
            let samples = [
                day(0, "claude-fable-5", 100, 200, sid: "s1"),
                day(0, "claude-opus-4-8", 50, 10, sid: "s1"),
                day(-1, "claude-fable-5", 300, 100, sid: "s2"),
                day(-2, "claude-fable-5", 10, 5, sid: "s3"),
            ]
            let a = UsageAnalyticsBuilder.build(from: samples, range: .all, now: now, calendar: cal)
            check("analytics total tokens = in+out", a.totalTokens == 100+200+50+10+300+100+10+5)
            check("analytics sessions distinct", a.sessions == 3)
            check("analytics messages", a.messages == 4)
            check("analytics active days = 3", a.activeDays == 3)
            check("analytics current streak = 3", a.currentStreak == 3)
            check("analytics favorite = Fable 5", a.favoriteModel == "Fable 5")
            check("analytics model fractions sum ~1",
                  abs(a.models.map(\.fraction).reduce(0, +) - 1.0) < 0.001)
        }

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
