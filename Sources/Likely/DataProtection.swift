import Combine
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
            // Decrypted test screenshots an eval run left behind when it was killed.
            let removed = EvalScreenshots.removeTemporaryCopies()
            if removed > 0 { Log.write("privacy", "removed \(removed) leftover decrypted test screenshot(s)") }
            // Search history: SearchHistoryStore moves and encrypts it on its own queue.
            SearchHistoryStore.shared.convertPlaintext()
            encryptScreenshots()
        }
    }

    /// Plain test screenshots (older versions, or a build without encryption) → `.png.enc`. Also run
    /// again when the Keychain answers after an error.
    static func encryptScreenshots() {
        guard let cipher else { return }
        do {
            let count = try EvalScreenshots.encryptExisting(cipher: cipher)
            if count > 0 { noteKeyResult(nil) }   // 0: the key wasn't needed, so this says nothing about it
            if count > 0 { Log.write("privacy", "encrypted \(count) saved test screenshot(s)") }
        } catch {
            noteKeyResult(error)
            Log.write("privacy", "couldn't encrypt saved test screenshots (left as they are): \(error)")
        }
    }

    /// The Keychain answers again: save the searches waiting in memory and finish the migrations.
    fileprivate static func keychainRecovered() {
        SearchHistoryStore.shared.flushPending()
        SearchHistoryStore.shared.convertPlaintext()
        DispatchQueue.global(qos: .utility).async { encryptScreenshots() }
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
        Log.write("privacy", initial.summary)
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
        Log.write("privacy", new.summary)
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
