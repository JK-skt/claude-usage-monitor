import Foundation
import ServiceManagement

/// Wraps `SMAppService.mainApp` to expose a "Launch at login" toggle.
///
/// `SMAppService` is the modern (macOS 13+) replacement for login-item plists: it
/// registers *this very app bundle* as a login item, managed by the system and visible
/// to the user under System Settings › General › Login Items. It requires a real,
/// signed `.app` bundle (see `scripts/build-app.sh`).
@MainActor
final class LoginItemManager: ObservableObject {
    @Published private(set) var status: SMAppService.Status = .notRegistered

    init() { refresh() }

    var isEnabled: Bool { status == .enabled }

    /// The user must approve in System Settings before it takes effect.
    var needsApproval: Bool { status == .requiresApproval }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    /// Returns an error message on failure, or `nil` on success.
    @discardableResult
    func setEnabled(_ enable: Bool) -> String? {
        var message: String?
        do {
            if enable {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            message = error.localizedDescription
        }
        refresh()
        return message
    }
}
