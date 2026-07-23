import SwiftUI
import ClaudeUsageCore

/// A circular "remaining capacity" gauge. `fraction` is 0...1 of the ring that should
/// be filled (we pass *remaining* capacity, so a full green ring = lots left).
struct GaugeRing: View {
    let fraction: Double
    let color: Color
    var lineWidth: CGFloat = 8

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.10), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.0001, min(fraction, 1)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.45), value: fraction)
        }
    }
}

/// A slim rounded usage bar. `fraction` is 0...1 consumed.
struct UsageBar: View {
    let fraction: Double
    let color: Color
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(color)
                    .frame(width: geo.size.width * min(max(fraction, 0), 1))
                    .animation(.easeInOut(duration: 0.35), value: fraction)
            }
        }
        .frame(height: height)
    }
}

/// A compact sparkline of recent *used%* samples (0…100). Draws a filled area under a
/// smooth line — enough to read the trend at a glance in the menu.
struct Sparkline: View {
    /// Values in 0...100, oldest → newest.
    let values: [Double]
    var color: Color = .accentColor

    var body: some View {
        GeometryReader { geo in
            let pts = points(in: geo.size)
            ZStack {
                if pts.count >= 2 {
                    // Filled area.
                    Path { p in
                        p.move(to: CGPoint(x: pts[0].x, y: geo.size.height))
                        for pt in pts { p.addLine(to: pt) }
                        p.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: geo.size.height))
                        p.closeSubpath()
                    }
                    .fill(color.opacity(0.15))
                    // Line.
                    Path { p in
                        p.move(to: pts[0])
                        for pt in pts.dropFirst() { p.addLine(to: pt) }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                }
            }
        }
    }

    private func points(in size: CGSize) -> [CGPoint] {
        guard values.count >= 2 else { return [] }
        let maxV = 100.0, minV = 0.0
        let dx = size.width / CGFloat(values.count - 1)
        return values.enumerated().map { i, v in
            let norm = (v - minV) / (maxV - minV)
            return CGPoint(x: CGFloat(i) * dx, y: size.height * (1 - CGFloat(norm)))
        }
    }
}

/// Burn rate / Runs out / Reset — the forecast promoted to first-class information.
/// The "RUNS OUT" stat tints orange when exhaustion is projected *before* the reset.
struct ForecastStrip: View {
    let prediction: UsagePrediction
    let nextReset: Date?

    /// True when the quota is projected to run out before it resets — the case worth warning about.
    var runsOutBeforeReset: Bool {
        guard let out = prediction.exhaustionAt, let reset = nextReset else { return false }
        return out < reset
    }

    var body: some View {
        HStack(spacing: 8) {
            let rate = splitNumberUnit(String(format: "%.1f", prediction.ratePerHour), "%/h")
            stat("BURN RATE", rate.0, rate.1)

            let out = clockParts(prediction.exhaustionAt)
            stat("RUNS OUT", out.0, out.1, warning: runsOutBeforeReset)

            let reset = clockParts(nextReset)
            stat("RESET", reset.0, reset.1)
        }
    }

    /// "9:42 PM" → ("9:42", " PM") so the meridiem can be de-emphasized.
    private func clockParts(_ date: Date?) -> (String, String) {
        guard let date else { return ("—", "") }
        let text = Formatting.time(date)
        if let range = text.range(of: " ") {
            return (String(text[..<range.lowerBound]), String(text[range.lowerBound...]))
        }
        return (text, "")
    }

    private func splitNumberUnit(_ value: String, _ unit: String) -> (String, String) {
        (value, unit)
    }

