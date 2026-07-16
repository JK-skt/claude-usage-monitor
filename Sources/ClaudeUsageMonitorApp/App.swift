import SwiftUI
import AppKit
import ServiceManagement
import ClaudeUsageCore

/// Entry point. Intercepts a few CLI flags (used by scripts / for headless testing of
/// the login-item registration) before handing off to the SwiftUI app.
@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--login-status") {
            print(loginStatusString()); exit(0)
        }
        if args.contains("--register-login") {
            do { try SMAppService.mainApp.register(); print("registered: \(loginStatusString())") }
            catch { FileHandle.standardError.write(Data("register failed: \(error)\n".utf8)); exit(1) }
            exit(0)
        }
        if args.contains("--unregister-login") {
            do { try SMAppService.mainApp.unregister(); print("unregistered: \(loginStatusString())") }
            catch { FileHandle.standardError.write(Data("unregister failed: \(error)\n".utf8)); exit(1) }
            exit(0)
        }
        ClaudeUsageMonitorApp.main()
    }

    static func loginStatusString() -> String {
        switch SMAppService.mainApp.status {
        case .notRegistered: return "notRegistered"
        case .enabled: return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notFound: return "notFound"
        @unknown default: return "unknown"
        }
    }
}

struct ClaudeUsageMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = MenuBarViewModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(model: model)
        } label: {
            MenuBarLabel(state: model.state)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Hides the Dock icon so the app behaves as a proper menu-bar accessory.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

/// The compact menu-bar label. Renders `Claude 82%` (or an icon on error/loading),
/// tinted by severity.
struct MenuBarLabel: View {
    let state: MenuBarViewModel.State

    var body: some View {
        switch state {
        case .loading:
            Image(systemName: "hourglass")
        case .failed:
            Image(systemName: "exclamationmark.triangle")
        case .loaded(let snapshot):
            Text("Claude \(snapshot.percentRemaining)%")
                .foregroundStyle(color(for: snapshot.severity))
                .monospacedDigit()
        }
    }

    private func color(for severity: UsageSnapshot.Severity) -> Color {
        switch severity {
        case .green: return .green
        case .yellow: return .yellow
        case .orange: return .orange
        case .red: return .red
        case .critical: return .red
        }
    }
}
