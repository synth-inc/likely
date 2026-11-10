import AppKit
import LikelyEvalKit
import LikelyStorage
import SwiftUI

/// Personal eval cases and drafts (~/Library/Application Support/Likely/evals), for Settings → Tests
/// and the Debug View's "Make This a Test".
///
/// Edits change only the target case's line: every other line (comments, lines this version can't
/// read) is kept as is. If a file couldn't be read cleanly, editing it here is refused so nothing in
/// it is lost; fix it in a text editor first.
final class EvalCaseStore: ObservableObject {
    static let shared = EvalCaseStore()

    @Published private(set) var cases: [EvalCase] = []
    @Published private(set) var drafts: [EvalCase] = []
    @Published var lastError: String?
    /// Why a file can't be edited here (parse errors or a failed read), by file.
    private var loadProblems: [URL: String] = [:]

    func reload() {
        loadProblems = [:]
        cases = load(EvalStorage.casesURL)
        drafts = load(EvalStorage.draftsURL)
        lastError = loadProblems.values.sorted().first
    }

    private func load(_ url: URL) -> [EvalCase] {
        do {
            let (loaded, errors) = try EvalCaseFile.load(url)
            if let first = errors.first {
                loadProblems[url] = "\(url.lastPathComponent) has \(errors.count) line\(errors.count == 1 ? "" : "s") Likely can't read (\(first)). "
                    + "Fix \(url.lastPathComponent) in a text editor; editing here is off until then."
            }
            return loaded
        } catch {
            loadProblems[url] = "Couldn't read \(url.lastPathComponent): \(error.localizedDescription). Editing here is off until it can be read."
            return []
        }
    }

    var allTags: [String] { Array(Set(cases.flatMap(\.tags))).sorted() }

    /// Adds or replaces (by `replacing` id, or the case's own id) a case in cases.jsonl.
    func save(_ c: EvalCase, replacing oldID: String? = nil) {
        write(EvalStorage.casesURL, id: oldID ?? c.id, with: c)
    }

    /// Appends a case to cases.jsonl (EvalCaseFile.append, so lines this version can't read are kept).
    @discardableResult
    func append(_ c: EvalCase) -> Bool {
        do {
            try EvalCaseFile.append(c, to: EvalStorage.casesURL)
            reload()
            lastError = nil
            return true
        } catch {
            lastError = "Couldn't save: \(error.localizedDescription)"
            return false
        }
    }

    func delete(_ c: EvalCase) {
        write(EvalStorage.casesURL, id: c.id, with: nil)
    }

    func saveDraft(_ c: EvalCase, replacing oldID: String) {
        guard drafts.contains(where: { $0.id == oldID }) else { return }
        write(EvalStorage.draftsURL, id: oldID, with: c)
    }

    func discardDraft(_ c: EvalCase) {
        write(EvalStorage.draftsURL, id: c.id, with: nil)
    }

    /// Moves a draft (as edited) into cases.jsonl.
    func approve(_ c: EvalCase, draftID: String) {
        guard loadProblems[EvalStorage.draftsURL] == nil else { lastError = loadProblems[EvalStorage.draftsURL]; return }
        var approved = c
        approved.id = EvalCaseFile.uniqueID(c.id, existing: cases)
        approved.tags.removeAll { $0 == EvalCase.needsExpectedTag }
        save(approved)
        if lastError == nil { discardDraft(drafts.first { $0.id == draftID } ?? c) }
    }

    /// Replaces or removes one case's line.
    private func write(_ url: URL, id: String, with replacement: EvalCase?) {
        if let problem = loadProblems[url] {
            lastError = problem
            return
        }
        do {
            try EvalCaseFile.replace(id: id, with: replacement, in: url)
            reload()
        } catch {
            lastError = "Couldn't save: \(error.localizedDescription)"
        }
    }

}

// MARK: - Settings tab