    private func stat(_ label: String, _ value: String, _ unit: String,
                      warning: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9))
                .tracking(0.5)
                .foregroundStyle(warning ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary))
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(value)
                    .font(.system(size: 14, weight: .bold)).monospacedDigit()
                    .foregroundStyle(warning ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.primary))
                Text(unit)
                    .font(.system(size: 10))
                    .foregroundStyle(warning ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
            }
            .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(warning ? Color.orange.opacity(0.10) : Color.primary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Usage forecast: measured history (line + area) continued by a dashed projection to the
/// exhaustion point, with a 100% limit rule and a reset marker.
///
/// Hand-drawn rather than Swift Charts — Charts trapped (`EXC_BREAKPOINT`) on real
/// datasets in this app, so the whole chart surface stays dependency-free.
struct ForecastChart: View {
    /// Measured samples (used %, 0…100) oldest → newest, with timestamps.
    let history: [(date: Date, used: Double)]
    let exhaustionAt: Date?
    let nextReset: Date?
    var color: Color = .orange

    var body: some View {
        GeometryReader { geo in
            plot(in: geo.size)
        }
    }

    /// Geometry + drawing. A plain method (not a `@ViewBuilder` closure) so it can declare
    /// the scale helpers it needs.
    private func plot(in size: CGSize) -> some View {
        // Inset so the 100% rule and the projection endpoint aren't flush against the
        // frame edges (they were being clipped).
        let topInset: CGFloat = 6, bottomInset: CGFloat = 2, sideInset: CGFloat = 1
        let w = size.width - sideInset * 2
        let h = size.height - topInset - bottomInset
        guard let start = history.first?.date, let lastPoint = history.last, w > 1, h > 1 else {
            return AnyView(EmptyView())
        }
        // Time axis spans the history plus whichever marker lies furthest ahead.
        let end = [lastPoint.date, exhaustionAt, nextReset].compactMap { $0 }.max() ?? lastPoint.date
        // 4% headroom so a marker landing on `end` isn't drawn flush against the frame.
        let span = max(end.timeIntervalSince(start), 60) * 1.04
        func x(_ d: Date) -> CGFloat { sideInset + CGFloat(d.timeIntervalSince(start) / span) * w }
        func y(_ used: Double) -> CGFloat {
            topInset + h * (1 - CGFloat(min(max(used, 0), 100) / 100))
        }

        let pts = history.map { CGPoint(x: x($0.date), y: y($0.used)) }
        let limitY = y(100)
        let resetX: CGFloat? = nextReset.flatMap { r in (r >= start && r <= end) ? x(r) : nil }
        let projection: (from: CGPoint, to: CGPoint)? = exhaustionAt.flatMap { out in
            out > lastPoint.date
                ? (CGPoint(x: x(lastPoint.date), y: y(lastPoint.used)), CGPoint(x: x(out), y: y(100)))
                : nil
        }

        return AnyView(ZStack {
            // 100% limit.
            Path { p in
                p.move(to: CGPoint(x: sideInset, y: limitY))
                p.addLine(to: CGPoint(x: sideInset + w, y: limitY))
            }
            .stroke(Color.red.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

            // Reset marker.
            if let rx = resetX {
                Path { p in
                    p.move(to: CGPoint(x: rx, y: topInset))
                    p.addLine(to: CGPoint(x: rx, y: topInset + h))
                }
                .stroke(Color.primary.opacity(0.28), style: StrokeStyle(lineWidth: 1))
            }

            if pts.count >= 2 {
                // Measured area + line.
                Path { p in
                    let base = topInset + h
                    p.move(to: CGPoint(x: pts[0].x, y: base))
                    for pt in pts { p.addLine(to: pt) }
                    p.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: base))
                    p.closeSubpath()
                }
                .fill(color.opacity(0.12))
                Path { p in
                    p.move(to: pts[0])
                    for pt in pts.dropFirst() { p.addLine(to: pt) }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }

            // Dashed projection from the last sample to 100% at the exhaustion time.
            if let proj = projection {
                Path { p in
                    p.move(to: proj.from)
                    p.addLine(to: proj.to)
                }
                .stroke(color.opacity(0.85), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }
        })
    }
}

/// A labelled token bar — one row of the "by model" / "by source" breakdowns.
struct TokenBarRow: View {
    let name: String
    let tokens: Int
    /// 0…1 share of the largest row, for the bar width.
    let fraction: Double
    var color: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(name).font(.caption).lineLimit(1)
                Spacer()
                Text(TokenBarRow.compact(tokens))
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
            UsageBar(fraction: fraction, color: color, height: 5)
        }
    }

    static func compact(_ n: Int) -> String {
        let d = Double(n)
        if d >= 1_000_000 { return String(format: "%.1fM", d / 1_000_000) }
        if d >= 1_000 { return String(format: "%.1fK", d / 1_000) }
        return "\(n)"
    }
}

/// Small pill used to mark the currently-binding window.
struct ActiveBadge: View {
    var body: some View {
        Text("active")
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Color.accentColor.opacity(0.16), in: Capsule())
            .foregroundStyle(Color.accentColor)
    }
}
