import AppKit
import LikelyTools
import OnboardingKit
import SwiftUI

struct SettingsActions {
    var showOnboarding: () -> Void
    /// Onboarding, opened on the license page.
    var showLicense: () -> Void
    var showDebugView: () -> Void
    var verboseChanged: (Bool) -> Void
}

struct SettingsView: View {
    let actions: SettingsActions

    var body: some View {
        TabView {
            GeneralSettings(actions: actions).tabItem { Label("General", systemImage: "gearshape") }
            AgentSettings().tabItem { Label("Agent", systemImage: "sparkle.magnifyingglass") }
            PromptSettings().tabItem { Label("Prompt", systemImage: "text.alignleft") }
            ToolsSettings().tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }
            PermissionSettings().tabItem { Label("Permissions", systemImage: "lock.shield") }
            if MenuBarGlyph.isDebugEnabled {
                DebugSettings().tabItem { Label("Debug", systemImage: "ladybug") }
            }
        }
        .padding(20)
        .frame(width: 680, height: 520)
    }
}

// MARK: - Debug (dev builds only)

/// Menu bar glyph candidates, switchable live. Only in `./build.sh` builds (LIKELY_DEV).
private struct DebugSettings: View {
    @State private var selection = MenuBarGlyph.debugSelection ?? ""