/// Settings → Tests (every build): your tests, Run Tests, the last report, and the command your coding
/// agent can run. Dev builds also run the public fixtures from Run Tests.
struct EvalsSettings: View {
    @ObservedObject private var store = EvalCaseStore.shared
    @AppStorage(EvalCapture.defaultsKey) private var capture = EvalCapture.defaultValue
    @State private var section = Section.tests
    @State private var search = ""
    @State private var tag = ""
    @State private var editing: EditorRequest?
    @State private var showingRun = false
    @State private var copiedCommand = false
    @State private var copiedPrompt = false
    @State private var shimMessage: String?
    @State private var allowCLI = ProtectedSettings.bool(ProtectedSettings.allowCommandLineTests) == true

    enum Section: Hashable { case tests, drafts }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Automatically save picks as tests", isOn: $capture)
                Text("When you pick a file in a picker Likely helped with, what you typed and what you picked become a test (tagged “captured”, on this Mac only). Cancelled pickers are never saved.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Picker("", selection: $section) {
                    Text("Tests (\(store.cases.count))").tag(Section.tests)
                    Text("Needs expected (\(store.drafts.count))").tag(Section.drafts)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
                Spacer()
                TextField("Search", text: $search).textFieldStyle(.roundedBorder).frame(width: 160)
                if section == .tests {
                    Picker("Tag", selection: $tag) {
                        Text("All tags").tag("")
                        ForEach(store.allTags, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                }
            }
            list
                .overlay {
                    if visible.isEmpty {
                        Text(section == .tests ? "No tests yet. Use “Save as test” in the bar above a picker, Make Eval in History, New Test…, or turn on automatic saving."
                                               : "Nothing here. Picks Likely couldn't read show up here for you to fill in.")
                            .multilineTextAlignment(.center).foregroundStyle(.secondary).padding(30)
                    }
                }
            if let error = store.lastError { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack {
                Button("New Test…") { editing = EditorRequest(evalCase: EvalCaseEditor.blank(), mode: .newCase) }
                Button("Run Tests…") { showingRun = true }
                    .disabled(store.cases.isEmpty && EvalCLI.policy == .release)
                Button("Open Report") { if let url = EvalStorage.lastReport { NSWorkspace.shared.open(url) } }
                    .disabled(EvalStorage.lastReport == nil)
                    .help("The last run's report")
                Spacer()
                Button("Show Folder") {
                    try? OwnerOnly.createDirectory(EvalStorage.root)
                    NSWorkspace.shared.open(EvalStorage.root)
                }
            }
            commandLine
        }
        .onAppear { store.reload() }
        .sheet(item: $editing) { request in
            EvalCaseEditor(request: request) { editing = nil }
        }
        .sheet(isPresented: $showingRun) { RunTestsSheet(tags: store.allTags) { showingRun = false } }
    }

    /// The command for the user's coding agent, to re-run the tests after adding a tool.
    private var commandLine: some View {
        VStack(alignment: .leading, spacing: 4) {
            if EvalCLI.policy == .release {
                VStack(alignment: .leading, spacing: 1) {
                    Toggle("Allow command-line test runs", isOn: Binding(
                        get: { allowCLI },
                        set: { on in
                            ProtectedSettings.set(on, forKey: ProtectedSettings.allowCommandLineTests)
                            allowCLI = ProtectedSettings.bool(ProtectedSettings.allowCommandLineTests) == true
                        }))
                    Text("Lets Terminal and your coding agent run your tests with the command below. Off: only Run Tests here can."
                         + (ProtectedSettings.isProtected ? "" : " (This build has no provisioning profile, so the switch is stored like any other preference.)"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 6) {
                Text(EvalCommand.command + " --json")
                    .font(.caption.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    .help("Runs your tests from Terminal or a coding agent, and prints the results as JSON")
                Spacer()
                Button(copiedCommand ? "Copied" : "Copy Command") {
                    EvalCommand.copy(EvalCommand.command + " --json")
                    copiedCommand = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedCommand = false }
                }
                Button(copiedPrompt ? "Copied" : "Copy for Coding Agent") {
                    EvalCommand.copy(EvalCommand.agentPrompt)
                    copiedPrompt = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedPrompt = false }
                }
                .help("Instructions for Claude Code, Codex or another coding agent: how to run your tests before and after a change and report the difference")
                Button("Install Command…") { shimMessage = EvalCommand.installShim() }
                    .help("Adds a `likely` command to ~/.local/bin that runs your tests (no administrator password)")
            }
            if let shimMessage { Text(shimMessage).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        }
    }

    private var visible: [EvalCase] {
        let source = section == .tests ? store.cases : store.drafts
        return source.filter { c in
            (tag.isEmpty || c.tags.contains(tag) || section == .drafts)
                && (search.isEmpty || c.id.localizedCaseInsensitiveContains(search)
                    || c.query.contains { $0.localizedCaseInsensitiveContains(search) }
                    || c.tags.contains { $0.localizedCaseInsensitiveContains(search) }
                    || c.expect.paths.contains { $0.localizedCaseInsensitiveContains(search) })
        }
    }

    private var list: some View {
        List(visible) { c in
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(c.query.map { "“\($0)”" }.joined(separator: " → ")).fontWeight(.medium).lineLimit(1)
                        if c.needsExpected {
                            Text("needs expected").font(.caption2.bold()).foregroundStyle(.orange)
                        }
                    }
                    Text(c.expect.summary).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                    HStack(spacing: 4) {
                        Text(c.id).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                        if let app = c.context?.app { Text("· \(app)").font(.caption2).foregroundStyle(.tertiary) }
                        if !c.hasQuery {
                            Text("needs a query").font(.caption2).foregroundStyle(.orange)
                                .help("Saved by an older version that searched on a screenshot alone. Add a query (Edit) or it's skipped.")
                        }
                        ForEach(c.tags, id: \.self) { t in
                            Text(t).font(.caption2).padding(.horizontal, 4).background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                        }
                    }
                }
                Spacer()
                if section == .tests {
                    Button("Edit") { editing = EditorRequest(evalCase: c, mode: .editCase(c.id)) }
                    Button(role: .destructive) { store.delete(c) } label: { Image(systemName: "trash") }
                        .help("Delete this test")
                } else {
                    Button("Add to Tests") { store.approve(c, draftID: c.id) }
                        .disabled(c.needsExpected)
                        .help(c.needsExpected ? "Choose the expected file first (Fix…)" : "Move to your tests")
                    Button("Fix…") { editing = EditorRequest(evalCase: c, mode: .editDraft(c.id)) }
                    Button(role: .destructive) { store.discardDraft(c) } label: { Image(systemName: "trash") }
                        .help("Discard this draft")
                }
            }
            .padding(.vertical, 2)
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }
}

/// The command line for running the tests outside Likely: the command, a prompt for a coding agent,
/// and the optional `likely` shim in ~/.local/bin.
enum EvalCommand {
    /// `<this executable> --eval personal`, e.g. /Applications/Likely.app/Contents/MacOS/Likely --eval personal.
    static var command: String { EvalCLI.commandPath + " --eval personal" }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// For the user's coding agent: how to measure a change (a tool, an edited prompt) with the tests.
    static var agentPrompt: String {
        """
        Likely (a macOS menu bar app that suggests files in Open dialogs) can re-run my saved tests from the \
        command line, without opening any window, even while it's running:

        \(command) --json

        Run it before you change anything (a tool in Likely's tools.json, Likely's prompt) and again afterwards, \
        then report the difference: summary.passed / summary.scored before and after, the tests in \
        comparison.nowPassing and comparison.nowFailing, and whether comparison.toolsChanged is true \
        (comparison.toolChanges lists +added, -removed and ~edited tools). The second run compares itself with the first.

        If it exits with status 4, ask me to turn on “Allow command-line test runs” in Likely → Settings → Tests.

        Notes: a new or changed tool isn't used until I approve it in Likely → Settings → Tools \
        (tools.pendingApproval lists tools waiting for that), so ask me to approve it before the second run. \
        `--without-tools` runs without any of my tools, to see what they add. Exit status 0 means the run \
        completed (whatever the pass rate), 1 an error (the message is in "error"), 2 a usage error, 3 Likely isn't \
        licensed, 4 command-line runs are off. Each test sends its query to my search agent's provider, as using Likely does, and can take up \
        to two minutes. Don't run two at once.
        """
    }

    static let shimMarker = "# Installed by Likely (Settings → Tests)."

    static var shimURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/likely")
    }

    /// The shim's script: always `--eval`, so `likely` alone never starts a second copy of the app.
    static func shimScript(executable: String) -> String {
        let executable = executable.filter { !$0.isNewline && $0 != "\u{0}" }
        let quoted = "'" + executable.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return """
        #!/bin/sh
        \(shimMarker)
        # Runs your Likely tests: `likely --json` is `\(executable) --eval personal --json`.
        case "$1" in --eval) ;; *) set -- --eval personal "$@" ;; esac
        exec \(quoted) "$@"

        """
    }

    /// Writes ~/.local/bin/likely (never with sudo; never over a file Likely didn't write). Returns a
    /// line for the user.
    static func installShim() -> String {
        guard let executable = Bundle.main.executablePath else { return "Can't find Likely's executable." }
        // Opened straight from the download (macOS runs it from a random, temporary copy): that path
        // stops working once Likely quits.
        if executable.contains("/AppTranslocation/") {
            return "Move Likely to your Applications folder and open it from there first: it's running from a temporary copy macOS made."
        }
        let url = shimURL
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) || (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil {
            let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            guard existing.contains(shimMarker) else {
                return "\(EvalPath.display(url.path)) already exists and isn't Likely's; left it alone."
            }
        }
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try OwnerOnly.write(Data(shimScript(executable: executable).utf8), to: url, mode: 0o755)
        } catch {
            return "Couldn't write \(EvalPath.display(url.path)): \(error)"
        }
        return "Installed \(EvalPath.display(url.path)): run `likely --json`. If `command -v likely` prints nothing in Terminal, "
            + "add ~/.local/bin to your PATH (e.g. in ~/.zshrc: export PATH=\"$HOME/.local/bin:$PATH\")."
    }
}

