import SwiftUI
import ClaudeUsageCore

/// Overview tab — hero gauge, forecast strip, then per-window usage.
///
/// Mental model (handoff §00): every *bar* reads as **used** — fill, number, and color all
/// move the same direction. Only the hero ring keeps "% left", where the fuel-gauge
/// metaphor is the point.
struct OverviewTab: View {
    @ObservedObject var model: MenuBarViewModel
    let snapshot: UsageSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            hero

            if let p = model.prediction, p.ratePerHour > 0.05 {
                ForecastStrip(prediction: p, nextReset: snapshot.nextReset)
            }

            Divider()

            VStack(alignment: .leading, spacing: 9) {
                ForEach(snapshot.metrics) { metricRow($0) }
            }

            // "Show all details" (Settings › Display) reveals account/plan context.
            if model.detailed {
                Divider()
                detailSection
            }
        }
    }

    // MARK: Details (opt-in)

    private var detailSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("DETAILS")
                .font(.system(size: 9, weight: .bold)).tracking(0.8).foregroundStyle(.tertiary)
            if let reset = snapshot.nextReset {
                detailRow("Next reset", Formatting.absolute(reset))
            }
            detailRow("Severity", snapshot.severity(pinnedID: model.headlineMetricID).rawValue.capitalized)
            if let a = snapshot.account {
                if let org = a.organizationName { detailRow("Organization", org) }
                if let name = a.displayName { detailRow("Account", name) }
                if let email = a.emailAddress { detailRow("Email", email) }
                if let tier = a.organizationRateLimitTier { detailRow("Tier", tier) }
                if let billing = a.billingType { detailRow("Billing", billing) }
                if let extra = a.hasExtraUsageEnabled { detailRow("Extra usage", extra ? "on" : "off") }
            }
            if let overage = snapshot.usage.overage, let status = overage.status {
                detailRow("Overage", status)
            }
            if let spend = snapshot.meteredSpend {
                detailRow("Metered spend", ModelPricing.formatUSD(spend))
            }
            detailRow("Captured", Formatting.absolute(snapshot.capturedAt))
        }
    }

    private func detailRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(key).font(.system(size: 10)).foregroundStyle(.tertiary)
            Spacer()
            Text(value).font(.system(size: 10)).foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing).lineLimit(1).minimumScaleFactor(0.8)
        }
    }

    // MARK: Hero

    private var hero: some View {
        let pinned = model.headlineMetricID
        let remaining = snapshot.percentRemaining(pinnedID: pinned)
        let severity = snapshot.severity(pinnedID: pinned)
        let headline = snapshot.headlineMetric(pinnedID: pinned)
        return HStack(spacing: 14) {
            ZStack {
                GaugeRing(fraction: Double(remaining) / 100.0,
                          color: color(severity), lineWidth: 8)
                    .frame(width: 64, height: 64)
                VStack(spacing: -2) {
                    Text("\(remaining)")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("% left").font(.system(size: 8)).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                // "Session (5h) · most used" — the window this headline reflects, inline.
                HStack(spacing: 4) {
                    Text(headline?.label ?? snapshot.planName)
                        .font(.system(size: 14, weight: .bold)).lineLimit(1)
                    Text(pinned.isEmpty ? "· most used" : "· pinned")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if let reset = snapshot.nextReset {
                    Text("Resets \(Formatting.time(reset)) · \(Formatting.relative(reset))")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                if model.runsOutBeforeReset {
                    Label("Projected to run out before reset", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11)).foregroundStyle(.orange).lineLimit(1)
                }
                if model.lastError != nil {
                    Label("Showing last known values", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10)).foregroundStyle(.orange).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Metrics

    @ViewBuilder
    private func metricRow(_ m: UsageMetric) -> some View {
        if m.hasQuota {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(m.label).font(.system(size: 11))
                    if m.isActive { ActiveBadge() }
                    Spacer(minLength: 4)
                    // "63% used · resets 2h" — value and reset together, on one line.
                    Text("\(m.percentUsed)% used")
                        .font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(color(forFraction: m.fractionUsed))
                    if let reset = m.resetsAt {
                        Text("· \(shortReset(reset))")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
                UsageBar(fraction: m.fractionUsed,
                         color: color(forFraction: m.fractionUsed), height: 5)
                if model.detailed, let reset = m.resetsAt {
                    Text("resets \(Formatting.absolute(reset))")
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            }
        } else {
            // Metered window (Fable): a spend figure and its rate — no quota bar.
            HStack(spacing: 5) {
                Text(m.label).font(.system(size: 11)).lineLimit(1)
                if m.isActive { ActiveBadge() }
                Spacer(minLength: 4)
                Text(m.spendText ?? "$0.00").font(.system(size: 11)).monospacedDigit()
                if let p = m.pricing {
                    Text("· $\(rate(p.inputPerMillion))/M in · $\(rate(p.outputPerMillion))/M out")
                        .font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
        }
    }

    // MARK: Helpers

    /// "resets 2h" / "resets Thu" — compact enough to sit on the metric row.
    private func shortReset(_ date: Date) -> String {
        let delta = date.timeIntervalSinceNow
        guard delta > 0 else { return "resetting" }
        if delta < 24 * 3600 {
            let h = Int(delta) / 3600, m = (Int(delta) % 3600) / 60
            return h > 0 ? "resets \(h)h" : "resets \(m)m"
        }
        return "resets \(Formatting.weekday(date))"
    }

    private func rate(_ d: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 2
        return f.string(from: NSDecimalNumber(decimal: d)) ?? "\(d)"
    }

    private func color(_ severity: UsageSnapshot.Severity) -> Color {
        switch severity {
        case .green: return .green
        case .yellow: return .yellow
        case .orange: return .orange
        case .red, .critical: return .red
        }
    }

    private func color(forFraction f: Double) -> Color {
        switch Int(f * 100) {
        case ..<50: return .green
        case 50..<80: return .yellow
        case 80..<95: return .orange
        default: return .red
        }
    }
}
