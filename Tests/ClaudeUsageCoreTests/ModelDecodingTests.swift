import Testing
import Foundation
@testable import ClaudeUsageCore

@Suite("Usage model decoding & aggregation")
struct ModelDecodingTests {

    // MARK: /api/oauth/usage response

    @Test("Decodes the reverse-engineered /api/oauth/usage schema (integer percents)")
    func usageResponseDecodes() throws {
        let json = """
        {
          "five_hour":  { "utilization": 3, "resets_at": "2026-07-16T22:00:00Z" },
          "seven_day":  { "utilization": 5, "remaining": 12400000, "resets_at": "2026-07-23T00:00:00Z" },
          "seven_day_opus": { "utilization": 88, "resets_at": "2026-07-23T00:00:00Z" },
          "overage": { "status": "disabled", "resets_at": null }
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let usage = try decoder.decode(UsageResponse.self, from: json)

        #expect(usage.fiveHour?.percentUsed == 3)
        #expect(usage.sevenDay?.remaining == 12_400_000)
        #expect(usage.sevenDayOpus?.percentUsed == 88)
        #expect(usage.overage?.status == "disabled")
    }

    @Test("Decodes the `limits` array and surfaces Fable as a metered (pay-as-you-go) metric")
    func limitsArrayWithFable() throws {
        // Post-2026-07 policy: Fable is metered. The server may report accrued spend via
        // `used_dollars`; it carries no quota bar.
        let json = """
        { "limits": [
            { "group":"session", "kind":"session", "is_active":true, "percent":3,
              "resets_at":"2026-07-16T15:29:59Z", "severity":"normal" },
            { "group":"weekly", "kind":"weekly_scoped", "is_active":false,
              "resets_at":"2026-07-22T12:59:59Z", "severity":"normal", "used_dollars": 4.20,
              "scope": { "model": { "display_name":"Fable", "id":null }, "surface":null } }
        ] }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let usage = try decoder.decode(UsageResponse.self, from: json)
        let snapshot = UsageSnapshot(capturedAt: Date(), account: nil, usage: usage)

        #expect(usage.limits.count == 2)
        let fable = snapshot.metric(forModel: "fable")
        #expect(fable?.isMetered == true)
        #expect(fable?.pricing == .fable)
        #expect(fable?.usedDollars == 4.20)
        #expect(fable?.spendText == "$4.20")
        #expect(fable?.label == "Fable (metered)")
        #expect(snapshot.modelMetrics.map(\.modelName) == ["Fable"])
        // Metered Fable does not drive the quota headline; the 3% session window does.
        #expect(snapshot.percentUsed == 3)
        #expect(snapshot.meteredSpend == 4.20)
    }

    // MARK: Metered pricing (Fable pay-as-you-go)

    @Test("Fable pricing: $10 / 1M input, $50 / 1M output")
    func fablePricing() {
        let p = ModelPricing.fable
        #expect(p.cost(inputTokens: 1_000_000, outputTokens: 1_000_000).total == Decimal(60))
        #expect(p.cost(inputTokens: 1_000_000, outputTokens: 0).total == Decimal(10))
        #expect(p.cost(inputTokens: 0, outputTokens: 1_000_000).total == Decimal(50))
        #expect(p.cost(inputTokens: 250_000, outputTokens: 100_000).inputCost == Decimal(2.5))
        #expect(p.cost(inputTokens: 250_000, outputTokens: 100_000).outputCost == Decimal(5))
        #expect(p.cost(inputTokens: -5, outputTokens: -5).total == Decimal(0)) // clamps negatives
    }

    @Test("Pricing registry resolves metered models case-insensitively")
    func pricingRegistry() {
        #expect(ModelPricing.forModel("Fable") == .fable)
        #expect(ModelPricing.forModel("fable") == .fable)
        #expect(ModelPricing.forModel("Opus") == nil)
        #expect(ModelPricing.forModel(nil) == nil)
    }

    @Test("Spend object decodes minor-unit money")
    func spendDecoding() throws {
        let json = """
        { "spend": { "enabled": true, "percent": 12, "severity": "normal",
                     "used": { "amount_minor": 1234, "currency": "USD", "exponent": 2 },
                     "limit": { "amount_minor": 5000, "currency": "USD", "exponent": 2 } } }
        """.data(using: .utf8)!
        let usage = try JSONDecoder().decode(UsageResponse.self, from: json)
        #expect(usage.spend?.usedDollars == 12.34)
        #expect(usage.spend?.limitDollars == 50.0)
    }

