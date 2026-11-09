import Foundation
import LocalAuthentication
import Security

/// The data key as a generic password in the data-protection keychain (the iOS-style keychain on
/// macOS), in Likely's own access group: readable after the first unlock, this device only, never
/// synced to iCloud Keychain.
///
/// Only apps signed by the same team with that access group in their `keychain-access-groups`
/// entitlement can see the item, and no other app can be granted access to it by the user. The
/// entitlement needs a provisioning profile, so builds without one can't use this store at all;
/// `EncryptionAvailability` turns encryption off for them (see docs/BUILDING.md).
///
/// Lookups never show UI: the data-protection keychain has no per-app access prompts, and every query
/// carries an authentication context with `interactionNotAllowed` (the replacement for the deprecated
/// `kSecUseAuthenticationUIFail`), so anything that would need one fails instead. A key this build
/// can't read is reported as an error, and no new key is made over it.
public final class KeychainKeyStore: DataKeyStore {
    public static let service = "inc.synth.likely.data-key"
    public static let defaultAccount = "data-key"

    public struct KeychainError: Error, CustomStringConvertible {
        public let status: OSStatus
        public init(status: OSStatus) { self.status = status }
        public var description: String {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "error"
            return "Keychain: \(message) (\(status))"
        }
    }

    public let accessGroup: String
    let service: String
    let account: String

    public init(accessGroup: String, service: String = KeychainKeyStore.service, account: String = KeychainKeyStore.defaultAccount) {
        self.accessGroup = accessGroup
        self.service = service
        self.account = account
    }

    /// A context that never shows authentication UI.
    static func noInteractionContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }

    /// The attributes every query and the stored item share.
    var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecUseDataProtectionKeychain as String: true,
         kSecAttrAccessGroup as String: accessGroup,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false,
         kSecUseAuthenticationContext as String: Self.noInteractionContext()]
    }

    var loadQuery: [String: Any] {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return query
    }

    func addQuery(_ key: Data) -> [String: Any] {
        var query = baseQuery
        query[kSecValueData as String] = key
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        query[kSecAttrLabel as String] = "Likely data key"
        query[kSecAttrDescription as String] = "Encrypts Likely's search history and saved test screenshots"
        return query
    }

    public func loadKey() throws -> Data? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(loadQuery as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw KeychainError(status: status)
        }
    }

    public func storeKey(_ key: Data) throws {
        let status = SecItemAdd(addQuery(key) as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    /// Whether the data-protection keychain works for this build and access group: a lookup that
    /// either finds the key or finds nothing. Reads only; never makes an item or shows UI.
    public func probe() -> Result<Void, KeychainError> {
        var query = baseQuery
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return status == errSecSuccess || status == errSecItemNotFound ? .success(()) : .failure(KeychainError(status: status))
    }
}
