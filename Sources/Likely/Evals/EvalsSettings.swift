import AppKit
import LikelyEvalKit
import SwiftUI

/// Personal eval cases and drafts (~/Library/Application Support/Likely/evals), for Settings → Evals
/// and the Debug View's "Make This a Test".
final class EvalCaseStore: ObservableObject {
    static let shared = EvalCaseStore()

    @Published private(set) var cases: [EvalCase] = []
    @Published private(set) var drafts: [EvalCase] = []
    @Published var lastError: String?

    func reload() {
        do {
            cases = try EvalCaseFile.load(EvalStorage.casesURL).cases
            drafts = try EvalCaseFile.load(EvalStorage.draftsURL).cases
        } catch {
            lastError = "Couldn't read your tests: \(error.localizedDescription)"
        }
    }

    var allTags: [String] { Array(Set(cases.flatMap(\.tags))).sorted() }

    /// Adds or replaces (by `replacing` id, or the case's own id) a case in cases.jsonl.
    func save(_ c: EvalCase, replacing oldID: String? = nil) {
        var list = cases
        if let index = list.firstIndex(where: { $0.id == (oldID ?? c.id) }) { list[index] = c } else { list.append(c) }
        write(list, to: EvalStorage.casesURL) { self.cases = list }
    }

    func delete(_ c: EvalCase) {
        let list = cases.filter { $0.id != c.id }
        write(list, to: EvalStorage.casesURL) { self.cases = list }
    }

    func saveDraft(_ c: EvalCase, replacing oldID: String) {
        var list = drafts
        if let index = list.firstIndex(where: { $0.id == oldID }) { list[index] = c }
        write(list, to: EvalStorage.draftsURL) { self.drafts = list }
    }

    func discardDraft(_ c: EvalCase) {
        let list = drafts.filter { $0.id != c.id }
        write(list, to: EvalStorage.draftsURL) { self.drafts = list }
    }

    /// Moves a draft (as edited) into cases.jsonl.
    func approve(_ c: EvalCase, draftID: String) {
        var approved = c
        approved.id = EvalCaseFile.uniqueID(c.id, existing: cases)
        approved.tags.removeAll { $0 == EvalCase.needsExpectedTag }
        save(approved)
        if lastError == nil { discardDraft(drafts.first { $0.id == draftID } ?? c) }
    }

    private func write(_ list: [EvalCase], to url: URL, then update: () -> Void) {
        do {
            try EvalCaseFile.save(list, to: url)
            lastError = nil
            update()
        } catch {
            lastError = "Couldn't save: \(error.localizedDescription)"
        }
    }

    /// Copies a screenshot next to the cases (debug-view copies are deleted as runs roll over).
    static func keepScreenshot(_ url: URL, id: String) -> String? {
        let fm = FileManager.default
        if url.path.hasPrefix(EvalStorage.screenshotsURL.path) { return url.path }
        try? fm.createDirectory(at: EvalStorage.screenshotsURL, withIntermediateDirectories: true)
        let copy = EvalStorage.screenshotsURL.appendingPathComponent("\(id).png")
        try? fm.removeItem(at: copy)
        return (try? fm.copyItem(at: url, to: copy)) != nil ? copy.path : nil
    }
}

