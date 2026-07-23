import Foundation

/// CSV rendering for exportable usage data. Shared by the app's "Export CSV" action and
/// the CLI's `--csv` output so both emit an identical schema.
public enum UsageCSV {
    /// Usage history: one row per sample.
    public static func history(_ records: [UsageRecord]) -> String {
        var out = "timestamp,plan,remaining_percent,used_percent,metered_spend_usd,next_reset\n"
        let iso = ISO8601DateFormatter()
        for r in records {
            let reset = r.nextReset.map { iso.string(from: $0) } ?? ""
            let spend = r.meteredSpend.map { String(format: "%.2f", $0) } ?? ""
            out += "\(iso.string(from: r.timestamp)),\(field(r.plan)),\(r.percentRemaining),"
            out += "\(r.percentUsed),\(spend),\(reset)\n"
        }
        return out
    }

    /// Token breakdown: one row per model and per source for the selected window.
    public static func breakdown(_ b: TokenBreakdown, generatedAt: Date = Date()) -> String {
        var out = "generated_at,window_hours,group,name,messages,input,output,cache_creation,cache_read\n"
        let iso = ISO8601DateFormatter()
        let stamp = iso.string(from: generatedAt)
        func rows(_ group: String, _ items: [NamedTotals]) {
            for i in items {
                let t = i.totals
                out += "\(stamp),\(formatted(b.hours)),\(group),\(field(i.name)),"
                out += "\(t.messages),\(t.input),\(t.output),\(t.cacheCreation),\(t.cacheRead)\n"
            }
        }
        rows("model", b.byModel)
        rows("source", b.bySource)
        return out
    }

    private static func formatted(_ hours: Double) -> String {
        hours == hours.rounded() ? String(Int(hours)) : String(format: "%.1f", hours)
    }

    /// Quotes a field when it contains a comma, quote, or newline (RFC 4180).
    private static func field(_ s: String) -> String {
        guard s.contains(",") || s.contains("\"") || s.contains("\n") else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
