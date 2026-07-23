import Foundation
import UserNotifications
import ClaudeUsageCore

/// Fires local notifications when remaining quota crosses configured thresholds
/// (20 / 10 / 5 / 1 %), and once when the quota resets. Debounced so each threshold
/// alerts at most once per drain cycle.
@MainActor
final class NotificationManager {
    static let thresholds = [20, 10, 5, 1]

    /// Most severe threshold already alerted this cycle (nil = none yet).
    private var lastAlerted: Int?
    private var authorized = false
    /// Resolved on demand — `UNUserNotificationCenter.current()` raises when the process
    /// has no app bundle (e.g. the headless `--render-preview` QA path).
    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }

    /// Whether the user has enabled threshold alerts (persisted).
    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "notify.enabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "notify.enabled") }
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in self?.authorized = granted }
        }
    }

    func evaluate(_ snapshot: UsageSnapshot) {
        guard enabled else { return }
        let remaining = snapshot.percentRemaining

        // Reset detected: quota climbed back above the top threshold after we'd alerted.
        if let last = lastAlerted, remaining > Self.thresholds.max()! {
            notify(title: "Claude quota reset",
                   body: "Usage reset — \(remaining)% of your \(snapshot.planName) quota is available.")
            lastAlerted = nil
            _ = last
            return
        }

        // Most severe threshold currently crossed.
        guard let crossed = Self.thresholds.filter({ remaining <= $0 }).min() else { return }
        if lastAlerted == nil || crossed < lastAlerted! {
            notify(title: "Claude usage at \(remaining)%",
                   body: "\(remaining)% of your \(snapshot.planName) quota remains. Resets \(resetText(snapshot)).")
            lastAlerted = crossed
        }
    }

    private func resetText(_ s: UsageSnapshot) -> String {
        guard let reset = s.nextReset else { return "soon" }
        return Formatting.relative(reset)
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request)
    }
}
