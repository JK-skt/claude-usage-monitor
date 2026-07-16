import Foundation
import Security

/// Abstraction over "where do the OAuth credentials come from" so tests can inject
/// fakes and future sources (Claude Desktop, env var) can be added behind one type.
public protocol CredentialProviding: Sendable {
    func loadCredentials() throws -> OAuthCredentials
}

public enum CredentialError: Error, LocalizedError, Equatable {
    case itemNotFound
    case unexpectedData
    case interactionRequired
    case timedOut
    case keychain(OSStatus)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .itemNotFound:
            return "No Claude Code credentials found in the Keychain. Sign in with Claude Code first (`claude`)."
        case .unexpectedData:
            return "The Keychain item did not contain readable credential data."
        case .interactionRequired:
            return "macOS needs authorization to read the 'Claude Code-credentials' Keychain item. Run once interactively and click 'Always Allow'."
        case .timedOut:
            return "Timed out waiting for Keychain authorization. Grant access once interactively (click 'Always Allow'), then retry."
        case .keychain(let status):
            let msg = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Keychain access failed: \(msg)"
        case .decoding(let detail):
            return "Could not decode credentials: \(detail)"
        }
    }
}

/// Reads Claude Code's OAuth credentials from the login Keychain.
///
/// Item coordinates (verified on macOS via `security find-generic-password`):
/// - `kSecClass`       = `kSecClassGenericPassword`
/// - `kSecAttrService` = `"Claude Code-credentials"`
/// - `kSecAttrAccount` = current macOS short user name
///
/// ## Authorization
/// The item's ACL is owned by Claude Code, so the **first** read of the secret from
/// any other binary triggers a macOS "Allow / Always Allow" dialog. After the user
/// clicks *Always Allow* (once, per signed binary identity), subsequent reads are
/// silent. In non-interactive contexts the read is time-bounded so it fails with
/// ``CredentialError/timedOut`` instead of blocking forever on that dialog.
public struct KeychainCredentialStore: CredentialProviding {
    public static let service = "Claude Code-credentials"

    private let service: String
    private let account: String
    private let allowInteraction: Bool
    private let timeout: TimeInterval

    /// - Parameters:
    ///   - allowInteraction: `true` (default) is correct for the GUI app — macOS may
    ///     show the one-time authorization dialog. `false` suits cron/CI.
    ///   - timeout: Upper bound on the blocking Keychain call. Defaults to 30s when
    ///     interactive (leaves room to click the dialog) and 3s otherwise.
    public init(service: String = KeychainCredentialStore.service,
                account: String = NSUserName(),
                allowInteraction: Bool = true,
                timeout: TimeInterval? = nil) {
        self.service = service
        self.account = account
        self.allowInteraction = allowInteraction
        self.timeout = timeout ?? (allowInteraction ? 30 : 3)
    }

    public func loadCredentials() throws -> OAuthCredentials {
        let data = try readRawData()
        do {
            return try OAuthCredentials.decode(from: data)
        } catch {
            throw CredentialError.decoding(String(describing: error))
        }
    }

    /// Thread-safe transport for values crossing the background-queue boundary.
    private final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ v: T) { value = v }
    }

    /// Raw Keychain payload. Runs the synchronous `SecItemCopyMatching` on a background
    /// queue and waits up to `timeout`, so a blocking ACL dialog can't wedge the caller.
    public func readRawData() throws -> Data {
        let service = self.service
        let account = self.account
        let allowInteraction = self.allowInteraction

        let dataBox = Box<Data?>(nil)
        let statusBox = Box<OSStatus>(errSecSuccess)
        let semaphore = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .userInitiated).async {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            if !account.isEmpty {
                query[kSecAttrAccount as String] = account
            }
            if !allowInteraction {
                query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
            }
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            statusBox.value = status
            dataBox.value = item as? Data
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            throw CredentialError.timedOut
        }

        switch statusBox.value {
        case errSecSuccess:
            guard let data = dataBox.value else { throw CredentialError.unexpectedData }
            return data
        case errSecItemNotFound:
            // Retry without the account constraint (item may be stored under a different account).
            if !account.isEmpty {
                return try KeychainCredentialStore(
                    service: service, account: "",
                    allowInteraction: allowInteraction, timeout: timeout
                ).readRawData()
            }
            throw CredentialError.itemNotFound
        case errSecInteractionNotAllowed, errSecInteractionRequired, errSecAuthFailed:
            throw CredentialError.interactionRequired
        default:
            throw CredentialError.keychain(statusBox.value)
        }
    }
}
