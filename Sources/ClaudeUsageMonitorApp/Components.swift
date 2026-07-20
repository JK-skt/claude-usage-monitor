import SwiftUI

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
