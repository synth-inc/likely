import Combine
import Foundation
import LikelyEvalKit
import LikelyStorage

/// Likely's data at rest (see docs/PRIVACY.md):
/// - owner-only permissions on everything under ~/Library/Application Support/Likely and
///   ~/Library/Logs/Likely (set at creation by OwnerOnly; `prepareAtLaunch` fixes older files);
/// - the agents' sandboxes can't read either folder (AgentSandbox.protectionRules, CodexRunner);
/// - in builds with a provisioning profile, search history is encrypted
///   with a key in the data-protection keychain (`cipher`, see EncryptionAvailability); other builds
///   keep them in plaintext (docs/BUILDING.md);
/// - both folders are kept out of Spotlight (SpotlightExclusion).
enum DataProtection {
    /// This build's encryption, kept current: decided at launch from the entitlements and a read-only
    /// keychain probe, then updated by every use of the key (a Keychain error, and its recovery).
    static let status = EncryptionStatus(EncryptionAvailability.current())

    static var encryption: EncryptionAvailability { status.value }

    /// The data key's cipher whenever this build encrypts, including while the Keychain doesn't answer
    /// (then every seal and open throws, so nothing meant to be encrypted is written in plaintext).
    /// Nil only in a build without a provisioning profile, which keeps data in plaintext.
    /// One key for every build of the same team: the access group, not the code signature, decides
    /// who can read it, so dev and release builds signed by that team share it.
    static let cipher: DataCipher? = status.value.accessGroup.map { DataCipher(store: KeychainKeyStore(accessGroup: $0)) }

    /// docs/BUILDING.md: how to build with encryption on.
    static let buildingGuideURL = URL(string: "https://github.com/synth-inc/likely/blob/main/docs/BUILDING.md")!

    /// After using the key: a Keychain failure puts encryption in its error state (and starts the
    /// retries); a success after one ends it.
    static func noteKeyResult(_ error: Error?) {
        guard let group = status.value.accessGroup else { return }
        if let error {
            guard case .keyUnavailable(let why)? = error as? DataCipher.CipherError else { return }
            status.set(.keychainError(accessGroup: group, why))
        } else {
            status.set(.on(accessGroup: group))
        }
    }

    /// Runs before anything else touches the folders (main.swift): quick, synchronous. Encrypting what
    /// older versions left in plaintext happens in the background (`migrateInBackground`).
    /// The log file waits until both folders are in place: a log line written in between would create
    /// ~/Library/Logs/Likely as a real folder and split the log.
    static func prepareAtLaunch() {
        Log.holdFileWrites()
        defer { Log.startFileWrites() }
        for folder in LikelyDataPaths.all() {
            do {
                let outcome = try SpotlightExclusion.exclude(folder)
                if outcome != .alreadyExcluded { Log.write("privacy", "Spotlight exclusion for \(path: folder): \(outcome)") }
            } catch {
                Log.write("privacy", "couldn't keep \(path: folder) out of Spotlight: \(error: error)")
            }
            let changed = OwnerOnly.repair(folder)
            if changed > 0 { Log.write("privacy", "made \(changed) item(s) in \(path: folder) owner-only") }
        }
    }

    static func migrateInBackground() {
        DispatchQueue.global(qos: .utility).async {
            removeLegacyScreenshots()
            // Search history: SearchHistoryStore moves and encrypts it on its own queue.
            SearchHistoryStore.shared.convertPlaintext()
        }
    }

    static let legacyScreenshotsCleanedKey = "legacyScreenshotsCleaned"

    /// Likely no longer takes screenshots: delete any an older version left, at each launch until a
    /// pass finds nothing.
    private static func removeLegacyScreenshots() {
        guard !UserDefaults.standard.bool(forKey: legacyScreenshotsCleanedKey) else { return }
        guard let removed = LegacyScreenshots.removeAll() else {
            Log.write("privacy", "data folder is redirected elsewhere; left old screenshots alone")
            return
        }
        if removed > 0 {
            Log.write("privacy", "removed \(removed) screenshot(s) left by an older version")
        } else {
            UserDefaults.standard.set(true, forKey: legacyScreenshotsCleanedKey)
        }
    }

    /// The Keychain answers again: save the searches waiting in memory and finish the migrations.
    fileprivate static func keychainRecovered() {
        SearchHistoryStore.shared.flushPending()
        SearchHistoryStore.shared.convertPlaintext()
    }
}

/// The current EncryptionAvailability, readable from any thread (`value`) and published on the main
/// thread for Settings (`state`). In the Keychain error state it probes the Keychain again every
/// `retryInterval` (read-only, never any UI) until it answers.
final class EncryptionStatus: ObservableObject {
    static let retryInterval: TimeInterval = 60

    @Published private(set) var state: EncryptionAvailability
    private let lock = NSLock()
    private var current: EncryptionAvailability
    private var retryScheduled = false

    init(_ initial: EncryptionAvailability) {
        state = initial
        current = initial
        Log.write("privacy", "\(meta: initial.summary)")
        if case .keychainError = initial { scheduleRetry() }
    }

    var value: EncryptionAvailability {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func set(_ new: EncryptionAvailability) {
        lock.lock()
        let old = current
        current = new
        lock.unlock()
        guard new != old else { return }
        Log.write("privacy", "\(meta: new.summary)")
        DispatchQueue.main.async { self.state = new }
        if case .keychainError = new { scheduleRetry() }
        if case .keychainError = old, new.isOn { DataProtection.keychainRecovered() }
    }

    private func scheduleRetry() {
        lock.lock()
        defer { lock.unlock() }
        guard !retryScheduled else { return }
        retryScheduled = true
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.retryInterval) { [weak self] in
            self?.retry()
        }
    }

    private func retry() {
        lock.lock()
        retryScheduled = false
        let state = current
        lock.unlock()
        guard case .keychainError(let group, _) = state else { return }
        let next = EncryptionAvailability.evaluate(accessGroup: group) { KeychainKeyStore(accessGroup: $0).probe() }
        set(next)
        if case .keychainError = next { scheduleRetry() }
    }
}
