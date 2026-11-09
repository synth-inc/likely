import AppKit
import LikelyEvalKit
import LikelyStorage
import SwiftUI

/// Personal eval cases and drafts (~/Library/Application Support/Likely/evals), for Settings → Evals
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
        let old = cases.first { $0.id == (oldID ?? c.id) }
        write(EvalStorage.casesURL, id: oldID ?? c.id, with: c, released: old)
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
        write(EvalStorage.casesURL, id: c.id, with: nil, released: c)
    }

    func saveDraft(_ c: EvalCase, replacing oldID: String) {
        guard let old = drafts.first(where: { $0.id == oldID }) else { return }
        write(EvalStorage.draftsURL, id: oldID, with: c, released: old)
    }

    func discardDraft(_ c: EvalCase) {
        write(EvalStorage.draftsURL, id: c.id, with: nil, released: c)
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

    /// Replaces or removes one case's line. `released`: the case as it was, whose screenshot is
    /// deleted if nothing refers to it any more.
    private func write(_ url: URL, id: String, with replacement: EvalCase?, released: EvalCase?) {
        if let problem = loadProblems[url] {
            lastError = problem
            return
        }
        do {
            try EvalCaseFile.replace(id: id, with: replacement, in: url)
            reload()
            if let shot = released?.context?.screenshot { removeScreenshotIfUnused(shot) }
        } catch {
            lastError = "Couldn't save: \(error.localizedDescription)"
        }
    }

    /// Deletes a screenshot Likely copied into the evals folder once no case or draft uses it.
    func removeScreenshotIfUnused(_ path: String) {
        let folder = EvalStorage.screenshotsURL.standardizedFileURL.path + "/"
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard standardized.hasPrefix(folder), loadProblems.isEmpty else { return }
        let used = (cases + drafts).contains { $0.context?.screenshot.map { URL(fileURLWithPath: $0).standardizedFileURL.path } == standardized }
        if !used { try? FileManager.default.removeItem(atPath: standardized) }
    }

    /// Keeps a screenshot with the cases, encrypted (evals/screenshots/<id>.png.enc). A path already
    /// in that folder is kept as it is.
    static func keepScreenshot(path: String, id: String) -> String? {
        if URL(fileURLWithPath: path).standardizedFileURL.path.hasPrefix(EvalStorage.screenshotsURL.standardizedFileURL.path + "/") {
            return path
        }
        guard let png = try? EvalScreenshots.load(path, cipher: DataProtection.cipher) else { return nil }
        return keepScreenshot(png: png, id: id)
    }

    static func keepScreenshot(png: Data, id: String) -> String? {
        do {
            return try EvalScreenshots.save(png, id: id, cipher: DataProtection.cipher)
        } catch {
            Log.write("evals", "couldn't save the test's screenshot: \(error)")
            return nil
        }
    }
}

// MARK: - Settings tab

// The Evals tab and Run Suite are dev-build only (LIKELY_DEV), like `--eval` itself. The store and
// the editor above/below stay in every build (the Debug View and search history use them).
#if LIKELY_DEV