    @Test("Utilization is an integer percentage (0…100)")
    func utilizationPercent() {
        let w = RateLimitWindow(utilization: 42, remaining: nil, resetsAt: nil)
        #expect(w.percentUsed == 42)
        #expect(w.percentRemaining == 58)
    }

    @Test("Missing windows decode to nil, not error")
    func missingWindows() throws {
        let usage = try JSONDecoder().decode(UsageResponse.self, from: Data("{}".utf8))
        #expect(usage.fiveHour == nil)
        #expect(usage.sevenDay == nil)
    }

    // MARK: OAuth credentials

    @Test("Credentials decode the enveloped Keychain form")
    func credentialsEnveloped() throws {
        let json = """
        { "claudeAiOauth": {
            "accessToken": "sk-abc", "refreshToken": "rt-xyz",
            "expiresAt": 1777385989340, "scopes": ["user:inference"],
            "subscriptionType": "max"
        } }
        """.data(using: .utf8)!
        let creds = try OAuthCredentials.decode(from: json)
        #expect(creds.accessToken == "sk-abc")
        #expect(creds.refreshToken == "rt-xyz")
        #expect(creds.subscriptionType == "max")
        #expect(creds.expiresAt != nil)
    }

    @Test("Expiry detection uses millisecond epochs")
    func credentialExpiry() {
        let expired = OAuthCredentials(accessToken: "a", refreshToken: nil,
            expiresAtMillis: 1000, scopes: nil, subscriptionType: nil)
        #expect(expired.isExpired())

        let future = Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000
        let valid = OAuthCredentials(accessToken: "a", refreshToken: nil,
            expiresAtMillis: future, scopes: nil, subscriptionType: nil)
        #expect(!valid.isExpired())
    }

    // MARK: Account info

    @Test("Plan display name derives from org type + tier")
    func planName() {
        let account = AccountInfo(
            accountUuid: nil, organizationUuid: nil, emailAddress: nil, displayName: nil,
            organizationName: nil, organizationType: "claude_max",
            organizationRateLimitTier: "default_claude_max_20x",
            billingType: "stripe_subscription", hasExtraUsageEnabled: false)
        #expect(account.planDisplayName == "Max 20×")
    }

    @Test("Multiplier extraction from tier string")
    func multiplier() {
        #expect(AccountInfo.multiplier(from: "default_claude_max_20x") == "20×")
        #expect(AccountInfo.multiplier(from: "default_claude_max_5x") == "5×")
        #expect(AccountInfo.multiplier(from: "default_claude_pro") == nil)
    }

    // MARK: Snapshot aggregation

    @Test("Headline window is the most-consumed window")
    func headlineWindow() {
        let usage = UsageResponse(
            fiveHour: RateLimitWindow(utilization: 42, remaining: nil, resetsAt: nil),
            sevenDay: RateLimitWindow(utilization: 10, remaining: nil, resetsAt: nil),
            sevenDayOpus: RateLimitWindow(utilization: 88, remaining: nil, resetsAt: nil),
            overage: nil)
        let snapshot = UsageSnapshot(capturedAt: Date(), account: nil, usage: usage)
        #expect(snapshot.percentUsed == 88)
        #expect(snapshot.severity == .orange) // 12% remaining → orange (10..<20)
    }

    @Test("Severity buckets map remaining% correctly", arguments: [
        (10.0, UsageSnapshot.Severity.green),    // 90% left
        (70.0, .yellow),                          // 30% left
        (85.0, .orange),                          // 15% left
        (93.0, .red),                             // 7% left
        (98.0, .critical),                        // 2% left
    ])
    func severityBuckets(util: Double, expected: UsageSnapshot.Severity) {
        let snap = UsageSnapshot(capturedAt: Date(), account: nil,
            usage: UsageResponse(
                fiveHour: RateLimitWindow(utilization: util, remaining: nil, resetsAt: nil),
                sevenDay: nil, sevenDayOpus: nil, overage: nil))
        #expect(snap.severity == expected)
    }
}