    var body: some View {
        Form {
            Section("Menu bar glyph") {
                List(selection: $selection) {
                    row(id: "", title: "Default — Resources/MenuBarGlyph.pdf")
                    ForEach(MenuBarGlyph.available) { option in row(id: option.id, title: option.title) }
                }
                .frame(minHeight: 320)
                Text("Also in the menu bar menu: Debug › Next Glyph / Previous Glyph.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: selection) { _, id in
            if (MenuBarGlyph.debugSelection ?? "") != id { MenuBarGlyph.debugSelection = id.isEmpty ? nil : id }
        }
        .onReceive(NotificationCenter.default.publisher(for: MenuBarGlyph.didChange)) { _ in
            selection = MenuBarGlyph.debugSelection ?? ""
        }
    }

    private func row(id: String, title: String) -> some View {
        HStack(spacing: 10) {
            if let image = MenuBarGlyph.baseImage(id: id.isEmpty ? nil : id) {
                Image(nsImage: image).renderingMode(.template).resizable().frame(width: 18, height: 18)
            }
            Text(title)
        }
        .tag(id)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    let actions: SettingsActions
    @AppStorage("openToLikely") private var openToLikely = true
    @AppStorage("verbose") private var verbose = false
    @AppStorage("autoSuggest") private var autoSuggest = true
    private var screenshotsAllowed: Bool { CGPreflightScreenCaptureAccess() }
    @State private var folderPath = (LikelyFolder.url.path as NSString).abbreviatingWithTildeInPath
    @State private var pinned = SidebarFavorites.contains(LikelyFolder.url)

    private func refreshFolder() {
        folderPath = (LikelyFolder.url.path as NSString).abbreviatingWithTildeInPath
        pinned = SidebarFavorites.contains(LikelyFolder.url)
    }

    var body: some View {
        Form {
            LicenseSection(actions: actions)
            Section("Likely folder") {
                HStack {
                    Image(systemName: "folder.fill").foregroundStyle(.secondary)
                    Text(folderPath).font(.system(.body, design: .monospaced))
                    Spacer()
                    Button("Change…") {
                        LikelyFolder.choose()
                        refreshFolder()
                    }
                    if LikelyFolder.url.standardizedFileURL != LikelyFolder.defaultURL.standardizedFileURL {
                        Button("Use ~/Likely") {
                            LikelyFolder.resetToDefault()
                            refreshFolder()
                        }
                    }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([LikelyFolder.url]) }
                }
                if LikelyFolder.isProtectedLocation(LikelyFolder.url) {
                    Text("This folder is protected by macOS or synced to iCloud, so suggestions may stop appearing if access is revoked. We recommend ~/Likely.")
                        .font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Text(pinned ? "In the Finder sidebar" : "Not in the Finder sidebar, so pickers can't jump to it")
                        .foregroundStyle(pinned ? Color.secondary : Color.orange)
                    Spacer()
                    if !pinned {
                        Button("Add to Sidebar") {
                            SidebarFavorites.add(LikelyFolder.url)
                            pinned = SidebarFavorites.contains(LikelyFolder.url)
                        }
                    }
                }
                Toggle("Jump file pickers to the Likely folder when they open", isOn: $openToLikely)
            }
            Section("Suggestions") {
                Toggle("Suggest files as soon as a picker opens", isOn: $autoSuggest)
                    .disabled(!screenshotsAllowed)
                Text(screenshotsAllowed
                     ? "Uses a screenshot of the app you're uploading from. Turn off to only search when you type."
                     : "Needs the optional Screenshots permission (Permissions tab). Without it, describe the file in the bar above the picker.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if Updater.isEnabled { UpdatesSection() }
            Section("Troubleshooting") {
                Toggle("Log every accessibility event (verbose)", isOn: $verbose)
                    .onChange(of: verbose) { _, value in actions.verboseChanged(value) }
                HStack {
                    Button("Open Debug View") { actions.showDebugView() }
                    Button("Open Log") { NSWorkspace.shared.open(Log.fileURL) }
                    Spacer()
                    Button("Run Onboarding Again") { actions.showOnboarding() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Updates

private struct UpdatesSection: View {
    @ObservedObject private var updater = Updater.shared

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        Section("Updates") {
            HStack {
                Text("Version \(version)")
                Spacer()
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
            Toggle("Automatically check for updates", isOn: Binding(
                get: { updater.automaticallyChecksForUpdates },
                set: { updater.automaticallyChecksForUpdates = $0 }))
            if let lastCheck = updater.lastCheck {
                Text("Last checked \(lastCheck.formatted(.relative(presentation: .named)))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - License

private struct LicenseSection: View {
    let actions: SettingsActions
    @ObservedObject private var store = LicenseStore.shared
    @State private var openingPortal = false
    @State private var portalError: String?

    var body: some View {
        Section("License") {
            HStack {
                Image(systemName: store.isActive ? "checkmark.seal.fill" : "exclamationmark.triangle")
                    .foregroundStyle(store.isActive ? Color.green : Color.orange)
                Text(store.statusText)
                Spacer()
                if !License.isFreeBuild {
                    if store.isChecking { ProgressView().controlSize(.small) }
                    if store.isSubscriber {
                        Button("Manage Subscription…", action: openPortal).disabled(openingPortal)
                    }
                    if !store.isActive {
                        Button("Buy…") { actions.showLicense() }
                    }
                    Button("Check Again") { Task { await store.refresh() } }.disabled(store.isChecking)
                }
            }
            if let message = portalError ?? store.lastError, !License.isFreeBuild {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            if let checkedAt = store.cached?.checkedAt, !License.isFreeBuild {
                Text("Last checked \(checkedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Stripe's customer portal: cancel, change card, invoices.
    private func openPortal() {
        openingPortal = true
        portalError = nil
        Task {
            defer { openingPortal = false }
            do {
                NSWorkspace.shared.open(try await store.billingPortalURL())
            } catch {
                portalError = error.localizedDescription
            }
        }
    }
}

// MARK: - Agent

private struct AgentSettings: View {
    @ObservedObject private var agents = AgentDetector.shared
    @AppStorage("agentID") private var agentID = "claude"
    @AppStorage("model") private var model = "sonnet"
    @AppStorage("codexModel") private var codexModel = "gpt-5.6-luna"
    @AppStorage("geminiVertexProject") private var geminiProject = ""
    @AppStorage("geminiVertexLocation") private var geminiLocation = "global"
    @State private var modelRefresh = 0

    var body: some View {
        Form {
            Section {
                ForEach(AgentKind.all) { kind in
                    let path = agents.path(for: kind)
                    HStack {
                        Image(systemName: agentID == kind.id ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(kind.isSupported && path != nil ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(kind.name)
                            Text(path.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Not installed")
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(!kind.isSupported ? "Coming soon" : path == nil ? "Not installed" : "Ready")
                            .font(.caption)
                            .foregroundStyle(kind.isSupported && path != nil ? .green : .secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { if kind.isSupported && path != nil { agentID = kind.id } }
                    .opacity(kind.isSupported && path != nil ? 1 : 0.55)
                }
            } header: {
                HStack {
                    Text("Coding agent")
                    Spacer()
                    if agents.isScanning { ProgressView().controlSize(.small) }
                    Button("Scan Again") { agents.scan() }.controlSize(.small)
                }
            }
            if agentID == "codex" {
                Section("Codex") {
                    Picker("Model", selection: $codexModel) {
                        ForEach(CodexRunner.availableModels, id: \.self) { Text($0).tag($0) }
                    }
                    Text("Runs in Codex's read-only sandbox, signed in with your ChatGPT account.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if ["gemini", "opencode", "hermes"].contains(agentID) {
                Section(AgentKind.with(id: agentID)?.name ?? "Agent") {
                    Picker("Model", selection: Binding(
                        get: { UserDefaults.standard.string(forKey: AgentModels.key(for: agentID)) ?? AgentModels.defaultModel(for: agentID) },
                        set: { UserDefaults.standard.set($0, forKey: AgentModels.key(for: agentID)); modelRefresh += 1 })) {
                        ForEach(AgentModels.available(for: agentID), id: \.self) { Text($0).tag($0) }
                    }
                    .id(modelRefresh)
                    if agentID == "gemini" {
                        TextField("Vertex AI project", text: $geminiProject, prompt: Text("my-gcp-project"))
                        TextField("Vertex AI location", text: $geminiLocation, prompt: Text("global"))
                        Text("Gemini runs through Vertex AI with your gcloud login, billed to this Google Cloud project.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if agentID == "opencode" {
                        Text("Uses OpenCode's free models by default; no sign-in needed. Runs inside a macOS sandbox that blocks writes.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if agentID == "claude" {
                Section("Claude Code") {
                    Picker("Model", selection: $model) {
                        Text("Haiku (fastest)").tag("haiku")
                        Text("Sonnet").tag("sonnet")
                        Text("Opus (smartest)").tag("opus")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { if agents.paths.isEmpty { agents.scan() } }
    }
}

// MARK: - Prompt

private struct PromptSettings: View {
    @State private var text = Settings.promptTemplate

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Instructions sent to your agent each time a picker opens.").foregroundStyle(.secondary)
                Spacer()
                Button("Reset to Default") { text = PromptTemplate.default }
                    .disabled(text == PromptTemplate.default)
            }
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                .onChange(of: text) { _, value in Settings.promptTemplate = value }
            VStack(alignment: .leading, spacing: 3) {
                Text("Placeholders").font(.caption.bold())
                ForEach(PromptTemplate.placeholders, id: \.name) { item in
                    Text("{{\(item.name)}}").font(.caption.monospaced()) + Text("  \(item.meaning)").font(.caption).foregroundColor(.secondary)
                }
                Text("Keep the STATUS: and FILE: lines in the protocol section; Likely relies on them.")
                    .font(.caption).foregroundStyle(.orange).padding(.top, 2)
            }
        }
    }
}

// MARK: - Permissions

private struct PermissionSettings: View {
    @StateObject private var state = SetupState()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                OnboardingPermissionRow(
                    icon: "accessibility", title: "Accessibility",
                    description: "Notices when a file picker opens and jumps it to your Likely folder.",
                    isGranted: state.accessibility, shouldPulse: false, action: Permissions.requestAccessibility)
                OnboardingPermissionRow(
                    icon: "camera.viewfinder", title: "Screenshots", badge: "Optional",
                    description: "Lets Likely send your agent a screenshot of the app you're uploading from, so it can suggest files before you type.",
                    isGranted: state.screenRecording, shouldPulse: false,
                    note: "Already allowed it?", secondaryTitle: "Quit & Reopen", secondaryAction: Permissions.relaunch,
                    action: Permissions.requestScreenRecording)
                Divider()
                Text("Folders Likely searches").font(.headline)
                SearchFolderList(state: state)
            }
            .padding(4)
        }
        .task {
            while !Task.isCancelled {
                state.refresh()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
}

// MARK: - Tools

/// Extra command-line tools for the agent, stored in tools.json (see ToolStore, docs/TOOLS.md).
private struct ToolsSettings: View {
    @ObservedObject private var store = ToolStore.shared
    @AppStorage("agentID") private var agentID = "claude"
    @State private var editing: ToolDraft?
    @State private var deleting: CustomTool?
    @State private var testResults: [String: [ToolCheck]] = [:]
    @State private var copied = false

    var body: some View {
        Form {
            Section {
                Label("Your agent runs these commands on its own, without asking you. Only add commands that read; never ones that change, move or delete files.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
                if let note = ToolPermissions.agentNotes[agentID] {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
                if let error = store.loadError {
                    Text("\(error). Using the built-in search commands only; fix the file or save a tool here (the broken file is kept as tools.invalid.json).")
                        .font(.caption).foregroundStyle(.red)
                }
                ForEach(store.issues, id: \.self) { issue in
                    Text(issue).font(.caption).foregroundStyle(.orange)
                }
                if store.tools.isEmpty {
                    Text("No tools yet. Add one, or ask your coding agent to set one up (below).")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.tools) { tool in
                    ToolRow(tool: tool, results: testResults[tool.id],
                            edit: { editing = ToolDraft(tool, isNew: false) },
                            test: { testResults[tool.id] = ToolCheck.run(tool.cleanedCommands, agentID: agentID) },
                            delete: { deleting = tool })
                }
            } header: {
                HStack {
                    Text("Tools")
                    Spacer()
                    Button("Reveal tools.json") { revealFile() }.controlSize(.small)
                    Button("Add Tool…") {
                        editing = ToolDraft(CustomTool(id: "", name: "", commands: [], instructions: ""), isNew: true)
                    }
                    .controlSize(.small)
                }
            }

            Section("Set up with your coding agent") {
                Text("Paste this into Claude Code, Codex or another coding agent and say what you want. It installs the tool, checks it works, and adds it to tools.json; Likely picks it up automatically.")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    Text(ToolPrompts.setupPrompt)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                }
                .frame(height: 160)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                HStack {
                    Spacer()
                    if copied { Text("Copied").font(.caption).foregroundStyle(.secondary) }
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(ToolPrompts.setupPrompt, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { store.reloadIfChanged() }
        .sheet(item: $editing) { draft in
            ToolEditor(draft: draft, agentID: agentID) { tool in
                store.save(tool)
                testResults[tool.id] = nil
                editing = nil
            } cancel: {
                editing = nil
            }
        }
        .alert("Delete \(deleting?.name ?? "tool")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) {
                if let deleting { store.delete(id: deleting.id) }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("It's removed from tools.json. The command-line tool itself stays installed.")
        }
    }

    private func revealFile() {
        // Nothing to select yet: create an empty list so there's a file to show and edit.
        store.createFileIfMissing()
        NSWorkspace.shared.activateFileViewerSelecting([ToolStore.fileURL])
    }
}

private struct ToolRow: View {
    let tool: CustomTool
    let results: [ToolCheck]?
    let edit: () -> Void
    let test: () -> Void
    let delete: () -> Void

    var body: some View {
        let problems = tool.problems
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Toggle(isOn: Binding(get: { tool.enabled && problems.isEmpty },
                                     set: { ToolStore.shared.setEnabled($0, id: tool.id) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tool.name)
                        Text(tool.cleanedCommands.isEmpty ? "No commands" : tool.cleanedCommands.joined(separator: "   "))
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .disabled(!problems.isEmpty)
                Spacer()
                Button("Test", action: test).controlSize(.small)
                Button("Edit…", action: edit).controlSize(.small)
                Button(role: .destructive, action: delete) { Image(systemName: "trash") }
                    .controlSize(.small).help("Delete")
            }
            if !problems.isEmpty {
                Text("Disabled: " + problems.joined(separator: ". "))
                    .font(.caption).foregroundStyle(.orange)
            }
            if let results { ToolCheckList(results: results) }
        }
        .padding(.vertical, 2)
    }
}

/// Whether a command's first word resolves on the PATH the agent gets.
struct ToolCheck: Hashable {
    let command: String
    let result: AgentPath.Resolution

    static func run(_ commands: [String], agentID: String) -> [ToolCheck] {
        let kind = AgentKind.with(id: agentID)
        let executable = kind.flatMap { $0.id == "claude" ? ClaudeLocator.path ?? AgentDetector.shared.path(for: $0) : AgentDetector.shared.path(for: $0) }
        let directories = AgentPath.directories(agentExecutable: executable, inherited: ProcessInfo.processInfo.environment["PATH"])
        return commands.map { ToolCheck(command: $0, result: AgentPath.resolve($0, in: directories)) }
    }
}

private struct ToolCheckList: View {
    let results: [ToolCheck]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if results.isEmpty { Text("No commands to test").font(.caption).foregroundStyle(.secondary) }
            ForEach(results, id: \.self) { check in
                HStack(spacing: 6) {
                    switch check.result {
                    case .found(let path):
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("\(ToolValidator.firstWord(of: check.command)): found at \((path as NSString).abbreviatingWithTildeInPath)")
                    case .builtin:
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("\(ToolValidator.firstWord(of: check.command)): shell builtin")
                    case .notFound:
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                        Text("\(ToolValidator.firstWord(of: check.command)): not found on the agent's PATH")
                    }
                }
                .font(.caption)
            }
        }
    }
}

private struct ToolDraft: Identifiable {
    let id = UUID()
    let original: CustomTool
    let isNew: Bool
    init(_ tool: CustomTool, isNew: Bool) {
        original = tool
        self.isNew = isNew
    }
}

private struct ToolEditor: View {
    let draft: ToolDraft
    let agentID: String
    let save: (CustomTool) -> Void
    let cancel: () -> Void

    @State private var name = ""
    @State private var commands = ""
    @State private var instructions = ""
    @State private var setup = ""
    @State private var results: [ToolCheck]?

    private var tool: CustomTool {
        var tool = draft.original
        tool.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        tool.commands = commands.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        tool.instructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let setup = setup.trimmingCharacters(in: .whitespacesAndNewlines)
        tool.setup = setup.isEmpty ? nil : setup
        if draft.isNew {
            tool.id = ToolStore.shared.newID(for: tool.name)
            tool.enabled = true
        }
        return tool
    }

    var body: some View {
        let problems = tool.problems
        VStack(alignment: .leading, spacing: 10) {
            Text(draft.isNew ? "Add Tool" : "Edit Tool").font(.headline)
            TextField("Name", text: $name, prompt: Text("Image search"))
            field("Commands the agent may run, one per line (matched as prefixes)", text: $commands, height: 60, monospaced: true)
            field("Instructions for the agent: when to use it, the exact command, what it prints", text: $instructions, height: 90)
            field("Setup notes (optional, not sent to the agent)", text: $setup, height: 36)
            Label("These commands run unattended. Only add read-only ones.", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
            if !problems.isEmpty, !name.isEmpty || !commands.isEmpty {
                Text(problems.joined(separator: ". ") + ". It will be saved turned off.")
                    .font(.caption).foregroundStyle(.red)
            }
            if let results { ToolCheckList(results: results) }
            HStack {
                Button("Test") { results = ToolCheck.run(tool.commands, agentID: agentID) }
                    .disabled(tool.commands.isEmpty)
                Spacer()
                Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button("Save") { save(tool) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            name = draft.original.name
            commands = draft.original.commands.joined(separator: "\n")
            instructions = draft.original.instructions
            setup = draft.original.setup ?? ""
        }
        .onChange(of: commands) { _, _ in results = nil }
    }

    private func field(_ title: String, text: Binding<String>, height: CGFloat, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: text)
                .font(monospaced ? .system(size: 12, design: .monospaced) : .system(size: 12))
                .scrollContentBackground(.hidden)
                .padding(4)
                .frame(height: height)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
        }
    }
}
