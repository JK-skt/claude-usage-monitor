import WidgetKit
import SwiftUI
import ClaudeUsageCore

// Home-screen / Notification-Center widget for Claude Usage Monitor.
//
// This target is built by Xcode (a Widget Extension), not SwiftPM — WidgetKit requires
// an .appex bundle. See docs/WIDGET.md for how to add it to an Xcode project. It reads
// the latest snapshot the app publishes via the shared App Group (SharedSnapshotStore).

// MARK: Timeline

struct UsageEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageSnapshot?
    /// User-pinned headline metric id ("" = auto), so the widget matches the app.
    var pinnedID: String = ""
}

struct UsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: Date(), snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        let store = SharedSnapshotStore()
        completion(UsageEntry(date: Date(), snapshot: store.load(), pinnedID: store.loadHeadlinePin()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let store = SharedSnapshotStore()
        let entry = UsageEntry(date: Date(), snapshot: store.load(), pinnedID: store.loadHeadlinePin())
        // Refresh roughly every 15 minutes; the app also nudges reloads on each poll.
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

// MARK: Shared pieces

private func severityColor(_ s: UsageSnapshot.Severity) -> Color {
    switch s {
    case .green: return .green
    case .yellow: return .yellow
    case .orange: return .orange
    case .red, .critical: return .red
    }
}

/// Ring gauge (duplicated from the app so the widget target is self-contained).
private struct WidgetGauge: View {
    let remaining: Int
    let color: Color
    var lineWidth: CGFloat = 9

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.0001, Double(remaining) / 100.0))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: -2) {
                Text("\(remaining)").font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit()
                Text("% left").font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }
}

private struct MetricLine: View {
    let metric: UsageMetric
    var body: some View {
        HStack(spacing: 6) {
            Text(metric.label).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if metric.isMetered {
                Text(metric.spendText ?? "$0.00").font(.caption2).monospacedDigit()
            } else {
                Text("\(metric.percentUsed)%").font(.caption2).monospacedDigit()
            }
        }
    }
}

// MARK: Views by family

struct UsageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UsageEntry

    var body: some View {
        if let s = entry.snapshot {
            switch family {
            case .systemSmall: small(s)
            case .systemLarge: large(s)
            default: medium(s)
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "gauge.with.dots.needle.67percent").font(.title2).foregroundStyle(.orange)
                Text("Open Claude Usage Monitor").font(.caption2).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }.padding()
        }
    }

    private func small(_ s: UsageSnapshot) -> some View {
        VStack(spacing: 6) {
            WidgetGauge(remaining: s.percentRemaining(pinnedID: entry.pinnedID),
                        color: severityColor(s.severity(pinnedID: entry.pinnedID)))
                .frame(width: 78, height: 78)
            Text(s.planName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }.padding()
    }

    private func medium(_ s: UsageSnapshot) -> some View {
        HStack(spacing: 16) {
            WidgetGauge(remaining: s.percentRemaining(pinnedID: entry.pinnedID),
                        color: severityColor(s.severity(pinnedID: entry.pinnedID)))
                .frame(width: 82, height: 82)
            VStack(alignment: .leading, spacing: 6) {
                Text(s.planName).font(.headline)
                ForEach(s.metrics.prefix(3)) { MetricLine(metric: $0) }
                if let reset = s.nextReset {
                    Label(reset.formatted(.relative(presentation: .named)), systemImage: "clock.arrow.circlepath")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }.padding()
    }

    private func large(_ s: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                WidgetGauge(remaining: s.percentRemaining(pinnedID: entry.pinnedID),
                            color: severityColor(s.severity(pinnedID: entry.pinnedID)))
                    .frame(width: 90, height: 90)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Claude Usage").font(.headline)
                    Text(s.planName).font(.subheadline).foregroundStyle(.secondary)
                    if let spend = s.meteredSpend {
                        Label(ModelPricing.formatUSD(spend), systemImage: "dollarsign.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            Divider()
            ForEach(s.metrics) { MetricLine(metric: $0) }
            Spacer(minLength: 0)
            if let reset = s.nextReset {
                Label("Resets \(reset.formatted(.relative(presentation: .named)))",
                      systemImage: "clock.arrow.circlepath")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }.padding()
    }
}

// MARK: Widget entry point

struct ClaudeUsageWidget: Widget {
    let kind = "ClaudeUsageWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: UsageProvider()) { entry in
            UsageWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Claude Usage")
        .description("Remaining Claude quota, per-window usage, and reset time.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct ClaudeUsageWidgetBundle: WidgetBundle {
    var body: some Widget {
        ClaudeUsageWidget()
    }
}
