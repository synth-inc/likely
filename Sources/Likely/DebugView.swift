import AppKit
import LikelyEvalKit
import LikelyStorage
import SwiftUI

/// Record of one picker → claude run, for the debug window.
final class DebugRun: ObservableObject, Identifiable {
    let id = UUID()
    let date = Date()
    let appName: String
    let detectedVia: String
    @Published var prompt: String?
    @Published var model: String?
    @Published var events: [(Date, String)] = []
    @Published var files: [(path: String, added: Bool)] = []
    /// Files put in the Likely folder as recent files when the picker opened (to measure how often
    /// the picked file was one of them).
    @Published var recentFiles: [String] = []
    @Published var outcome: String?
    @Published var closedReason: String?
    /// For "Make this a test": what the user typed, the window behind the picker, and the file(s)
    /// they picked in the end (when Accessibility could read them).
    @Published var queries: [String] = []
    @Published var windowTitle: String?
    @Published var buttonTitle: String?
    @Published var pickedPaths: [String] = []

    init(appName: String, detectedVia: String) {
        self.appName = appName
        self.detectedVia = detectedVia
    }

    func log(_ message: String) { events.append((Date(), message)) }
}

/// Keeps the most recent runs, in memory only.
final class DebugStore: ObservableObject {
    static let shared = DebugStore()
    static let maxRuns = 15

    @Published private(set) var runs: [DebugRun] = []

    func begin(appName: String, detectedVia: String) -> DebugRun {
        let run = DebugRun(appName: appName, detectedVia: detectedVia)
        runs.insert(run, at: 0)
        if runs.count > Self.maxRuns { runs.removeLast(runs.count - Self.maxRuns) }
        return run
    }
}

struct DebugView: View {
    @ObservedObject var store: DebugStore
    @State private var selection: UUID?

    var body: some View {
        NavigationSplitView {
            List(store.runs, selection: $selection) { run in
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.appName).font(.headline)
                    Text(run.date.formatted(date: .omitted, time: .standard)).font(.caption).foregroundStyle(.secondary)
                }
                .tag(run.id)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 190)
            .overlay {
                if store.runs.isEmpty {
                    Text("No runs yet.\nOpen a file picker in any app.").multilineTextAlignment(.center).foregroundStyle(.secondary)
                }
            }
        } detail: {
            if let run = store.runs.first(where: { $0.id == selection }) ?? store.runs.first {
                RunDetail(run: run)
            } else {
                Text("Nothing to show").foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 820, minHeight: 600)
    }
}

private struct RunDetail: View {
    @ObservedObject var run: DebugRun
    @State private var testEditor: EditorRequest?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(run.appName) — \(run.date.formatted(date: .abbreviated, time: .standard))").font(.title3.bold())
                        Text("Detected via \(run.detectedVia)\(run.model.map { " · model \($0)" } ?? "")")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Make This a Test…") { testEditor = makeTest() }
                        .help("Save this run's query and context as an eval case, with the file(s) you wanted")
                }

                section("Prompt") {
                    if let prompt = run.prompt {
                        Text(prompt)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                        Button("Copy Prompt") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(prompt, forType: .string)
                        }
                    } else {
                        Text("Not sent yet").foregroundStyle(.secondary)
                    }
                }

                section("Progress") {
                    ForEach(Array(run.events.enumerated()), id: \.offset) { _, event in
                        HStack(alignment: .firstTextBaseline) {
                            Text(String(format: "+%.1fs", event.0.timeIntervalSince(run.date)))
                                .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                                .frame(width: 54, alignment: .trailing)
                            Text(event.1).textSelection(.enabled)
                        }
                    }
                }

                section("Recent files") {
                    if run.recentFiles.isEmpty {
                        Text("None").foregroundStyle(.secondary)
                    }
                    ForEach(run.recentFiles, id: \.self) { path in
                        HStack {
                            Text(path).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                            Spacer()
                            Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                                .buttonStyle(.link)
                        }
                    }
                }

                section("Files Claude suggested") {
                    if run.files.isEmpty {
                        Text(run.outcome == nil ? "None yet" : "None").foregroundStyle(.secondary)
                    }
                    ForEach(Array(run.files.enumerated()), id: \.offset) { _, file in
                        HStack {
                            Image(systemName: file.added ? "checkmark.circle.fill" : "xmark.circle")
                                .foregroundStyle(file.added ? Color.green : Color.secondary)
                            Text(file.path).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                            Spacer()
                            Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)]) }
                                .buttonStyle(.link)
                        }
                    }
                }

                if run.outcome != nil || run.closedReason != nil {
                    section("Outcome") {
                        if let outcome = run.outcome { Text(outcome) }
                        if let closed = run.closedReason { Text("Picker closed: \(closed)").foregroundStyle(.secondary) }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(item: $testEditor) { request in EvalCaseEditor(request: request) { testEditor = nil } }
    }

    private func makeTest() -> EditorRequest {
        EvalCaseStore.shared.reload()
        return EditorRequest.from(run: run)
    }

    private func section<Content: View>(_ title: String, detail: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            content()
        }
    }
}
