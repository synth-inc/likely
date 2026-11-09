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
/// builds from source don't unless the builder sets one up (docs/BUILDING.md). Without it (and only
/// then), data is kept in plaintext with Likely's other protections (owner-only files, the agent
/// sandbox deny, Spotlight exclusion). There is deliberately no fallback (a key file next to the
/// data, or the login keychain's access prompts).
///
/// A build that has the entitlement but whose Keychain doesn't answer (`keychainError`) is not "off":
/// it still encrypts, so nothing meant to be encrypted is ever written in plaintext. History waits in
/// memory, test screenshots aren't saved, and the Keychain is tried again (DataProtection).
public enum EncryptionAvailability: Equatable {
    case on(accessGroup: String)
    /// The entitlement is there but the data-protection keychain didn't answer (with why).
    case keychainError(accessGroup: String, String)
    case off(Reason)

    public enum Reason: Equatable {
        /// No `keychain-access-groups` entitlement: the app was built without a provisioning profile.
        case noProvisioningProfile
    }

    public var isOn: Bool { if case .on = self { return true } else { return false } }

    /// Whether this build encrypts (on, or on but waiting for the Keychain). Only a build without a
    /// provisioning profile keeps its data in plaintext.
    public var encrypts: Bool { accessGroup != nil }

    /// The data key's access group, for a build that encrypts.
    public var accessGroup: String? {
        switch self {
        case .on(let group), .keychainError(let group, _): return group
        case .off: return nil
        }
    }

    /// Decides from the entitlements and a read-only keychain probe for that access group. The probe
    /// only runs when there is an access group (tests pass their own and never reach a keychain).
    public static func evaluate(_ entitlements: SigningEntitlements,
                                probe: (String) -> Result<Void, KeychainKeyStore.KeychainError>) -> EncryptionAvailability {
        guard let group = entitlements.dataKeyAccessGroup else { return .off(.noProvisioningProfile) }
        return evaluate(accessGroup: group, probe: probe)
    }

    /// The probe alone, for an access group already known (retrying after a Keychain error).
    public static func evaluate(accessGroup group: String,
                                probe: (String) -> Result<Void, KeychainKeyStore.KeychainError>) -> EncryptionAvailability {
        switch probe(group) {
        case .success: return .on(accessGroup: group)
        case .failure(let error): return .keychainError(accessGroup: group, error.description)
        }
    }

    /// This process: its entitlements and the data-protection keychain.
    public static func current() -> EncryptionAvailability {
        evaluate(SigningEntitlements.current()) { KeychainKeyStore(accessGroup: $0).probe() }
    }

    /// For Settings: "Encryption: on", or why it's off or not working.
    public var summary: String {
        switch self {
        case .on: return "Encryption: on"
        case .off(.noProvisioningProfile): return "Encryption: off in this build (no provisioning profile)"
        case .keychainError(_, let why):
            return "Encryption: on, but the Keychain isn't answering (\(why)). Nothing is saved unencrypted; Likely keeps trying"
        }
    }
}
