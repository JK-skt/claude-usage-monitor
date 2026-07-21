import Foundation
import AppKit
import CryptoKit
import Security
import UserNotifications
import ClaudeUsageCore

/// Watches GitHub Releases for a newer build, notifies the user with the key changes,
/// and (optionally) installs the update automatically: download DMG → verify digest +
/// code signature → mount → atomically replace /Applications app → relaunch.
///
/// Trust model: talks only to the pinned public repo over HTTPS. Before an installed
/// bundle is swapped in, the download must clear an authenticity gate — the GitHub
/// asset's published sha256 digest must match, and the staged `.app` must be validly
/// code-signed (and, when the running app carries a Developer-ID team identifier, signed
/// by that same team). If no trust anchor can be established (no digest and no team
/// pin), the install is refused rather than run unverified code.
@MainActor
final class UpdateManager: ObservableObject {
    /// A newer release than the running build, when one exists.
    @Published private(set) var available: ReleaseInfo?
    @Published private(set) var isChecking = false
    @Published private(set) var isInstalling = false
    /// Human-readable progress while installing ("Downloading…", "Installing…").
    @Published private(set) var installStatus: String?
    @Published private(set) var lastChecked: Date?
    @Published private(set) var lastError: String?

    /// Check GitHub for updates on a 6-hour cadence (persisted).
    @Published var autoCheck: Bool {
        didSet {
            UserDefaults.standard.set(autoCheck, forKey: Keys.autoCheck)
            autoCheck ? startAutoCheck() : stopAutoCheck()
        }
    }

    /// Install updates without asking (persisted; off by default — the notification
    /// and in-menu banner still announce what changed).
    @Published var autoInstall: Bool {
        didSet { UserDefaults.standard.set(autoInstall, forKey: Keys.autoInstall) }
    }

    private enum Keys {
        static let autoCheck = "update.autoCheck"
        static let autoInstall = "update.autoInstall"
        static let skipped = "update.skippedVersion"
        static let notified = "update.lastNotifiedVersion"
    }

    private let checker = UpdateChecker()
    private var pollTask: Task<Void, Never>?
    private static let checkInterval: TimeInterval = 6 * 3600

    init() {
        self.autoCheck = UserDefaults.standard.object(forKey: Keys.autoCheck) as? Bool ?? true
        self.autoInstall = UserDefaults.standard.bool(forKey: Keys.autoInstall)
        if autoCheck { startAutoCheck() }
    }

    deinit {
        pollTask?.cancel()
    }

    // MARK: Checking

