import Foundation

/// Pay-as-you-go token pricing for a model.
///
/// As of the 2026-07 policy change, **Fable is metered (usage-based)** rather than
/// bounded by a session/weekly quota: usage is billed per token at
/// **$10 / 1M input tokens** and **$50 / 1M output tokens**. This type turns raw
/// token counts (or dollar figures the server later reports) into a displayable cost,
/// and is the single source of truth for those rates.
///
/// Rates are expressed *per million tokens* because that is how the policy is stated;
/// `cost(inputTokens:outputTokens:)` normalizes to per-token internally.
public struct ModelPricing: Sendable, Hashable, Codable {
    /// USD charged per 1,000,000 input tokens.
    public let inputPerMillion: Decimal
    /// USD charged per 1,000,000 output tokens.
    public let outputPerMillion: Decimal

    public init(inputPerMillion: Decimal, outputPerMillion: Decimal) {
        self.inputPerMillion = inputPerMillion
        self.outputPerMillion = outputPerMillion
    }

    /// The current Fable metered rate: $10 / 1M input, $50 / 1M output.
    public static let fable = ModelPricing(inputPerMillion: 10, outputPerMillion: 50)

    /// Known pay-as-you-go pricing for a model, looked up by its display name
    /// (case-insensitive). Returns `nil` for models still on a fixed quota.
    public static func forModel(_ name: String?) -> ModelPricing? {
        guard let name else { return nil }
        switch name.lowercased() {
        case "fable": return .fable
        default:      return nil
        }
    }

    /// A metered charge split into its input and output components.
    public struct CostBreakdown: Sendable, Hashable, Codable {
        public let inputTokens: Int
        public let outputTokens: Int
        public let inputCost: Decimal
        public let outputCost: Decimal

        public var total: Decimal { inputCost + outputCost }
        public var totalTokens: Int { inputTokens + outputTokens }

        /// Total as a `Double` for chart/JSON consumers. Money is computed in `Decimal`;
        /// only convert at the display boundary.
        public var totalDollars: Double { NSDecimalNumber(decimal: total).doubleValue }
    }

    /// Cost of a given input/output token workload under this pricing.
    public func cost(inputTokens: Int, outputTokens: Int) -> CostBreakdown {
        let million: Decimal = 1_000_000
        let inputCost = Decimal(max(inputTokens, 0)) / million * inputPerMillion
        let outputCost = Decimal(max(outputTokens, 0)) / million * outputPerMillion
        return CostBreakdown(inputTokens: max(inputTokens, 0),
                             outputTokens: max(outputTokens, 0),
                             inputCost: inputCost,
                             outputCost: outputCost)
    }

    /// USD rendered as `$1.23` (2 fraction digits). Shared so the CLI and app agree.
    public static func formatUSD(_ amount: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.locale = Locale(identifier: "en_US")
        return f.string(from: NSDecimalNumber(decimal: amount)) ?? "$\(amount)"
    }

    public static func formatUSD(_ amount: Double) -> String {
        formatUSD(Decimal(amount))
    }
}