// MARK: - Editor

struct EditorRequest: Identifiable {
    enum Mode { case newCase, editCase(String), editDraft(String) }
    let id = UUID()
    var evalCase: EvalCase
    var mode: Mode
    /// Files Likely suggested in the run this comes from, offered as checkboxes.
    var suggestions: [String] = []

    /// A new test prefilled from a picker run: typed queries, app, window title,
    /// Likely's suggestions as checkboxes, and the user's pick (if Accessibility read it) checked.
    static func from(run: DebugRun) -> EditorRequest {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let tilde: (String) -> String = { $0.hasPrefix(home + "/") ? "~" + $0.dropFirst(home.count) : $0 }
        let picked = run.pickedPaths.map(tilde)
        let c = EvalCase(id: EvalCase.slug(run.queries.first ?? run.appName, fallback: "case"),
                         query: run.queries,
                         context: EvalCase.Context(app: run.appName, windowTitle: run.windowTitle,
                                                   button: run.buttonTitle),
                         expect: picked.count > 1 ? Expectation(allOf: picked) : Expectation(anyOf: picked.isEmpty ? nil : picked),
                         source: "manual")
        return EditorRequest(evalCase: c, mode: .newCase, suggestions: run.files.filter(\.added).map(\.path))
    }
}

/// Edits one case: queries, context, expected files (chosen with a file panel), tags, notes.
struct EvalCaseEditor: View {
    let request: EditorRequest
    let dismiss: () -> Void
    @ObservedObject private var store = EvalCaseStore.shared

