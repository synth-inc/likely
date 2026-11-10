import Foundation
import LikelyEvalKit
import LikelyStorage
import SwiftUI

/// The preferences that decide what Likely runs, read and written through `SettingsSeal` (an HMAC per
/// value, keyed from the data key in the data-protection keychain): the agent, its Claude path, the
/// models, the prompt, the tool approvals, and "Allow command-line test runs". A value changed outside
/// Likely (`defaults write`, a `-key value` launch argument, another process) is ignored, logged and
/// shown in Settings, and the safe default is used instead. This covers normal searches and
/// `Likely --eval` alike.
///
/// Builds without a provisioning profile have no data key (EncryptionAvailability), so they read and
/// write these settings plainly, as before; see docs/PRIVACY.md.
enum ProtectedSettings {
    static let agentID = "agentID"
    static let claudePath = "claudePath"
    static let promptTemplate = "promptTemplate"
    static let approvedTools = "approvedTools"
    static let allowCommandLineTests = "allowCommandLineTests"

    /// Every sealed key (the models' keys come from AgentModels).
    static var keys: [String] {
        [agentID, claudePath, promptTemplate, approvedTools, allowCommandLineTests]
            + EvalOptions.agentIDs.map(AgentModels.key(for:))
    }

    /// Nil without a data key (a build without a provisioning profile): no seals.
    static let seal: SettingsSeal? = {
        guard let cipher = DataProtection.cipher, let group = DataProtection.status.value.accessGroup else { return nil }
        let marker = KeychainKeyStore(accessGroup: group, account: KeychainKeyStore.settingsAdoptedAccount,
                                      label: "Likely settings seal",
                                      description: "Marks that Likely's settings are protected against changes from outside Likely")
        return SettingsSeal(cipher: cipher, adoptedMarker: marker)
    }()

    static var isProtected: Bool { seal != nil }

    /// At the app's launch (never in `--eval`): seal what older versions saved, once.
    static func adoptAtLaunch() {
        guard let seal else { return }
        do {
            let adopted = try seal.adoptExisting(keys)
            if !adopted.isEmpty { Log.write("privacy", "protected \(adopted.count) setting(s) saved by an older version") }
        } catch {
            Log.write("privacy", "couldn't protect the settings yet: \(error: error)")
        }
    }

    static func string(_ key: String) -> String? {
        guard let seal else { return UserDefaults.standard.string(forKey: key) }
        return checked(key, seal.string(key))
    }

    static func data(_ key: String) -> Data? {
        guard let seal else { return UserDefaults.standard.data(forKey: key) }
        return checked(key, seal.data(key))
    }

    static func bool(_ key: String) -> Bool? {
        guard let seal else { return UserDefaults.standard.object(forKey: key) as? Bool }
        return checked(key, seal.bool(key))
    }

    /// Writes `value` (String, Data or Bool; nil removes it) with its seal.
    static func set(_ value: Any?, forKey key: String) {
        guard let seal else {
            if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            return
        }
        do {
            try seal.set(value, forKey: key)
            ProtectedSettingsStatus.shared.resolved(key)
        } catch {
            Log.write("privacy", "couldn't save \(meta: key): \(error: error)")
        }
    }

    private static func checked<T>(_ key: String, _ read: SettingsSeal.Read<T>) -> T? {
        switch read {
        case .valid(let v): return v
        case .absent: return nil
        case .tampered:
            ProtectedSettingsStatus.shared.report(key, unverifiable: false)
            return nil
        case .unverifiable:
            ProtectedSettingsStatus.shared.report(key, unverifiable: true)
            return nil
        }
    }

    /// For the warning in Settings.
    static func title(_ key: String) -> String {
        switch key {
        case agentID: return "the agent"
        case claudePath: return "Claude Code's location"
        case promptTemplate: return "the prompt"
        case approvedTools: return "the tool approvals"
        case allowCommandLineTests: return "“Allow command-line test runs”"
        default: return "a model choice"
        }
    }
}

/// Settings ignored because they changed outside Likely (or couldn't be checked), for Settings.
final class ProtectedSettingsStatus: ObservableObject {
    static let shared = ProtectedSettingsStatus()
    @Published private(set) var ignored: [String] = []
    @Published private(set) var unverifiable = false
    private let lock = NSLock()
    private var logged = Set<String>()

    func report(_ key: String, unverifiable: Bool) {
        lock.lock()
        let first = logged.insert(key).inserted
        lock.unlock()
        guard first else { return }
        // `key` is one of ProtectedSettings' fixed key names, never user text.
        if unverifiable {
            Log.write("privacy", "can't check \(meta: key) (Keychain); using the default")
        } else {
            Log.write("privacy", "ignored \(meta: key): changed outside Likely; using the default")
        }
        DispatchQueue.main.async {
            if !self.ignored.contains(key) { self.ignored.append(key) }
            if unverifiable { self.unverifiable = true }
        }
    }

    func resolved(_ key: String) {
        lock.lock()
        logged.remove(key)
        lock.unlock()
        DispatchQueue.main.async { self.ignored.removeAll { $0 == key } }
    }

    func dismiss() {
        ignored = []
        unverifiable = false
    }
}

/// Shown at the top of Settings while any protected setting was ignored.
struct ProtectedSettingsWarning: View {
    @ObservedObject private var status = ProtectedSettingsStatus.shared

    var body: some View {
        if !status.ignored.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.shield").foregroundStyle(.orange)
                Text(status.unverifiable
                     ? "Likely couldn't check \(list) (the Keychain didn't answer), so it's using the defaults for now."
                     : "\(list.prefix(1).uppercased() + list.dropFirst()) changed outside Likely, so Likely ignored the change and uses the default. Choose again here to keep a setting.")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("OK") { status.dismiss() }.controlSize(.small)
            }
            .padding(8)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var list: String {
        let titles = status.ignored.map(ProtectedSettings.title)
        var unique: [String] = []
        for t in titles where !unique.contains(t) { unique.append(t) }
        return unique.count <= 1 ? (unique.first ?? "") : unique.dropLast().joined(separator: ", ") + " and " + unique.last!
    }
}
