import Foundation
import LikelyEvalKit
import LikelyStorage

/// Likely's data at rest (see docs/PRIVACY.md):
/// - owner-only permissions on everything under ~/Library/Application Support/Likely and
///   ~/Library/Logs/Likely (set at creation by OwnerOnly; `prepareAtLaunch` fixes older files);
/// - the agents' sandboxes can't read either folder (AgentSandbox.protectionRules, CodexRunner);
/// - in builds with a provisioning profile, search history and saved test screenshots are encrypted
///   with a key in the data-protection keychain (`cipher`, see EncryptionAvailability); other builds
///   keep them in plaintext (docs/BUILDING.md);
/// - both folders are kept out of Spotlight (SpotlightExclusion).
enum DataProtection {
    /// Decided once per launch, from this build's entitlements and a read-only keychain probe.
    static let encryption: EncryptionAvailability = {
        let state = EncryptionAvailability.current()
        Log.write("privacy", state.summary)
        return state
    }()

    /// The data key's cipher, or nil when this build has no encryption (data is kept in plaintext).
    /// One key for every build of the same team: the access group, not the code signature, decides
    /// who can read it, so dev and release builds signed by that team share it.
    static let cipher: DataCipher? = encryption.accessGroup.map { DataCipher(store: KeychainKeyStore(accessGroup: $0)) }

    /// docs/BUILDING.md: how to build with encryption on.
    static let buildingGuideURL = URL(string: "https://github.com/synth-inc/likely/blob/main/docs/BUILDING.md")!

    /// Runs before anything else touches the folders (main.swift): quick, synchronous. Encrypting what
    /// older versions left in plaintext happens in the background (`migrateInBackground`).
    static func prepareAtLaunch() {
        for folder in LikelyDataPaths.all() {
            do {
                let outcome = try SpotlightExclusion.exclude(folder)
                if outcome != .alreadyExcluded { Log.write("privacy", "Spotlight exclusion for \(folder.path): \(outcome)") }
            } catch {
                Log.write("privacy", "couldn't keep \(folder.path) out of Spotlight: \(error)")
            }
            let changed = OwnerOnly.repair(folder)
            if changed > 0 { Log.write("privacy", "made \(changed) item(s) in \(folder.path) owner-only") }
        }
        #if !LIKELY_DEV
        // Release builds keep debug screenshots in memory only.
        DebugStore.removeSavedScreenshots()
        #endif
    }

    static func migrateInBackground() {
        DispatchQueue.global(qos: .utility).async {
            // Search history: SearchHistoryStore moves and encrypts it on its own queue.
            _ = SearchHistoryStore.shared
            guard let cipher else { return }
            do {
                let count = try EvalScreenshots.encryptExisting(cipher: cipher)
                if count > 0 { Log.write("privacy", "encrypted \(count) saved test screenshot(s)") }
            } catch {
                Log.write("privacy", "couldn't encrypt saved test screenshots (left as they are): \(error)")
            }
        }
    }
}
