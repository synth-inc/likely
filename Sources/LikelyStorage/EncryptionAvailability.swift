import Foundation
import Security

/// The code-signing entitlements that decide whether this build can encrypt (see
/// `EncryptionAvailability`). Read from the running process's signature, so a build signed with
/// another team's provisioning profile uses that team's access group: nothing is hard-coded.
public struct SigningEntitlements: Equatable {
    /// `com.apple.application-identifier`: "<team id>.<bundle id>".
    public var applicationIdentifier: String?
    /// `com.apple.developer.team-identifier`.
    public var teamIdentifier: String?
    /// `keychain-access-groups`. Only present when a provisioning profile allows it.
    public var keychainAccessGroups: [String]

    public init(applicationIdentifier: String? = nil, teamIdentifier: String? = nil, keychainAccessGroups: [String] = []) {
        self.applicationIdentifier = applicationIdentifier
        self.teamIdentifier = teamIdentifier
        self.keychainAccessGroups = keychainAccessGroups
    }

    public static let applicationIdentifierKey = "com.apple.application-identifier"
    public static let teamIdentifierKey = "com.apple.developer.team-identifier"
    public static let keychainAccessGroupsKey = "keychain-access-groups"
    /// The access group's name after the team id: "<team id>.inc.synth.likely" (Likely.entitlements).
    public static let accessGroupSuffix = "inc.synth.likely"

    /// This process's entitlements (SecTask: reads the kernel's copy of the signature, no UI).
    public static func current() -> SigningEntitlements {
        guard let task = SecTaskCreateFromSelf(kCFAllocatorDefault) else { return SigningEntitlements() }
        func value(_ key: String) -> Any? { SecTaskCopyValueForEntitlement(task, key as CFString, nil) }
        return SigningEntitlements(applicationIdentifier: value(applicationIdentifierKey) as? String,
                                   teamIdentifier: value(teamIdentifierKey) as? String,
                                   keychainAccessGroups: value(keychainAccessGroupsKey) as? [String] ?? [])
    }

    /// The team: the team-identifier entitlement, else the application identifier's prefix.
    public var team: String? {
        if let teamIdentifier, !teamIdentifier.isEmpty { return teamIdentifier }
        guard let prefix = applicationIdentifier?.split(separator: ".").first, !prefix.isEmpty else { return nil }
        return String(prefix)
    }

    /// The access group for the data key: "<team>.inc.synth.likely" when the entitlement lists it,
    /// else the first concrete (no wildcard) group of this team. Nil without one.
    public var dataKeyAccessGroup: String? {
        let concrete = keychainAccessGroups.filter { !$0.contains("*") && !$0.isEmpty }
        if let team {
            let preferred = "\(team).\(Self.accessGroupSuffix)"
            if concrete.contains(preferred) { return preferred }
            if let own = concrete.first(where: { $0.hasPrefix(team + ".") }) { return own }
        }
        return concrete.first
    }
}

/// Whether this build encrypts Likely's private data, and why not if it doesn't.
///
/// Encryption needs the data-protection keychain, which needs a `keychain-access-groups`
/// entitlement, which needs a provisioning profile embedded in the app. Official releases have one;
/// builds from source don't unless the builder sets one up (docs/BUILDING.md). Without it, data is
/// kept in plaintext with Likely's other protections (owner-only files, the agent sandbox deny,
/// Spotlight exclusion). There is deliberately no fallback (a key file next to the data, or the
/// login keychain's access prompts).
public enum EncryptionAvailability: Equatable {
    case on(accessGroup: String)
    case off(Reason)

    public enum Reason: Equatable {
        /// No `keychain-access-groups` entitlement: the app was built without a provisioning profile.
        case noProvisioningProfile
        /// The entitlement is there but the data-protection keychain didn't answer (with why).
        case keychainUnavailable(String)
    }

    public var isOn: Bool { if case .on = self { return true } else { return false } }

    public var accessGroup: String? { if case .on(let group) = self { return group } else { return nil } }

    /// Decides from the entitlements and a read-only keychain probe for that access group. The probe
    /// only runs when there is an access group (tests pass their own and never reach a keychain).
    public static func evaluate(_ entitlements: SigningEntitlements,
                                probe: (String) -> Result<Void, KeychainKeyStore.KeychainError>) -> EncryptionAvailability {
        guard let group = entitlements.dataKeyAccessGroup else { return .off(.noProvisioningProfile) }
        switch probe(group) {
        case .success: return .on(accessGroup: group)
        case .failure(let error): return .off(.keychainUnavailable(error.description))
        }
    }

    /// This process: its entitlements and the data-protection keychain.
    public static func current() -> EncryptionAvailability {
        evaluate(SigningEntitlements.current()) { KeychainKeyStore(accessGroup: $0).probe() }
    }

    /// For Settings: "Encryption: on", or why it's off.
    public var summary: String {
        switch self {
        case .on: return "Encryption: on"
        case .off(.noProvisioningProfile): return "Encryption: off in this build (no provisioning profile)"
        case .off(.keychainUnavailable(let why)): return "Encryption: off (the Keychain isn't available to this build: \(why))"
        }
    }
}