struct EvalsSettings: View {
    @ObservedObject private var store = EvalCaseStore.shared
    @AppStorage(EvalCapture.defaultsKey) private var capture = EvalCapture.defaultValue
    @State private var section = Section.tests
    @State private var search = ""
    @State private var tag = ""
    @State private var editing: EditorRequest?
    @State private var showingRun = false

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
                        Text(section == .tests ? "No tests yet. Use “Save as test” in the bar above a picker, New Test…, or turn on automatic saving."
                                               : "Nothing here. Picks Likely couldn't read show up here for you to fill in.")
                            .multilineTextAlignment(.center).foregroundStyle(.secondary).padding(30)
                    }
                }
            if let error = store.lastError { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack {
                Button("New Test…") { editing = EditorRequest(evalCase: EvalCaseEditor.blank(), mode: .newCase) }
                Button("Run Suite…") { showingRun = true }
                Button("Open Last Report") { if let url = EvalStorage.lastReport { NSWorkspace.shared.open(url) } }
                    .disabled(EvalStorage.lastReport == nil)
                Spacer()
                Button("Show Folder") {
                    try? FileManager.default.createDirectory(at: EvalStorage.root, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(EvalStorage.root)
                }
            }
        }
        .onAppear { store.reload() }
        .sheet(item: $editing) { request in
            EvalCaseEditor(request: request) { editing = nil }
        }
        .sheet(isPresented: $showingRun) { RunSuiteSheet(tags: store.allTags) { showingRun = false } }
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

#endif

// MARK: - Editor

struct EditorRequest: Identifiable {
    enum Mode { case newCase, editCase(String), editDraft(String) }
    let id = UUID()
    var evalCase: EvalCase
    var mode: Mode
    /// Files Likely suggested in the run this comes from, offered as checkboxes.
    var suggestions: [String] = []
    /// The run's screenshot (in memory), saved encrypted with the case if kept.
    var screenshotPNG: Data?

    /// A new test prefilled from a picker run: typed queries, app, window title, screenshot,
    /// Likely's suggestions as checkboxes, and the user's pick (if Accessibility read it) checked.
    static func from(run: DebugRun) -> EditorRequest {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let tilde: (String) -> String = { $0.hasPrefix(home + "/") ? "~" + $0.dropFirst(home.count) : $0 }
        let picked = run.pickedPaths.map(tilde)
        let c = EvalCase(id: EvalCase.slug(run.queries.first ?? run.appName, fallback: "case"),
                         query: run.queries,
                         context: EvalCase.Context(app: run.appName, windowTitle: run.windowTitle,
                                                   screenshot: nil, button: run.buttonTitle),
                         expect: picked.count > 1 ? Expectation(allOf: picked) : Expectation(anyOf: picked.isEmpty ? nil : picked),
                         tags: run.screenshotPNG != nil ? ["screenshot"] : [], source: "manual")
        return EditorRequest(evalCase: c, mode: .newCase, suggestions: run.files.filter(\.added).map(\.path),
                             screenshotPNG: run.screenshotPNG)
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
    @State private var screenshot: String
    /// The run's screenshot, not saved yet (a new test from a picker run).
    @State private var pendingPNG: Data?
    /// The screenshot, decrypted in memory for the preview (nil: none, or it can't be read).
    @State private var preview: NSImage?
    @State private var previewProblem: String?
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
        _screenshot = State(initialValue: c.context?.screenshot ?? "")
        _pendingPNG = State(initialValue: request.screenshotPNG)
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
                if !screenshot.isEmpty || pendingPNG != nil {
                    LabeledContent("Screenshot") {
                        VStack(alignment: .leading, spacing: 4) {
                            if let preview {
                                Image(nsImage: preview).resizable().aspectRatio(contentMode: .fit).frame(maxHeight: 110)
                                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(.separator))
                            } else if let previewProblem {
                                Text(previewProblem).font(.caption).foregroundStyle(.secondary)
                            }
                            HStack {
                                Text(screenshot.isEmpty ? "From this run (saved encrypted with the test)" : EvalPath.display(screenshot))
                                    .font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                                Button("Remove") { screenshot = ""; pendingPNG = nil; preview = nil; previewProblem = nil }
                            }
                        }
                    }
                    .task(id: screenshot + (pendingPNG == nil ? "" : "+run")) { loadPreview() }
                }
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

    /// Decrypts the screenshot in memory for the preview; nothing decrypted is written anywhere.
    private func loadPreview() {
        if let pendingPNG {
            preview = NSImage(data: pendingPNG)
            previewProblem = nil
            return
        }
        guard !screenshot.isEmpty else { return }
        do {
            preview = NSImage(data: try EvalScreenshots.load((screenshot as NSString).expandingTildeInPath, cipher: DataProtection.cipher))
            previewProblem = preview == nil ? "Not an image" : nil
        } catch let error as DataCipher.CipherError {
            preview = nil
            previewProblem = "This screenshot can't be read by this build: \(error)."
        } catch {
            preview = nil
            previewProblem = "Can't read the screenshot: \(error.localizedDescription)"
        }
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
                                       screenshot: screenshot.isEmpty ? nil : screenshot, button: c.context?.button,
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
            var copied: String?
            if let png = pendingPNG, let kept = EvalCaseStore.keepScreenshot(png: png, id: c.id) {
                copied = kept
                c.context = c.context ?? EvalCase.Context()
                c.context?.screenshot = kept
            } else if let shot = c.context?.screenshot, let kept = EvalCaseStore.keepScreenshot(path: shot, id: c.id) {
                if kept != shot { copied = kept }
                c.context?.screenshot = kept
            }
            store.save(c)
            if store.lastError != nil, let copied { store.removeScreenshotIfUnused(copied) }
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

// MARK: - Run suite

#if LIKELY_DEV

/// Runs `Likely --eval …` (this same binary) as a subprocess and shows its progress.
struct RunSuiteSheet: View {
    let tags: [String]
    let dismiss: () -> Void
    @ObservedObject private var agents = AgentDetector.shared
    @StateObject private var job = EvalJob()
    @State private var suite = "personal"
    @State private var agentID = Settings.agentID
    @State private var model = AgentModels.selected(for: Settings.agentID)
    @State private var tagFilter = ""
    @State private var k = 8
    @State private var timeout = 120
    /// The public suite ships in dev builds (build.sh copies evals/fixtures); hidden if it's missing.
    private let hasFixtures = (try? Suite.fixturesFile()) != nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Run Suite").font(.title3.bold())
            Form {
                Picker("Suite", selection: $suite) {
                    Text("My tests").tag("personal")
                    if hasFixtures {
                        Text("Public fixtures (synthetic files)").tag("fixtures")
                        Text("Both").tag("all")
                    }
                }
                Picker("Agent", selection: $agentID) {
                    ForEach(AgentKind.all.filter { $0.isSupported && agents.path(for: $0) != nil }) { Text($0.name).tag($0.id) }
                }
                .onChange(of: agentID) { _, id in model = AgentModels.selected(for: id) }
                Picker("Model", selection: $model) {
                    ForEach(Array(Set(AgentModels.available(for: agentID) + [model])).sorted(), id: \.self) { Text($0).tag($0) }
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
        var args = ["--eval", suite, "--agent", agentID, "--model", model, "--k", "\(k)", "--timeout", "\(timeout)"]
        let filter = tagFilter.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !filter.isEmpty { args += ["--tags", filter.joined(separator: ",")] }
        if let path = agents.paths[agentID] { args += ["--agent-path", path] }
        job.start(arguments: args)
    }
}

/// The eval subprocess: parses `[i/n]` progress lines and the final `Report:` line.
final class EvalJob: ObservableObject {
    @Published var output: [String] = []
    @Published var done = 0
    @Published var total = 0
    @Published var isRunning = false
    @Published var finished = false
    @Published var report: URL?
    private var process: Process?
    private var buffer = Data()
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

    func start(arguments: [String]) {
        guard let executable = Bundle.main.executableURL else { return }
        output = ["$ Likely " + arguments.joined(separator: " ")]
        done = 0
        total = 0
        report = nil
        finished = false
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async { self?.consume(data) }
        }
        process.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                pipe.fileHandleForReading.readabilityHandler = nil
                if let rest = try? pipe.fileHandleForReading.readToEnd() { self?.consume(rest) }
                self?.isRunning = false
                self?.finished = true
                if p.terminationStatus != 0 { self?.output.append("Exited with status \(p.terminationStatus)") }
            }
        }
        do {
            try process.run()
            self.process = process
            isRunning = true
        } catch {
            output.append("Couldn't start: \(error.localizedDescription)")
        }
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

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...newline)
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
}
#endif