    @State private var id: String
    @State private var queries: String
    @State private var app: String
    @State private var windowTitle: String
    @State private var kind: Expectation.Kind
    @State private var paths: [String]
    @State private var tags: String
    @State private var notes: String
    /// Files chosen with the panel (kept listed even when unchecked).
    @State private var extraChosen: [String] = []

    init(request: EditorRequest, dismiss: @escaping () -> Void) {
        self.request = request
        self.dismiss = dismiss
        let c = request.evalCase
        _id = State(initialValue: c.id)
        _queries = State(initialValue: c.query.joined(separator: "\n"))
        _app = State(initialValue: c.context?.app ?? "")
        _windowTitle = State(initialValue: c.context?.windowTitle ?? "")
        _kind = State(initialValue: c.expect.kind == .none ? .anyOf : c.expect.kind)
        _paths = State(initialValue: c.expect.paths)
        _tags = State(initialValue: c.tags.filter { $0 != EvalCase.needsExpectedTag }.joined(separator: ", "))
        _notes = State(initialValue: c.notes ?? "")
    }

    static func blank() -> EvalCase {
        EvalCase(id: "", query: [], expect: Expectation(), source: "manual")
    }

    private var title: String {
        switch request.mode {
        case .newCase: return "New Test"
        case .editCase: return "Edit Test"
        case .editDraft: return "Choose the Expected File"
        }
    }