// MARK: - Settings tab

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
                Toggle("Save my picks as draft tests", isOn: $capture)
                Text("When you pick a file in a picker Likely helped with, save what you typed and what you picked as a draft (on this Mac only). Cancelled pickers are never saved."
                     + (EvalCapture.defaultValue ? " On by default in dev builds." : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Picker("", selection: $section) {
                    Text("Tests (\(store.cases.count))").tag(Section.tests)
                    Text("Drafts (\(store.drafts.count))").tag(Section.drafts)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
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
                        Text(section == .tests ? "No tests yet. Add one with New Test…, from the Debug View, or approve a draft."
                                               : "No drafts. With saving turned on, picks you make show up here.")
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
                    Button("Approve") { store.approve(c, draftID: c.id) }
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

// MARK: - Editor

struct EditorRequest: Identifiable {
    enum Mode { case newCase, editCase(String), editDraft(String) }
    let id = UUID()
    var evalCase: EvalCase
    var mode: Mode
    /// Files Likely suggested in the run this comes from, offered as one-click expected files.
    var suggestions: [String] = []
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
    @State private var kind: Expectation.Kind
    @State private var paths: [String]
    @State private var tags: String
    @State private var notes: String

    init(request: EditorRequest, dismiss: @escaping () -> Void) {
        self.request = request
        self.dismiss = dismiss
        let c = request.evalCase
        _id = State(initialValue: c.id)
        _queries = State(initialValue: c.query.joined(separator: "\n"))
        _app = State(initialValue: c.context?.app ?? "")
        _windowTitle = State(initialValue: c.context?.windowTitle ?? "")
        _screenshot = State(initialValue: c.context?.screenshot ?? "")
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
        case .editDraft: return "Fix Draft"
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
                if !screenshot.isEmpty {
                    LabeledContent("Screenshot") {
                        HStack {
                            Text(EvalPath.display(screenshot)).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                            Button("Remove") { screenshot = "" }
                        }
                    }
                }
                Picker("Expected", selection: $kind) {
                    Text("Any of these files").tag(Expectation.Kind.anyOf)
                    Text("All of these files").tag(Expectation.Kind.allOf)
                    Text("This folder (or what's in it)").tag(Expectation.Kind.folder)
                }
                LabeledContent("") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(paths, id: \.self) { path in
                            HStack {
                                Image(systemName: isFolder(path) ? "folder" : "doc").foregroundStyle(.secondary)
                                Text(EvalPath.display(path)).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Button { paths.removeAll { $0 == path } } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless)
                            }
                        }
                        HStack {
                            Button(kind == .folder ? "Choose Folder…" : "Add Files…", action: choose)
                            if !request.suggestions.isEmpty {
                                Menu("Add a Suggestion") {
                                    ForEach(request.suggestions, id: \.self) { s in
                                        Button(EvalPath.display(s)) { add([tilde(s)]) }
                                    }
                                }
                                .fixedSize()
                            }
                        }
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
                    Button("Approve") { store.approve(built(), draftID: draftID); dismiss() }
                        .keyboardShortcut(.defaultAction).disabled(!valid)
                } else {
                    Button("Save", action: save).keyboardShortcut(.defaultAction).disabled(!valid)
                }
            }
        }
        .padding(20)
        .frame(width: 600, height: 500)
    }

    private var isDraft: Bool { if case .editDraft = request.mode { return true } else { return false } }
    private var valid: Bool { !queryList.isEmpty && !paths.isEmpty }

    private func built() -> EvalCase {
        var c = request.evalCase
        let typedID = id.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-")
        c.id = typedID.isEmpty ? EvalCase.slug(queryList.first ?? "", fallback: "case") : typedID
        c.query = queryList
        let context = EvalCase.Context(app: app.isEmpty ? nil : app, windowTitle: windowTitle.isEmpty ? nil : windowTitle,
                                       screenshot: screenshot.isEmpty ? nil : screenshot, button: c.context?.button)
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
            if let shot = c.context?.screenshot, let kept = EvalCaseStore.keepScreenshot(URL(fileURLWithPath: shot), id: c.id) {
                c.context?.screenshot = kept
            }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Run Suite").font(.title3.bold())
            Form {
                Picker("Suite", selection: $suite) {
                    Text("My tests").tag("personal")
                    Text("Public fixtures (synthetic files)").tag("fixtures")
                    Text("Both").tag("all")
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
        var args = ["--eval", suite, "--agent", agentID, "--model", model, "--k", "\(k)", "--timeout", "\(timeout)", "--allow-eval"]
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

    func stop() {
        process?.terminate()
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
