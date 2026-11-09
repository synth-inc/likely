import Foundation
import LikelyEvalKit
import LikelyStorage

/// Likely's data at rest (see docs/PRIVACY.md):
/// - owner-only permissions on everything under ~/Library/Application Support/Likely and
///   ~/Library/Logs/Likely (set at creation by OwnerOnly; `prepareAtLaunch` fixes older files);
/// - the agents' sandboxes can't read either folder (AgentSandbox.protectionRules, CodexRunner);
/// - search history and saved test screenshots are encrypted with a key in the Keychain (`cipher`);
/// - both folders are kept out of Spotlight (SpotlightExclusion).
enum DataProtection {
    /// The data key: one per kind of build, because the Keychain ties an item to the code signature
    /// that made it (Apple Development for dev builds, Developer ID for releases).
    static let keyAccount: String = {
        #if LIKELY_DEV
        return "dev"
        #else
        return "release"
        #endif
    }()

    static let cipher = DataCipher(store: KeychainKeyStore(account: keyAccount))

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
            do {
                let count = try EvalScreenshots.encryptExisting(cipher: cipher)
                if count > 0 { Log.write("privacy", "encrypted \(count) saved test screenshot(s)") }
            } catch {
                Log.write("privacy", "couldn't encrypt saved test screenshots (left as they are): \(error)")
            }
        }
    }
}
