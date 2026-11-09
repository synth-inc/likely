import AppKit
import LikelyEvalKit
import SwiftUI

/// Every search Likely ran (History/history.jsonl next to the evals folder, last 500), so any of them
/// can be made into an eval case later. On this Mac only; never sent anywhere, and the agents' sandboxes
/// can't read it (AgentSandbox.historyRules, CodexRunner). "Save search history" in Settings → History,
/// on by default, independent of "Automatically save picks as tests".
///
/// All file access goes through one serial background queue, so recording a search never blocks the
/// main thread when a picker closes and writes can't interleave. The list is only read and decoded
/// while the History tab is on screen.
final class SearchHistoryStore: ObservableObject {
    static let shared = SearchHistoryStore()
    static let defaultsKey = "saveSearchHistory"
    static let defaultValue = true
    /// Set once the first search is recorded; drives the one-time notices.
    static let firstRecordedKey = "searchHistoryFirstRecorded"
    static let settingsNoticeDismissedKey = "searchHistorySettingsNoticeDismissed"
    static let hudNoticeShownKey = "searchHistoryHUDNoticeShown"
    static let notice = "Likely keeps a private history of your searches on this Mac so you can turn them into tests. Turn it off in Settings → History."

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? defaultValue }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    let url = SearchHistoryFile.defaultURL
    private let queue = DispatchQueue(label: "inc.synth.likely.history", qos: .utility)
    /// Newest first. Only kept current while the History tab is visible.
    @Published private(set) var entries: [SearchHistoryEntry] = []
    /// Whether history.jsonl exists, even if none of its lines decode (Clear and Show File use this).
    @Published private(set) var fileExists = false
    @Published var lastError: String?
    /// History tabs on screen (Settings may be closed and reopened).
    private var visibleCount = 0

    private init() {
        queue.async { [url] in
            do {
                try SearchHistoryFile.migrate(from: SearchHistoryFile.legacyURL, to: url)
            } catch {
                Log.write("history", "couldn't move history.jsonl into History/: \(error)")
            }
        }
    }

    // MARK: Visibility

    func tabAppeared() {
        visibleCount += 1
        reload()
    }

    func tabDisappeared() {
        visibleCount = max(0, visibleCount - 1)
        if visibleCount == 0 { entries = [] }   // nothing decoded is kept around off screen
    }

    /// Reads the file in the background and publishes it, if the tab is still visible.
    func reload() {
        queue.async { [url] in
            let exists = FileManager.default.fileExists(atPath: url.path)
            let result = Result { try SearchHistoryFile.load(url) }
            DispatchQueue.main.async {
                guard self.visibleCount > 0 else { return }
                self.fileExists = exists
                switch result {
                case .success(let list):
                    self.entries = list.reversed()
                    if self.lastError?.hasPrefix("Couldn't read") == true { self.lastError = nil }
                case .failure(let error):
                    self.entries = []
                    self.lastError = "Couldn't read the history file: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: Writes

    /// Appends one search in the background, if history is on. If the existing file can't be read,
    /// nothing is written (SearchHistoryFile.append throws first), so a bad read never wipes it.
    func record(_ entry: SearchHistoryEntry) {
        guard Self.isEnabled else { return }
        queue.async { [url] in
            do {
                try SearchHistoryFile.append(entry, to: url)
                Log.write("history", "saved search (\(entry.suggested.count) suggested, \(entry.picked.isEmpty ? "no pick" : "picked"))")
                DispatchQueue.main.async {
                    let defaults = UserDefaults.standard
                    if defaults.object(forKey: Self.firstRecordedKey) == nil { defaults.set(Date().timeIntervalSince1970, forKey: Self.firstRecordedKey) }
                    if self.visibleCount > 0 { self.reload() }
                }
            } catch {
                Log.write("history", "couldn't save search, history left as is: \(error)")
                DispatchQueue.main.async { self.lastError = "Couldn't save the last search: \(error.localizedDescription)" }
            }
        }
    }

    /// True once (the first picker after history first recorded something): the HUD shows `notice`.
    func takeHUDNotice() -> Bool {
        let defaults = UserDefaults.standard
        guard Self.isEnabled, defaults.object(forKey: Self.firstRecordedKey) != nil,
              !defaults.bool(forKey: Self.hudNoticeShownKey) else { return false }
        defaults.set(true, forKey: Self.hudNoticeShownKey)
        return true
    }

    func clear() {
        let result = queue.sync { [url] in Result { try SearchHistoryFile.clear(url) } }
        switch result {
        case .success:
            lastError = nil
            entries = []
            fileExists = false
        case .failure(let error):
            lastError = "Couldn't clear history: \(error.localizedDescription)"
        }
    }

    /// Marks the entry as made into `caseID`. Returns an error message if it couldn't be (including
    /// when the entry is no longer in the file, e.g. it aged out or history was cleared meanwhile).
    func markEval(entryID: String, caseID: String) -> String? {
        let result = queue.sync { [url] in Result { try SearchHistoryFile.update(id: entryID, in: url) { $0.evalCaseID = caseID } } }
        let message: String?
        switch result {
        case .success(let updated?):
            message = nil
            if let i = entries.firstIndex(where: { $0.id == entryID }) { entries[i] = updated }
        case .success(nil):
            message = "Saved the test “\(caseID)”, but this search is no longer in the history file, so it isn't marked “test saved”."
        case .failure(let error):
            message = "Saved the test “\(caseID)”, but couldn't mark the search: \(error.localizedDescription)"
        }
        lastError = message
        reload()
        return message
    }
}

// MARK: - Settings tab

struct HistorySettings: View {
    @ObservedObject private var store = SearchHistoryStore.shared
    @AppStorage(SearchHistoryStore.defaultsKey) private var enabled = SearchHistoryStore.defaultValue
    @State private var search = ""
    @State private var making: SearchHistoryEntry?
    @State private var confirmingClear = false
    @State private var askingDeleteOnOff = false
    @AppStorage(SearchHistoryStore.firstRecordedKey) private var firstRecorded: Double = 0
    @AppStorage(SearchHistoryStore.settingsNoticeDismissedKey) private var noticeDismissed = false

    /// Turning history off asks whether to delete what's already saved.
    private var enabledBinding: Binding<Bool> {
        Binding(get: { enabled }, set: { on in
            enabled = on
            if !on && store.fileExists { askingDeleteOnOff = true }
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Save search history", isOn: enabledBinding)
                Text("Keeps your last \(SearchHistoryFile.defaultLimit) searches (what you typed, the app, what Likely suggested and what you picked) on this Mac only, so you can turn any of them into a test. Nothing is uploaded.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if enabled && firstRecorded != 0 && !noticeDismissed {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    Text(SearchHistoryStore.notice).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("OK") { noticeDismissed = true }.controlSize(.small)
                }
            }
            HStack {
                Text("\(store.entries.count) search\(store.entries.count == 1 ? "" : "es")").foregroundStyle(.secondary)
                Spacer()
                TextField("Search", text: $search).textFieldStyle(.roundedBorder).frame(width: 200)
            }
            list
                .overlay {
                    if visible.isEmpty {
                        Text(store.entries.isEmpty
                             ? (enabled ? "No searches yet. Searches show up here once a picker closes." : "Search history is off.")
                             : "No searches match.")
                            .multilineTextAlignment(.center).foregroundStyle(.secondary).padding(30)
                    }
                }
            if let error = store.lastError { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack {
                Button("Clear History…") { confirmingClear = true }.disabled(!store.fileExists)
                Spacer()
                Button("Show File") { NSWorkspace.shared.activateFileViewerSelecting([store.url]) }
                    .disabled(!store.fileExists)
            }
        }
        .onAppear { store.tabAppeared() }
        .onDisappear { store.tabDisappeared() }
        .sheet(item: $making) { entry in
            MakeEvalSheet(entry: entry) { making = nil }
        }
        .confirmationDialog("Clear search history?", isPresented: $confirmingClear) {
            Button("Clear History", role: .destructive) { store.clear() }
        } message: {
            Text("This deletes all saved searches. Tests you made from them are kept. Likely's log (~/Library/Logs/Likely/likely.log) may still mention past searches; delete it too if you want them gone.")
        }
        .confirmationDialog("Delete the searches already saved?", isPresented: $askingDeleteOnOff) {
            Button("Delete History", role: .destructive) { store.clear() }
            Button("Keep History", role: .cancel) {}
        } message: {
            Text("New searches won't be saved. The ones already saved stay until you delete them. Likely's log (~/Library/Logs/Likely/likely.log) may still mention past searches.")
        }
    }

    private var visible: [SearchHistoryEntry] {
        guard !search.isEmpty else { return store.entries }
        return store.entries.filter { e in
            e.app.localizedCaseInsensitiveContains(search)
                || e.queries.contains { $0.localizedCaseInsensitiveContains(search) }
                || (e.picked + e.suggested).contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }

    private var list: some View {
        List(visible) { e in
            HStack(alignment: .center, spacing: 10) {
                pickIndicator(e)
                VStack(alignment: .leading, spacing: 3) {
                    if e.queries.isEmpty {
                        Text("No query (from the screenshot)").italic().foregroundStyle(.secondary).lineLimit(1)
                    } else {
                        Text(e.queries.map { "“\($0)”" }.joined(separator: " → ")).fontWeight(.medium).lineLimit(1)
                    }
                    HStack(spacing: 4) {
                        Text(e.app.isEmpty ? "Unknown app" : e.app)
                        if let date = e.timestamp { Text("· \(date, format: .relative(presentation: .named))") }
                        Text("· \(e.suggested.count) suggested")
                        if e.hasEval {
                            Text("test saved").font(.caption2.bold()).foregroundStyle(.green)
                                .help("Made into the test “\(e.evalCaseID ?? "")”")
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Make Eval") { making = e }
                    .help(e.hasEval ? "Make another test from this search" : "Make a test from this search")
            }
            .padding(.vertical, 2)
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }

    private func pickIndicator(_ e: SearchHistoryEntry) -> some View {
        Group {
            if e.wasPicked {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    .help("Picked: " + e.picked.map(EvalPath.display).joined(separator: ", "))
            } else {
                Image(systemName: "circle.dashed").foregroundStyle(.tertiary)
                    .help(e.outcome.map { "Not picked (\($0))" } ?? "Not picked")
            }
        }
        .frame(width: 16)
    }
}

// MARK: - Make Eval

/// Turns one history entry into a test: the query (editable), the files to count as correct (the pick
/// pre-checked, Likely's suggestions, anything added), and any-of / all-of.
struct MakeEvalSheet: View {
    let entry: SearchHistoryEntry
    let dismiss: () -> Void
    @State private var queries: String
    @State private var kind = Expectation.Kind.anyOf
    @State private var checked: [String]
    @State private var added: [String] = []
    @State private var error: String?

    init(entry: SearchHistoryEntry, dismiss: @escaping () -> Void) {
        self.entry = entry
        self.dismiss = dismiss
        _queries = State(initialValue: entry.queries.joined(separator: "\n"))
        _checked = State(initialValue: entry.picked)
        _kind = State(initialValue: entry.picked.count > 1 ? .allOf : .anyOf)
    }

    private var queryList: [String] {
        queries.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private var candidates: [String] {
        var list = entry.candidates
        for p in added where !list.contains(where: { EvalPath.same($0, p) }) { list.append(p) }
        return list
    }

    /// In candidate order.
    private var expected: [String] { candidates.filter { c in checked.contains { EvalPath.same($0, c) } } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Make Eval").font(.title3.bold())
            Form {
                LabeledContent("Query") {
                    VStack(alignment: .leading, spacing: 2) {
                        TextEditor(text: $queries)
                            .font(.body)
                            .frame(height: 54)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
                        Text("One message per line; later lines are follow-ups (“not these, …”).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                LabeledContent("App") {
                    Text([entry.app, entry.timestamp.map { $0.formatted(date: .abbreviated, time: .shortened) }]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                }
                Picker("Correct if Likely suggests", selection: $kind) {
                    Text("Any of the checked files").tag(Expectation.Kind.anyOf)
                    Text("All of the checked files").tag(Expectation.Kind.allOf)
                }
                LabeledContent("") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(candidates, id: \.self) { path in
                            Toggle(isOn: Binding(
                                get: { checked.contains { EvalPath.same($0, path) } },
                                set: { on in
                                    if on { checked.append(path) } else { checked.removeAll { EvalPath.same($0, path) } }
                                })) {
                                HStack(spacing: 4) {
                                    Image(systemName: isFolder(path) ? "folder" : "doc").foregroundStyle(.secondary)
                                    Text(EvalPath.display(path)).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                                    if entry.picked.contains(where: { EvalPath.same($0, path) }) {
                                        Text("picked").font(.caption2.bold()).foregroundStyle(.green)
                                    }
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                        if candidates.isEmpty {
                            Text("Likely didn't suggest anything for this search. Add the right files.").font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Add Files…", action: addFiles)
                    }
                }
            }
            .formStyle(.grouped)
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack {
                Text("Saved to \(EvalPath.display(EvalStorage.casesURL.path))").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction).disabled(queryList.isEmpty || expected.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 600, height: 480)
    }

    private func save() {
        let store = EvalCaseStore.shared
        store.reload()
        let c = entry.makeCase(queries: queryList, expected: expected, kind: kind, existing: store.cases)
        guard store.append(c) else {
            error = store.lastError
            return
        }
        // The test is saved either way; if the row can't be marked, the History tab says so.
        _ = SearchHistoryStore.shared.markEval(entryID: entry.id, caseID: c.id)
        dismiss()
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = "Add"
        panel.message = "Choose the file(s) or folder(s) Likely should have suggested."
        if let first = candidates.first {
            panel.directoryURL = URL(fileURLWithPath: (first as NSString).expandingTildeInPath).deletingLastPathComponent()
        }
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let path = url.path
            if !candidates.contains(where: { EvalPath.same($0, path) }) { added.append(path) }
            if !checked.contains(where: { EvalPath.same($0, path) }) { checked.append(path) }
        }
    }

    private func isFolder(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: (path as NSString).expandingTildeInPath, isDirectory: &isDir) && isDir.boolValue
    }
}
