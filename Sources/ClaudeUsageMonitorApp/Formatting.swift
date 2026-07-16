import Foundation

enum Formatting {
    /// "in 3h 12m", "in 45m", or "now".
    static func relative(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        let delta = date.timeIntervalSince(now)
        guard delta > 0 else { return "now" }
        let hours = Int(delta) / 3600
        let minutes = (Int(delta) % 3600) / 60
        if hours > 0 { return "in \(hours)h \(minutes)m" }
        return "in \(minutes)m"
    }

    static func absolute(_ date: Date?) -> String {
        guard let date else { return "—" }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    static func time(_ date: Date?) -> String {
        guard let date else { return "—" }
        let f = DateFormatter()
        f.timeStyle = .short
        return f.string(from: date)
    }

    /// 1_240_000 → "1.24M".
    static func compact(_ value: Double?) -> String {
        guard let value else { return "—" }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        switch value {
        case 1_000_000...:
            return String(format: "%.2fM", value / 1_000_000)
        case 1_000...:
            return String(format: "%.1fK", value / 1_000)
        default:
            return f.string(from: NSNumber(value: value)) ?? "\(Int(value))"
        }
    }
}
