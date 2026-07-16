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
