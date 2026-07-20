import Foundation

/// Renders a usage snapshot (+ optional prediction) as Prometheus text-format metrics,
/// suitable for scraping into Grafana.
public enum PrometheusExporter {
    public static func format(_ snapshot: UsageSnapshot,
                              prediction: UsagePrediction? = nil,
                              now: Date = Date()) -> String {
        var out = ""

        func line(_ s: String) { out += s + "\n" }
        func metric(_ name: String, _ help: String, _ type: String) {
            line("# HELP \(name) \(help)")
            line("# TYPE \(name) \(type)")
        }

        metric("claude_usage_remaining_percent", "Headline quota remaining (0-100).", "gauge")
        line("claude_usage_remaining_percent \(snapshot.percentRemaining)")

        metric("claude_usage_used_percent", "Headline quota consumed (0-100).", "gauge")
        line("claude_usage_used_percent \(snapshot.percentUsed)")

        metric("claude_metric_used_ratio", "Per-window fraction consumed (0-1).", "gauge")
        for m in snapshot.metrics {
            let labels = "id=\"\(escape(m.id))\",label=\"\(escape(m.label))\",metered=\"\(m.isMetered)\""
            line("claude_metric_used_ratio{\(labels)} \(fmt(m.fractionUsed))")
        }

        let metered = snapshot.metrics.filter { $0.isMetered }
        if !metered.isEmpty {
            metric("claude_metric_spend_usd", "Per-metric metered spend to date (USD).", "gauge")
            for m in metered {
                line("claude_metric_spend_usd{id=\"\(escape(m.id))\"} \(fmt(m.usedDollars ?? 0))")
            }
        }
        if let spend = snapshot.meteredSpend {
            metric("claude_metered_spend_usd", "Total metered spend to date (USD).", "gauge")
            line("claude_metered_spend_usd \(fmt(spend))")
        }

        metric("claude_next_reset_seconds", "Seconds until the soonest window resets.", "gauge")
        if let reset = snapshot.nextReset {
            line("claude_next_reset_seconds \(fmt(max(0, reset.timeIntervalSince(now))))")
        }

        if let p = prediction {
            metric("claude_usage_rate_per_hour", "Predicted quota consumed per hour (pct pts).", "gauge")
            line("claude_usage_rate_per_hour \(fmt(p.ratePerHour))")
            if let hours = p.hoursUntilExhaustion {
                metric("claude_usage_hours_until_exhaustion", "Predicted hours until quota exhaustion.", "gauge")
                line("claude_usage_hours_until_exhaustion \(fmt(hours))")
            }
        }

        metric("claude_usage_last_updated_seconds", "Unix time of the snapshot.", "gauge")
        line("claude_usage_last_updated_seconds \(fmt(snapshot.capturedAt.timeIntervalSince1970))")

        return out
    }

    private static func fmt(_ d: Double) -> String {
        if d == d.rounded() && abs(d) < 1e15 { return String(Int(d)) }
        return String(format: "%.4f", d)
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "\n", with: "\\n")
    }
}
