import Foundation
import Security

/// The data key as a generic password in the login keychain: readable after the first unlock, this
/// device only, never synced to iCloud Keychain.
///
/// Keychain access follows the app's code signature. Dev builds (Apple Development) and release
/// builds (Developer ID) are different apps to the Keychain, so each uses its own account (and key),
/// and neither can read what the other encrypted. Lookups never show a Keychain prompt: an item this
/// build isn't allowed to read is reported as an error (and no new key is made over it), so the UI can
/// say "can't be read by this build" instead of interrupting a search with a password dialog.
public final class KeychainKeyStore: DataKeyStore {
    public static let service = "inc.synth.likely.data-key"

    public struct KeychainError: Error, CustomStringConvertible {
        public let status: OSStatus
        public var description: String {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "error"
            return "Keychain: \(message) (\(status))"
        }
    }

    let service: String
    let account: String

    public init(service: String = KeychainKeyStore.service, account: String) {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    public func loadKey() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = Self.withoutUserInteraction { SecItemCopyMatching(query as CFDictionary, &result) }
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw KeychainError(status: status)
        }
    }

    private static let interactionLock = NSLock()

    /// Runs a Keychain call with prompts turned off. `kSecUseAuthenticationUIFail` doesn't stop the
    /// login keychain's "<app> wants to use …" access prompt: checked with a temporary keychain and a
    /// second, differently signed binary, the lookup blocked on the prompt. With user interaction off
    /// the same lookup returned errSecAuthFailed (-25293) at once. (The per-process switch is
    /// deprecated, but the file-based login keychain, the only one available to an app without a
    /// provisioning profile, still honors it.) Restored afterwards.
    private static func withoutUserInteraction(_ body: () -> OSStatus) -> OSStatus {
        interactionLock.lock()
        defer { interactionLock.unlock() }
        var previous: DarwinBoolean = true
        SecKeychainGetUserInteractionAllowed(&previous)
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(previous.boolValue) }
        return body()
    }

    public func storeKey(_ key: Data) throws {
        var query = baseQuery
        query[kSecValueData as String] = key
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        query[kSecAttrLabel as String] = "Likely data key"
        query[kSecAttrDescription as String] = "Encrypts Likely's search history and saved test screenshots"
        let status = Self.withoutUserInteraction { SecItemAdd(query as CFDictionary, nil) }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }
}
