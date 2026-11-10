import AppKit
import LikelyEvalKit
import LikelyStorage
import LikelyTools
import SwiftUI

/// The preferences that decide what Likely runs, read and written through `SettingsSeal` (an HMAC per
/// value, keyed from the data key in the data-protection keychain): the agent, its Claude path, the
/// models, the prompt, the tool approvals, and "Allow command-line test runs". A value changed outside
/// Likely (`defaults write`, a `-key value` launch argument, another process), or saved by a build that
/// can't seal (an unprofiled `./build.sh`, a free build, an older version after a downgrade), is
/// ignored, logged and shown in Settings, where the user can look at it and keep it, or use the
/// default. Until then the safe default is used. This covers normal searches and `Likely --eval` alike.
///
/// Builds without a provisioning profile have no data key (EncryptionAvailability), so they read and
/// write these settings plainly, and remove a value's stale seal when they write it; see docs/PRIVACY.md.
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

    /// The keys adoption seals as they are. Not "Allow command-line test runs": it's new with seals, so
    /// an unsealed value was never set in Likely and is never trusted.
    static var adoptableKeys: [String] { keys.filter { !SettingsSeal.neverAdopted.contains($0) } }

    /// Posted (main thread) when a protected setting was kept, reset, or adopted after a retry: views
    /// holding a copy read it again.
    static let didChange = Notification.Name("ProtectedSettings.didChange")

    /// Nil without a data key (a build without a provisioning profile): no seals.
    static let seal: SettingsSeal? = {
        guard let cipher = DataProtection.cipher, let group = DataProtection.status.value.accessGroup else { return nil }
        let marker = KeychainKeyStore(accessGroup: group, account: KeychainKeyStore.settingsAdoptedAccount,
                                      label: "Likely settings seal",
                                      description: "Marks that Likely's settings are protected against changes from outside Likely")
        // Adoption reads only the app's own saved preferences (never launch arguments or the global domain).
        return SettingsSeal(cipher: cipher, adoptedMarker: marker, domain: Bundle.main.bundleIdentifier ?? "inc.synth.likely")
    }()

    static var isProtected: Bool { seal != nil }

    // MARK: Adoption

    /// Only the app adopts (never `Likely --eval`): set at launch.
    private static var adopts = false
    private static let adoptionLock = NSLock()
    private static var lastAttempt: Date?
    /// Between retries a read triggers (the Keychain is asked at most this often).
    static let retryInterval: TimeInterval = 30

    /// At the app's launch (never in `--eval`): seal what older versions saved, once.
    static func adoptAtLaunch() {
        guard seal != nil else { return }
        adopts = true
        _ = adopt(force: true)
        // The Keychain may not answer yet (e.g. before the first unlock): try again when it may.
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.screensDidWakeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in _ = adopt(force: true) }
        }
    }

    /// Settings' "Try Again": adopt if still needed, then check every setting again.
    static func retry() {
        _ = adopt(force: true)
        recheck()
    }

    /// Adopts if that's still to do. Returns true when this call finished it. Throttled unless `force`.
    private static func adopt(force: Bool) -> Bool {
        guard adopts, let seal else { return false }
        adoptionLock.lock()
        defer { adoptionLock.unlock() }
        if (try? seal.adoptionComplete()) == true { return false }
        if !force, let lastAttempt, Date().timeIntervalSince(lastAttempt) < retryInterval { return false }
        lastAttempt = Date()
        do {
            let result = try seal.adoptExisting(adoptableKeys)
            if !result.adopted.isEmpty { Log.write("privacy", "protected \(result.adopted.count) setting(s) saved by an older version") }
            if !result.skipped.isEmpty { Log.write("privacy", "couldn't protect \(result.skipped.count) setting(s) saved by an older version; they're ignored") }
            DispatchQueue.main.async {
                ProtectedSettingsStatus.shared.clearUnverifiable()
                NotificationCenter.default.post(name: didChange, object: nil)
            }
            return true
        } catch {
            Log.write("privacy", "couldn't protect the settings yet: \(error: error)")
            return false
        }
    }

    // MARK: Reading and writing

    static func string(_ key: String) -> String? {
        read(key, sealed: { $0.string(key) }, plain: { UserDefaults.standard.string(forKey: key) }).value
    }

    static func data(_ key: String) -> Data? { dataRead(key).value }

    /// The full read, for a caller that must tell "none saved" from "couldn't verify" (ToolStore).
    static func dataRead(_ key: String) -> SettingsSeal.Read<Data> {
        read(key, sealed: { $0.data(key) }, plain: { UserDefaults.standard.data(forKey: key) })
    }

    static func bool(_ key: String) -> Bool? {
        read(key, sealed: { $0.bool(key) }, plain: { UserDefaults.standard.object(forKey: key) as? Bool }).value
    }

    /// Writes `value` (String, Data or Bool; nil removes it) with its seal. Without a data key, writes it
    /// plainly and removes the key's stale seal (so a protected build reads it as unsealed, not
    /// tampered). Returns false if it couldn't be saved.
    @discardableResult
    static func set(_ value: Any?, forKey key: String) -> Bool {
        guard let seal else {
            SettingsSeal.writeUnsealed(value, forKey: key)
            return true
        }
        do {
            try seal.set(value, forKey: key)
            ProtectedSettingsStatus.shared.resolved(key)
            return true
        } catch {
            Log.write("privacy", "couldn't save \(meta: key): \(error: error)")
            return false
        }
    }

    /// Whether a saved value of `key` is being ignored (couldn't be verified): an editor showing it
    /// mustn't save over it.
    static func isIgnored(_ key: String) -> Bool {
        guard let seal else { return false }
        switch seal.object(key) {
        case .absent, .valid: return false
        default: return true
        }
    }

    private static func read<T>(_ key: String, sealed: (SettingsSeal) -> SettingsSeal.Read<T>, plain: () -> T?) -> SettingsSeal.Read<T> {
        guard let seal else { return plain().map { .valid($0) } ?? .absent }
        var result = sealed(seal)
        // No seal yet because adoption couldn't run: try it now (throttled), then read again.
        if case .unverifiable = result, adopt(force: false) { result = sealed(seal) }
        switch result {
        case .valid, .absent: break
        case .tampered: ProtectedSettingsStatus.shared.report(key, .tampered)
        case .unsealed: ProtectedSettingsStatus.shared.report(key, .unsealed)
        case .unverifiable: ProtectedSettingsStatus.shared.report(key, .unverifiable)
        }
        return result
    }

    /// Reads every key again (after a retry), so Settings shows what's still ignored.
    static func recheck() {
        guard seal != nil else { return }
        for key in keys {
            switch read(key, sealed: { $0.object(key) }, plain: { nil }) {
            case .valid, .absent: ProtectedSettingsStatus.shared.resolved(key)
            default: break
            }
        }
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    // MARK: Keeping an ignored value

    /// The ignored value as stored, for Settings to show before the user keeps it.
    static func storedValue(_ key: String) -> Any? { seal?.storedValue(key) }

    /// The user looked at the ignored value and keeps it: sealed, if it's still what they saw.
    static func keep(_ key: String, expected: Any) -> Bool {
        guard let seal else { return false }
        do {
            guard try seal.keep(key, expected: expected) else { return false }
        } catch {
            Log.write("privacy", "couldn't save \(meta: key): \(error: error)")
            return false
        }
        // `key` is one of the fixed key names, never user text.
        Log.write("privacy", "kept \(meta: key) after the user reviewed it")
        ProtectedSettingsStatus.shared.resolved(key)
        NotificationCenter.default.post(name: didChange, object: nil)
        return true
    }

    /// The user chose the default instead: the ignored value is removed.
    static func useDefault(_ key: String) {
        guard set(nil, forKey: key) else { return }
        ProtectedSettingsStatus.shared.resolved(key)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// How Settings shows a stored value before keeping it, and whether it can be kept at all.
    struct Preview {
        var summary: String
        /// The full text, for long values (the prompt, the approvals).
        var detail: String?
        var keepable: Bool
    }

    static func preview(_ key: String, _ value: Any) -> Preview {
        let unusable = Preview(summary: "A value Likely can't use here.", detail: nil, keepable: false)
        switch key {
        case promptTemplate:
            guard let text = value as? String else { return unusable }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
            let same = text == PromptTemplate.default ? " (the same as the default)" : ""
            let missing = text.contains("FILE:") ? "" : " It has no FILE: line, which Likely relies on."
            return Preview(summary: "A prompt of \(text.count) characters, \(lines) line\(lines == 1 ? "" : "s")\(same).\(missing)",
                           detail: text, keepable: true)
        case agentID:
            guard let id = value as? String else { return unusable }
            guard let kind = AgentKind.with(id: id), kind.isSupported else {
                return Preview(summary: "“\(id.prefix(80))”, which isn't an agent Likely knows.", detail: nil, keepable: false)
            }
            return Preview(summary: kind.name, detail: nil, keepable: true)
        case claudePath:
            guard let path = value as? String else { return unusable }
            let runnable = FileManager.default.isExecutableFile(atPath: path) ? "" : " (not a program Likely can run, so it would be ignored)"
            return Preview(summary: path + runnable, detail: nil, keepable: true)
        case approvedTools:
            guard let data = value as? Data, let approvals = try? JSONDecoder().decode(ToolApproval.Approvals.self, from: data) else { return unusable }
            if approvals.isEmpty { return Preview(summary: "No tools approved.", detail: nil, keepable: true) }
            let detail = approvals.sorted { $0.key < $1.key }
                .map { "\($0.key): " + ($0.value.commands.isEmpty ? "no commands" : $0.value.commands.joined(separator: ", ")) }
                .joined(separator: "\n")
            return Preview(summary: "Approvals for \(approvals.count) tool\(approvals.count == 1 ? "" : "s"), with these commands:",
                           detail: detail, keepable: true)
        case allowCommandLineTests:
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return unusable }
            return Preview(summary: number.boolValue ? "On: your terminal and coding agents can run your tests." : "Off.",
                           detail: nil, keepable: true)
        default:
            guard let model = value as? String, EvalOptions.isValidModel(model) else { return unusable }
            return Preview(summary: model, detail: nil, keepable: true)
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

/// Settings ignored because they couldn't be verified, for Settings.
final class ProtectedSettingsStatus: ObservableObject {
    enum Problem {
        /// Its seal doesn't match: changed outside Likely, or by an older version.
        case tampered
        /// No seal: saved by a build that can't seal, or by another program.
        case unsealed
        /// The Keychain didn't answer (or adoption hasn't run yet).
        case unverifiable
    }

    static let shared = ProtectedSettingsStatus()
    /// In the order they were found.
    @Published private(set) var ignored: [String] = []
    @Published private(set) var problems: [String: Problem] = [:]
    private let lock = NSLock()
    private var logged = Set<String>()

    var unverifiable: [String] { ignored.filter { problems[$0] == .unverifiable } }
    var reviewable: [String] { ignored.filter { problems[$0] != .unverifiable } }

    func report(_ key: String, _ problem: Problem) {
        lock.lock()
        let first = logged.insert(key).inserted
        lock.unlock()
        guard first else { return }
        // `key` is one of ProtectedSettings' fixed key names, never user text.
        switch problem {
        case .unverifiable: Log.write("privacy", "can't check \(meta: key) (Keychain); using the default")
        case .tampered: Log.write("privacy", "ignored \(meta: key): changed outside Likely; using the default")
        case .unsealed: Log.write("privacy", "ignored \(meta: key): saved without a seal; using the default")
        }
        DispatchQueue.main.async {
            if !self.ignored.contains(key) { self.ignored.append(key) }
            self.problems[key] = problem
        }
    }

    func resolved(_ key: String) {
        lock.lock()
        logged.remove(key)
        lock.unlock()
        DispatchQueue.main.async {
            self.ignored.removeAll { $0 == key }
            self.problems[key] = nil
        }
    }

    /// Adoption finished: what couldn't be checked is read again (and reported again if still ignored).
    func clearUnverifiable() {
        for key in unverifiable { resolved(key) }
    }

    func dismiss() {
        ignored = []
        problems = [:]
    }
}

/// Shown at the top of Settings while any protected setting is ignored: what's ignored, why, and for a
/// value that can be shown, "Keep This Value…" (shows it, seals it on confirmation) or "Use Default".
struct ProtectedSettingsWarning: View {
    @ObservedObject private var status = ProtectedSettingsStatus.shared
    @State private var reviewing: ProtectedValueReview.Item?

    var body: some View {
        if !status.ignored.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if !status.unverifiable.isEmpty {
                    row(text: "Likely couldn't check \(Self.list(status.unverifiable)) (the Keychain didn't answer), so it's using the defaults for now. Your saved values are kept.") {
                        Button("Try Again") { ProtectedSettings.retry() }.controlSize(.small)
                    }
                }
                ForEach(status.reviewable, id: \.self) { key in
                    row(text: Self.message(key, status.problems[key] ?? .tampered)) {
                        Button("Keep This Value…") {
                            if let value = ProtectedSettings.storedValue(key) {
                                reviewing = .init(key: key, value: value)
                            } else {
                                ProtectedSettings.recheck()
                            }
                        }
                        .controlSize(.small)
                        Button("Use Default") { ProtectedSettings.useDefault(key) }.controlSize(.small)
                    }
                }
                HStack {
                    Spacer()
                    Button("Hide") { status.dismiss() }.controlSize(.small)
                }
            }
            .padding(8)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            .sheet(item: $reviewing) { item in ProtectedValueReview(item: item) }
        }
    }

    static func message(_ key: String, _ problem: ProtectedSettingsStatus.Problem) -> String {
        let title = ProtectedSettings.title(key)
        let subject = title.prefix(1).uppercased() + title.dropFirst()
        switch problem {
        case .unsealed:
            return "\(subject) was saved by a copy of Likely that can't protect settings (built without a provisioning profile), or by another program, so Likely is using the default."
        default:
            return "\(subject) changed outside this copy of Likely (another program, or an older version of Likely), so Likely is using the default."
        }
    }

    private func row<Buttons: View>(text: String, @ViewBuilder buttons: () -> Buttons) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.shield").foregroundStyle(.orange)
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer()
            buttons()
        }
    }

    static func list(_ keys: [String]) -> String {
        var unique: [String] = []
        for t in keys.map(ProtectedSettings.title) where !unique.contains(t) { unique.append(t) }
        return unique.count <= 1 ? (unique.first ?? "") : unique.dropLast().joined(separator: ", ") + " and " + unique.last!
    }
}

/// Shows an ignored value before the user keeps it.
struct ProtectedValueReview: View {
    struct Item: Identifiable {
        let key: String
        let value: Any
        var id: String { key }
    }

    let item: Item
    @Environment(\.dismiss) private var dismiss
    @State private var changed = false

    var body: some View {
        let preview = ProtectedSettings.preview(item.key, item.value)
        VStack(alignment: .leading, spacing: 10) {
            Text("Keep this value for \(ProtectedSettings.title(item.key))?").font(.headline)
            Text("Likely didn't save this value itself. Keep it only if you recognize it; otherwise use the default.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(preview.summary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if let detail = preview.detail {
                ScrollView {
                    Text(detail).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 220)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            }
            if changed {
                Text("The value changed while you were looking at it. Close this and review it again.")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Use Default") {
                    ProtectedSettings.useDefault(item.key)
                    dismiss()
                }
                Button("Keep This Value") {
                    if ProtectedSettings.keep(item.key, expected: item.value) { dismiss() } else { changed = true }
                }
                .disabled(!preview.keepable || changed)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