    func startAutoCheck() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            // Let the app settle before the first check.
            try? await Task.sleep(for: .seconds(10))
            while !Task.isCancelled {
                await self?.check(userInitiated: false)
                try? await Task.sleep(for: .seconds(Self.checkInterval))
            }
        }
    }

    private func stopAutoCheck() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Queries GitHub; on a newer release: publishes it, notifies once per version,
    /// and auto-installs when enabled. User-initiated checks ignore a skipped version.
    func check(userInitiated: Bool) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false; lastChecked = Date() }

        do {
            guard let release = try await checker.availableUpdate(currentVersion: AppVersion.current) else {
                available = nil
                lastError = nil
                return
            }
            let skipped = UserDefaults.standard.string(forKey: Keys.skipped)
            if !userInitiated, release.version == skipped { return }

            available = release
            lastError = nil
            notifyOncePerVersion(release)

            if autoInstall, !userInitiated {
                await install(release, userInitiated: false)
            }
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Hide this version from future automatic prompts (a newer one will still surface).
    func skip(_ release: ReleaseInfo) {
        UserDefaults.standard.set(release.version, forKey: Keys.skipped)
        available = nil
    }

    // MARK: Notification (includes the key changes)

    private func notifyOncePerVersion(_ release: ReleaseInfo) {
        let already = UserDefaults.standard.string(forKey: Keys.notified)
        guard release.version != already else { return }
        UserDefaults.standard.set(release.version, forKey: Keys.notified)

        let content = UNMutableNotificationContent()
        content.title = "Claude Usage Monitor \(release.tagName) available"
        let lines = release.highlights(max: 3)
        content.body = lines.isEmpty
            ? "A new version is ready to install."
            : lines.map { "• \($0)" }.joined(separator: "\n")
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "update-\(release.version)", content: content, trigger: nil))
    }

    // MARK: Install

    /// Downloads the release DMG, verifies authenticity, atomically swaps the installed
    /// `.app`, and relaunches. When there is no installable DMG or we're not running from
    /// a `.app` bundle (e.g. `swift run` dev builds), only a *user-initiated* install
    /// falls back to opening the release page — the automatic path never opens a browser.
    func install(_ release: ReleaseInfo, userInitiated: Bool = true) async {
        guard !isInstalling else { return }
        guard AppVersion.isBundledApp, let asset = release.dmgAsset else {
            if userInitiated, let url = release.htmlURL { NSWorkspace.shared.open(url) }
            else { lastError = "No installable DMG for \(release.tagName)." }
            return
        }
        // Translocated (Gatekeeper app-quarantine) copies live in a read-only shadow path
        // and cannot be replaced in place; sending the user to the page is the safe move.
        if Bundle.main.bundlePath.contains("/AppTranslocation/") {
            lastError = "Move the app to Applications to enable auto-update."
            if userInitiated, let url = release.htmlURL { NSWorkspace.shared.open(url) }
            return
        }
        isInstalling = true
        defer { isInstalling = false; installStatus = nil }

        do {
            installStatus = "Downloading \(release.tagName)…"
            let dmg = try await Self.download(asset)
            defer { try? FileManager.default.removeItem(at: dmg) }

            installStatus = "Verifying…"
            let digestChecked = try await Self.verifyDigest(of: dmg, against: asset.digest)

            installStatus = "Installing…"
            let target = try await Self.stageAndSwap(dmg: dmg, digestChecked: digestChecked)

            installStatus = "Relaunching…"
            relaunch(from: target)
        } catch {
            lastError = "Update failed: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    private struct InstallError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // All heavy lifting below is `nonisolated static` so it runs off the main actor
    // (hdiutil, ditto, checksum, and file swaps are slow / blocking); only the
    // @Published status strings above are touched on @MainActor.

    private nonisolated static func download(_ asset: ReleaseInfo.Asset) async throws -> URL {
        guard asset.browserDownloadURL.scheme == "https" else {
            throw InstallError(message: "Refusing non-HTTPS download URL.")
        }
        let (tmp, response) = try await URLSession.shared.download(from: asset.browserDownloadURL)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw InstallError(message: "Download failed (HTTP \(http.statusCode)).")
        }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("cum-update-\(UUID().uuidString).dmg")
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    /// Streams the file through SHA-256 and compares to GitHub's published digest.
    /// Returns whether a digest was actually verified (false = none published). Hashing
    /// is chunked so a large DMG never loads fully into memory.
    private nonisolated static func verifyDigest(of file: URL, against digest: String?) async throws -> Bool {
        guard let digest, digest.hasPrefix("sha256:") else { return false } // none published
        let expected = digest.dropFirst("sha256:".count).lowercased()
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while case let chunk = try handle.read(upToCount: 1 << 20) ?? Data(), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == expected else {
            throw InstallError(message: "Checksum mismatch — download discarded.")
        }
        return true
    }

    /// Mounts the DMG, verifies the contained app's authenticity, then atomically swaps
    /// it in for the running bundle (with rollback on failure). Returns the installed path.
    private nonisolated static func stageAndSwap(dmg: URL, digestChecked: Bool) async throws -> URL {
        let installedURL = URL(fileURLWithPath: Bundle.main.bundlePath)
        let mount = FileManager.default.temporaryDirectory
            .appendingPathComponent("cum-mount-\(UUID().uuidString)")

        try await runProcess("/usr/bin/hdiutil",
                             ["attach", dmg.path, "-nobrowse", "-readonly", "-mountpoint", mount.path])
        defer {
            Task.detached { try? await runProcess("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
        }

        let contents = try FileManager.default.contentsOfDirectory(atPath: mount.path)
        guard let appName = contents.first(where: { $0.hasSuffix(".app") }) else {
            throw InstallError(message: "No .app found inside the update DMG.")
        }
        let newApp = mount.appendingPathComponent(appName)

        // ── Authenticity gate ────────────────────────────────────────────────────────
        try verifyAuthenticity(of: newApp, installed: installedURL, digestChecked: digestChecked)

        // ditto to a same-volume staging copy (preserves signature/permissions).
        let staging = installedURL.deletingLastPathComponent()
            .appendingPathComponent("cum-staged-\(UUID().uuidString).app")
        try await runProcess("/usr/bin/ditto", [newApp.path, staging.path])
        defer { try? FileManager.default.removeItem(at: staging) }

        // Atomic replace with rollback: replaceItemAt swaps in one operation and restores
        // the original if anything fails, so a failed update never deletes the app.
        let fm = FileManager.default
        do {
            _ = try fm.replaceItemAt(installedURL, withItemAt: staging)
        } catch {
            throw InstallError(message: "Couldn't replace the app in place: \(error.localizedDescription)")
        }
        return installedURL
    }

    /// Refuses to install a bundle we can't authenticate: the staged app must be validly
    /// code-signed, must match the running app's team identifier when it has one, and —
    /// absent a Developer-ID team pin — must have arrived with a verified digest.
    private nonisolated static func verifyAuthenticity(of newApp: URL, installed: URL,
                                                       digestChecked: Bool) throws {
        guard isValidlySigned(newApp) else {
            throw InstallError(message: "Update is not validly code-signed — refusing to install.")
        }
        let runningTeam = teamIdentifier(ofBundleAt: installed)
        if let runningTeam {
            let newTeam = teamIdentifier(ofBundleAt: newApp)
            guard newTeam == runningTeam else {
                throw InstallError(message: "Update is signed by a different developer (\(newTeam ?? "unsigned")) — refusing.")
            }
        } else if !digestChecked {
            // Ad-hoc running app AND no published checksum → no trust anchor at all.
            throw InstallError(message: "Can't verify this update's authenticity (no checksum or developer signature).")
        }
    }

    /// True when the bundle's own code signature is structurally valid (untampered).
    private nonisolated static func isValidlySigned(_ url: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else {
            return false
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess
    }

    /// The Developer-ID team identifier a bundle is signed with, or nil (ad-hoc/unsigned).
    private nonisolated static func teamIdentifier(ofBundleAt url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else {
            return nil
        }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Launches the given app and terminates this instance only once it has actually
    /// started — a failed launch leaves the current app running with an error shown.
    private func relaunch(from app: URL) {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: app, configuration: config) { [weak self] _, error in
            Task { @MainActor in
                if let error {
                    self?.lastError = "Installed, but relaunch failed: \(error.localizedDescription). Reopen the app manually."
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    /// Async Process runner (non-blocking; fails on non-zero exit).
    private nonisolated static func runProcess(_ launchPath: String, _ arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: launchPath)
            p.arguments = arguments
            p.standardOutput = FileHandle.nullDevice
            p.standardError = Pipe()
            p.terminationHandler = { proc in
                if proc.terminationStatus == 0 { cont.resume() }
                else {
                    cont.resume(throwing: InstallError(
                        message: "\((launchPath as NSString).lastPathComponent) exited with \(proc.terminationStatus)"))
                }
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }
}