    private var queryList: [String] {
        queries.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.bold())
            Form {
                LabeledContent("Query") {
                    VStack(alignment: .leading, spacing: 2) {
                        TextEditor(text: $queries)
                            .font(.body)
                            .frame(height: 54)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
                        Text("What you'd type above the picker. One message per line; later lines are follow-ups (“not these, …”).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                TextField("App", text: $app, prompt: Text("Google Chrome"))
                TextField("Window title", text: $windowTitle, prompt: Text("optional"))
                Picker("Expected", selection: $kind) {
                    Text("Any of these files").tag(Expectation.Kind.anyOf)
                    Text("All of these files").tag(Expectation.Kind.allOf)
                    Text("This folder (or what's in it)").tag(Expectation.Kind.folder)
                }
                LabeledContent("") {
                    VStack(alignment: .leading, spacing: 4) {
                        // Likely's suggestions and anything chosen, each with a checkbox: checked = expected.
                        ForEach(candidates, id: \.self) { path in
                            Toggle(isOn: Binding(
                                get: { paths.contains(path) },
                                set: { on in
                                    if on { if kind == .folder { paths = [path] } else { add([path]) } } else { paths.removeAll { $0 == path } }
                                })) {
                                HStack(spacing: 4) {
                                    Image(systemName: isFolder(path) ? "folder" : "doc").foregroundStyle(.secondary)
                                    Text(EvalPath.display(path)).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                        if candidates.isEmpty {
                            Text("No suggestions to pick from.").font(.caption).foregroundStyle(.secondary)
                        }
                        Button(kind == .folder ? "Choose Folder…" : "Choose Other Files or Folders…", action: choose)
                    }
                }
                TextField("Tags", text: $tags, prompt: Text("image, documents, folder"))
                TextField("Notes", text: $notes, prompt: Text("optional"))
                TextField("ID", text: $id, prompt: Text(EvalCase.slug(queryList.first ?? "", fallback: "case")))
            }
            .formStyle(.grouped)
            HStack {
                Text("Saved to \(EvalPath.display(isDraft ? EvalStorage.draftsURL.path : EvalStorage.casesURL.path))")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
                if case .editDraft(let draftID) = request.mode {
                    Button("Save Draft") { store.saveDraft(built(), replacing: draftID); dismiss() }
                    Button("Add to Tests") { store.approve(built(), draftID: draftID); dismiss() }
                        .keyboardShortcut(.defaultAction).disabled(!valid)
                } else {
                    Button("Save", action: save).keyboardShortcut(.defaultAction).disabled(!valid)
                }
            }
        }
        .padding(20)
        .frame(width: 600, height: 500)
    }

    /// Suggestions first (best first), then anything else chosen.
    private var candidates: [String] {
        var list = request.suggestions.map(tilde)
        for p in paths + extraChosen where !list.contains(p) { list.append(p) }
        return list
    }

    private var isDraft: Bool { if case .editDraft = request.mode { return true } else { return false } }
    private var valid: Bool { !queryList.isEmpty && !paths.isEmpty }

    private func built() -> EvalCase {
        var c = request.evalCase
        let typedID = id.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-")
        c.id = typedID.isEmpty ? EvalCase.slug(queryList.first ?? "", fallback: "case") : typedID
        c.query = queryList
        let context = EvalCase.Context(app: app.isEmpty ? nil : app, windowTitle: windowTitle.isEmpty ? nil : windowTitle,
                                       button: c.context?.button,
                                       userName: c.context?.userName, useTools: c.context?.useTools)
        c.context = context.isEmpty ? nil : context
        c.expect = Expectation.make(kind: paths.isEmpty ? .none : kind, paths: kind == .folder ? Array(paths.prefix(1)) : paths)
        c.tags = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if c.expect.isEmpty && isDraft { c.tags.append(EvalCase.needsExpectedTag) }
        c.notes = notes.isEmpty ? nil : notes
        if c.createdAt == nil { c.createdAt = EvalCase.now() }
        return c
    }

    private func save() {
        var c = built()
        switch request.mode {
        case .newCase:
            c.id = EvalCaseFile.uniqueID(c.id, existing: store.cases)
            store.save(c)
        case .editCase(let oldID):
            if c.id != oldID { c.id = EvalCaseFile.uniqueID(c.id, existing: store.cases.filter { $0.id != oldID }) }
            store.save(c, replacing: oldID)
        case .editDraft(let draftID):
            store.saveDraft(c, replacing: draftID)
        }
        if store.lastError == nil { dismiss() }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = kind != .folder
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = kind != .folder
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = kind == .folder ? "Choose Folder" : "Add"
        panel.message = kind == .folder ? "Choose the folder the right answer is in." : "Choose the file(s) Likely should suggest."
        if let first = paths.first {
            panel.directoryURL = URL(fileURLWithPath: (first as NSString).expandingTildeInPath).deletingLastPathComponent()
        }
        guard panel.runModal() == .OK else { return }
        let chosen = panel.urls.map { tilde($0.path) }
        for c in chosen where !extraChosen.contains(c) { extraChosen.append(c) }
        if kind == .folder { paths = Array(chosen.prefix(1)) } else { add(chosen) }
    }

    private func add(_ new: [String]) {
        for p in new where !paths.contains(p) { paths.append(p) }
    }

    private func tilde(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    private func isFolder(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: (path as NSString).expandingTildeInPath, isDirectory: &isDir) && isDir.boolValue
    }
}

// MARK: - Run tests

/// Runs `Likely --eval … --json` (this same binary) as a subprocess: progress from its stderr, the
/// results from its stdout. Release builds run your tests only, with an agent Likely detected (the
/// subprocess finds it again itself; no path is passed).
struct RunTestsSheet: View {
    let tags: [String]
    let dismiss: () -> Void
    @ObservedObject private var agents = AgentDetector.shared
    @StateObject private var job = EvalJob()
    @State private var suite = "personal"
    @State private var agentID = Settings.agentID
    @State private var model = AgentModels.selected(for: Settings.agentID)
    @State private var withTools = true
    @State private var tagFilter = ""
    @State private var k = 8
    @State private var timeout = 120
    /// Dev builds ship the public suite (build.sh copies evals/fixtures); hidden if it's missing.
    private let hasFixtures = (try? Suite.fixturesFile()) != nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Run Tests").font(.title3.bold())
            Form {
                if hasFixtures {
                    Picker("Suite", selection: $suite) {
                        Text("My tests").tag("personal")
                        Text("Public fixtures (synthetic files)").tag("fixtures")
                        Text("Both").tag("all")
                    }
                }
                Picker("Agent", selection: $agentID) {
                    ForEach(AgentKind.all.filter { $0.isSupported && agents.path(for: $0) != nil }) { Text($0.name).tag($0.id) }
                    if agents.path(for: AgentKind.with(id: agentID) ?? AgentKind.all[0]) == nil {
                        Text(AgentKind.with(id: agentID)?.name ?? agentID).tag(agentID)
                    }
                }
                .onChange(of: agentID) { _, id in model = AgentModels.selected(for: id) }
                Picker("Model", selection: $model) {
                    ForEach(Array(Set(AgentModels.available(for: agentID) + [model])).sorted(), id: \.self) { Text($0).tag($0) }
                }
                Picker("Your tools", selection: $withTools) {
                    Text("With your tools").tag(true)
                    Text("Without (built-in commands only)").tag(false)
                }
                TextField("Tags", text: $tagFilter, prompt: Text(tags.isEmpty ? "all" : "all, or e.g. \(tags.prefix(2).joined(separator: ", "))"))
                Stepper("Pass if found in the top \(k)", value: $k, in: 1...8)
                Stepper("Time limit per test: \(timeout)s", value: $timeout, in: 30...600, step: 30)
            }
            .formStyle(.grouped)
            .disabled(job.isRunning)
            if suite != "fixtures" {
                Text("Running your tests sends their queries, and whatever the agent finds, to \(AgentKind.with(id: agentID)?.name ?? "the agent")'s provider, as using Likely does.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if suite != "personal" && agentID == "codex" {
                // Codex can't run inside the isolation sandbox (see EvalCLI): the fixtures aren't isolated.
                Text("Codex can't be isolated: during the public fixtures it can read any of your files, and whatever it reads goes to OpenAI, as using Likely does.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if job.isRunning || job.finished {
                VStack(alignment: .leading, spacing: 6) {
                    if job.total > 0 {
                        ProgressView(value: Double(job.done), total: Double(job.total)) {
                            Text(job.isRunning ? "Running \(job.done)/\(job.total)…" : "Finished \(job.done)/\(job.total)")
                        }
                    } else if job.isRunning {
                        ProgressView().controlSize(.small)
                    }
                    if let result = job.result, !job.isRunning {
                        RunResultSummary(result: result)
                    } else {
                        ScrollView {
                            Text(job.output.suffix(14).joined(separator: "\n"))
                                .font(.caption.monospaced()).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 110)
                        .padding(6)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            HStack {
                Spacer()
                if job.isRunning {
                    Button("Stop") { job.stop() }
                } else {
                    Button("Close", action: dismiss).keyboardShortcut(.cancelAction)
                }
                if let report = job.report, !job.isRunning {
                    Button("Open Report") { NSWorkspace.shared.open(report) }
                }
                Button("Run", action: run).keyboardShortcut(.defaultAction).disabled(job.isRunning)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear { if agents.paths.isEmpty { agents.scan() } }
    }

    private func run() {
        var args = ["--eval", suite, "--agent", agentID, "--model", model, "--k", "\(k)", "--timeout", "\(timeout)", "--json"]
        let filter = tagFilter.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("-") }
        if !filter.isEmpty { args += ["--tags", filter.joined(separator: ",")] }
        if !withTools { args.append("--without-tools") }
        // Dev builds pass the path the app found; release builds can't (the run looks it up itself).
        if EvalCLI.policy == .dev, let path = agents.paths[agentID] { args += ["--agent-path", path] }
        job.start(arguments: args)
    }
}

/// The finished run, from its JSON: passes, the comparison with the previous run and tool changes.
private struct RunResultSummary: View {
    let result: EvalCLIResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let error = result.error {
                Text(error).foregroundStyle(.orange)
            }
            if let s = result.summary {
                Text("Passed \(s.passed) of \(s.scored) (\(percent(s.passRate)))" + (result.status == "interrupted" ? " · stopped early" : ""))
                    .font(.headline)
                let cost = s.totalCostUSD.map { String(format: " · $%.3f", $0) } ?? ""
                Text("Median time \(s.medianTotalSeconds.map { String(format: "%.1fs", $0) } ?? "–")\(cost)"
                     + (s.timeouts + s.errors > 0 ? " · \(s.timeouts) timed out, \(s.errors) failed to run" : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let tools = result.tools {
                Text("Tools: " + (tools.active.isEmpty ? "none" : tools.active.map(\.id).joined(separator: ", "))
                     + (tools.pendingApproval.isEmpty ? "" : " · waiting for approval (not used): \(tools.pendingApproval.joined(separator: ", "))"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let c = result.comparison {
                let delta = c.passedDelta == 0 ? "no change" : (c.passedDelta > 0 ? "+\(c.passedDelta)" : "\(c.passedDelta)")
                Text("Previous run: \(c.previousPassed) of \(c.previousScored) (\(delta))")
                    .font(.caption)
                if c.toolsChanged {
                    Text("Tools changed since then: \(c.toolChanges.joined(separator: ", "))").font(.caption).foregroundStyle(.blue)
                }
                if !c.settingsDiffer.isEmpty {
                    Text("Different settings than the previous run (\(c.settingsDiffer.joined(separator: ", "))): not like for like.")
                        .font(.caption).foregroundStyle(.orange)
                }
                if !c.nowPassing.isEmpty { Text("Now passing: \(c.nowPassing.joined(separator: ", "))").font(.caption).foregroundStyle(.green) }
                if !c.nowFailing.isEmpty { Text("Now failing: \(c.nowFailing.joined(separator: ", "))").font(.caption).foregroundStyle(.red) }
            } else if result.summary != nil {
                Text("First run: the next one will compare with this.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func percent(_ x: Double) -> String { "\(Int((x * 100).rounded()))%" }
}

/// The eval subprocess: `[i/n]` progress lines from stderr, the JSON result from stdout.
final class EvalJob: ObservableObject {
    @Published var output: [String] = []
    @Published var done = 0
    @Published var total = 0
    @Published var isRunning = false
    @Published var finished = false
    @Published var report: URL?
    @Published var result: EvalCLIResult?
    private var process: Process?
    private var quitObserver: NSObjectProtocol?

    init() {
        // Quitting Likely mid-run mustn't leave the eval (and its agents) running.
        quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                                              queue: .main) { [weak self] _ in self?.stopAndWait() }
    }

    /// Closing the sheet (or Settings) releases the job: stop the eval with it.
    deinit {
        if let quitObserver { NotificationCenter.default.removeObserver(quitObserver) }
        if let process, process.isRunning { process.terminate() }
    }

    private var collector: ProcessOutputCollector?

    func start(arguments: [String]) {
        guard let executable = Bundle.main.executableURL else { return }
        output = ["$ Likely " + arguments.joined(separator: " ")]
        done = 0
        total = 0
        report = nil
        result = nil
        finished = false
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        // The results are read once the run has exited and both pipes reached end of file.
        collector = ProcessOutputCollector(process: process, onStderrLine: { [weak self] line in self?.consume(line) },
                                           completion: { [weak self] out, status in self?.finish(stdout: out, status: status) })
        do {
            try process.run()
            self.process = process
            isRunning = true
        } catch {
            collector = nil
            output.append("Couldn't start: \(error.localizedDescription)")
        }
    }

    private func finish(stdout: Data, status: Int32) {
        isRunning = false
        finished = true
        collector = nil
        if let parsed = try? JSONDecoder().decode(EvalCLIResult.self, from: stdout) {
            result = parsed
            if let path = parsed.reportPath, FileManager.default.fileExists(atPath: path) { report = URL(fileURLWithPath: path) }
        }
        if status != 0 && result == nil { output.append("Exited with status \(status)") }
    }

    /// SIGTERM: the eval cancels its agents and writes partial results (see EvalCLI).
    func stop() {
        guard let process, process.isRunning else { return }
        process.terminate()
    }

    /// At quit: give the eval a moment to stop its agents and write partial results.
    private func stopAndWait() {
        guard let process, process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning, Date() < deadline { usleep(50_000) }
    }

    private func consume(_ line: String) {
        output.append(line)
        if line.hasPrefix("Running "), let n = line.split(separator: " ").dropFirst().first.flatMap({ Int($0) }) { total = n }
        if line.hasPrefix("["), let slash = line.firstIndex(of: "/"), let close = line.firstIndex(of: "]"),
           let i = Int(line[line.index(after: line.startIndex)..<slash]), let n = Int(line[line.index(after: slash)..<close]) {
            done = i
            total = n
        }
        if line.hasPrefix("Report: ") { report = URL(fileURLWithPath: String(line.dropFirst("Report: ".count))) }
    }
}
