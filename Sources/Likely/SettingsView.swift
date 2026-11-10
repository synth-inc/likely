import AppKit
import LikelyStorage
import LikelyTools
import OnboardingKit
import SwiftUI

struct SettingsActions {
    var showOnboarding: () -> Void
    /// Onboarding, opened on the license page.
    var showLicense: () -> Void
    var showDebugView: () -> Void
    var logDetailsChanged: (Bool) -> Void
}

/// The selected Settings tab, so the menu bar can open Settings on a given tab.
final class SettingsNavigation: ObservableObject {
    enum Tab: Hashable { case general, agent, prompt, tools, permissions, history, evals, debug }
    static let shared = SettingsNavigation()
    @Published var tab: Tab = .general
}

struct SettingsView: View {
    let actions: SettingsActions
    @ObservedObject private var navigation = SettingsNavigation.shared

    var body: some View {
        TabView(selection: $navigation.tab) {
            GeneralSettings(actions: actions).tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsNavigation.Tab.general)
            AgentSettings().tabItem { Label("Agent", systemImage: "sparkle.magnifyingglass") }.tag(SettingsNavigation.Tab.agent)
            PromptSettings().tabItem { Label("Prompt", systemImage: "text.alignleft") }.tag(SettingsNavigation.Tab.prompt)
            ToolsSettings().tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }.tag(SettingsNavigation.Tab.tools)
            PermissionSettings().tabItem { Label("Permissions", systemImage: "lock.shield") }.tag(SettingsNavigation.Tab.permissions)
            HistorySettings().tabItem { Label("History", systemImage: "clock.arrow.circlepath") }.tag(SettingsNavigation.Tab.history)
            #if LIKELY_DEV
            EvalsSettings().tabItem { Label("Evals", systemImage: "checklist") }.tag(SettingsNavigation.Tab.evals)
            #endif
            if MenuBarGlyph.isDebugEnabled {
                DebugSettings().tabItem { Label("Debug", systemImage: "ladybug") }.tag(SettingsNavigation.Tab.debug)
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
    /// LogDetailsSwitch's expiry (seconds since 1970), 0 when off.
    @AppStorage(LogDetailsSwitch.defaultsKey) private var logDetailsUntil: Double = 0
    @AppStorage("showRecentFiles") private var showRecentFiles = true
    @AppStorage("recentFileCount") private var recentFileCount = 3
    @State private var folderPath = (LikelyFolder.url.path as NSString).abbreviatingWithTildeInPath
    @State private var pinned = SidebarFavorites.contains(LikelyFolder.url)

    private var logDetailsCaption: String {
        _ = logDetailsUntil   // the stored copy: changes re-render this; the switch itself decides
        var text: String
        if let until = Log.details.expiry {
            text = "On until \(until.formatted(date: .abbreviated, time: .shortened)): the log includes what you type, window titles, file names and paths, and your agent's output, plus every accessibility event. It turns off by itself after 24 hours or when you quit Likely. Those lines go to a separate detailed log, deleted when details turn off."
        } else {
            text = "Off: the log keeps events, timings and counts, but not what you type, window titles, file names or your agent's output. Turn on to send the log with a bug report; it turns off by itself after 24 hours or when you quit Likely."
        }
        if Log.details.alwaysOn { text += " This dev build always logs details." }
        return text
    }

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
            }
            Section("When a picker opens") {
                Toggle("Jump to the Likely folder when a picker opens", isOn: $openToLikely)
                Text(openToLikely ? "The picker shows your Likely folder right away."
                     : "The picker opens where it normally would, and jumps to the Likely folder when you search.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Show recent files", isOn: $showRecentFiles)
                Stepper("Recent files: \(recentFileCount)", value: $recentFileCount, in: Settings.recentFileCountRange)
                    .disabled(!showRecentFiles)
                Text("Your newest downloads, screenshots and saved files, ready in the Likely folder under …Recent…. Likely searches with your agent when you type in the bar above the picker.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if Updater.isEnabled { UpdatesSection() }
            Section("Troubleshooting") {
                Toggle("Log details for troubleshooting", isOn: Binding(
                    get: { logDetailsUntil > 0 && Log.details.isSwitchedOn },
                    set: { actions.logDetailsChanged($0) }))
                Text(logDetailsCaption).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Open Debug View") { actions.showDebugView() }
                    Button("Open Log") { NSWorkspace.shared.open(Log.fileToOpen) }
                    Button("Clear Log") { Log.clear() }
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
    @AppStorage("includeUserName") private var includeUserName = true

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
            Toggle("Include my name in searches", isOn: $includeUserName)
            Text("Sends your full name (\(NSFullUserName())) as {{userName}} so the agent can recognize your own documents. Prompts without {{userName}} never include it.")
                .font(.caption).foregroundStyle(.secondary)
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
                Divider()
                Text("Folders Likely searches").font(.headline)
                SearchFolderList(state: state)
                Divider()
                PrivateDataSection()
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

/// Settings → Permissions → Private data: macOS-protected stores the agents are kept out of unless
/// turned on here (see PrivateDataArea, PrivateDataPermission).
private struct PrivateDataSection: View {
    @ObservedObject private var tools = ToolStore.shared
    @State private var working: PrivateDataArea?
    @State private var problem: (area: PrivateDataArea, message: String)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Private data").font(.headline)
            Text("Off so searches never wander into them by surprise").font(.caption).foregroundStyle(.secondary)
            ForEach(PrivateDataArea.allCases) { area in
                HStack(alignment: .firstTextBaseline) {
                    Toggle(isOn: binding(area)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(area.title)
                            Text(area.detail + (area.needsFullDiskAccess ? " Only readable with Full Disk Access for Likely, which then applies to the search agents too." : ""))
                                .font(.caption).foregroundStyle(.secondary)
                            let users = tools.tools.filter { $0.neededAreas.contains(area) }.map(\.name)
                            if !users.isEmpty {
                                Text("Needed by \(users.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .toggleStyle(.switch)
                    .disabled(working != nil)
                    if working == area { ProgressView().controlSize(.small) }
                }
                if let problem, problem.area == area {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(problem.message).font(.caption).foregroundStyle(.orange)
                        if area.needsFullDiskAccess {
                            Button("Open Full Disk Access Settings") { NSWorkspace.shared.open(PrivateDataPermission.fullDiskAccessURL) }
                                .controlSize(.small)
                        }
                    }
                }
            }
            Text("Turning one on asks macOS for access now (Mail, Messages and Safari: macOS doesn't ask; add Likely to Full Disk Access yourself). Turning it off blocks the agents again, but the permission macOS gave stays in System Settings → Privacy & Security until you remove it there. Stores only Full Disk Access opens (call history, Keychains, cookies, iPhone backups, …) are always off.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func binding(_ area: PrivateDataArea) -> Binding<Bool> {
        Binding(get: { _ = tools.tools; return PrivateDataAccess.isAllowed(area) }, set: { on in
            problem = nil
            if on {
                working = area
                PrivateDataPermission.enable(area) { outcome in
                    working = nil
                    if case .denied(let message) = outcome { problem = (area, message) }
                }
            } else {
                PrivateDataPermission.disable(area)
            }
        })
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
    @State private var rclipInstalled = false
    @State private var settingUpPhotos = false
    /// A tool being turned on whose private data areas are still off: "<Tool> needs access to … Allow?"
    @State private var askingNeeds: CustomTool?
    @State private var needsProblem: String?
    /// The tool whose areas are being turned on (macOS may be showing its alert): its row waits.
    @State private var working: String?

    private var photoState: PhotoSearch.State { PhotoSearch.state(tools: store.tools, rclipInstalled: rclipInstalled) }

    private func detectRclip() {
        if case .found = AgentPath.resolve("rclip", in: ToolCheck.directories(agentID: agentID)) { rclipInstalled = true } else { rclipInstalled = false }
    }

    var body: some View {
        Form {
            if !store.pending.isEmpty {
                Section {
                    ApprovalBanner(pending: store.pending, approve: store.approvePending)
                }
            }
            if let needsProblem {
                Section {
                    Text(needsProblem).font(.caption).foregroundStyle(.orange)
                }
            }

            if case .configured = photoState {} else {
                Section {
                    PhotoSearchRow(installed: rclipInstalled, setUp: { settingUpPhotos = true },
                                   enable: { store.save(PhotoSearch.standardEntry) })
                }
            }

            Section {
                if let error = store.loadError {
                    Text("\(error). Using the built-in search commands only; fix the file or save a tool here (the broken file is kept as tools.invalid.json).")
                        .font(.caption).foregroundStyle(.red)
                }
                ForEach(store.issues, id: \.self) { issue in
                    Text(issue).font(.caption).foregroundStyle(.orange)
                }
                if store.tools.isEmpty {
                    Text("None yet. Add one, or ask your coding agent to set one up (below).")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.tools) { tool in
                    // A tool waiting for approval can't be switched on or have its needs allowed here: only
                    // Approve (with the full change list above) makes it usable.
                    ToolRow(tool: tool, results: testResults[tool.id],
                            waitingForApproval: store.isPending(tool),
                            unmetNeeds: store.unmetNeeds(of: tool),
                            working: working == tool.id,
                            setEnabled: { on in
                                guard !store.isPending(tool) else { return }
                                if on, !store.unmetNeeds(of: tool).isEmpty { askingNeeds = tool } else { store.setEnabled(on, id: tool.id) }
                            },
                            allow: { if !store.isPending(tool) { askingNeeds = tool } },
                            agentNote: ["codex", "hermes"].contains(agentID) && tool.isActive ? ToolPermissions.agentNotes[agentID] : nil,
                            edit: { editing = ToolDraft(tool, isNew: false) },
                            test: { testResults[tool.id] = ToolCheck.run(tool.cleanedCommands, agentID: agentID) },
                            delete: { deleting = tool })
                }
            } header: {
                HStack {
                    Text("Your tools")
                    Spacer()
                    Button("Reveal tools.json") { revealFile() }.controlSize(.small)
                    Button {
                        editing = ToolDraft(CustomTool(id: "", name: "", commands: [], instructions: ""), isNew: true)
                    } label: {
                        Label("Add Tool", systemImage: "plus")
                    }
                    .controlSize(.small)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Your agent runs these commands on its own, without asking you. Only add commands that read. Likely's checks catch mistakes; the real guarantee is the sandbox it runs the agent in, which blocks writes outside the agent's own state while tools are on.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    if let note = ToolPermissions.agentNotes[agentID] {
                        Text(note).foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }

            Section {
                ForEach(BuiltInTools.entries(for: agentID), id: \.self) { entry in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name).font(.body.monospaced())
                            if !entry.purpose.isEmpty {
                                Text(entry.purpose).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text("Always on").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Built in")
            } footer: {
                Text("What \(AgentKind.with(id: agentID)?.name ?? "your agent") can always use. These only read.")
                    .font(.caption).foregroundStyle(.secondary)
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
        .onAppear {
            store.reloadIfChanged()
            detectRclip()
        }
        .onChange(of: agentID) { _, _ in detectRclip() }
        .sheet(isPresented: $settingUpPhotos) {
            PhotoSearchSetupSheet(installed: rclipInstalled, checkAgain: detectRclip) { settingUpPhotos = false }
        }
        .sheet(item: $editing) { draft in
            ToolEditor(draft: draft, agentID: agentID) { tool in
                store.save(tool)
                testResults[tool.id] = nil
                editing = nil
            } cancel: {
                editing = nil
            }
        }
        .alert(askingNeeds.map { "\($0.name) needs access to \(Self.list(store.unmetNeeds(of: $0).map(\.phrase))). Allow?" } ?? "",
               isPresented: Binding(get: { askingNeeds != nil }, set: { if !$0 { askingNeeds = nil } })) {
            Button("Allow") {
                if let tool = askingNeeds { allowNeeds(of: tool) }
                askingNeeds = nil
            }
            Button("Cancel", role: .cancel) { askingNeeds = nil }
        } message: {
            Text(askingNeeds.map { Self.allowMessage(store.unmetNeeds(of: $0)) } ?? "")
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

    /// What Allow does, per kind of area: macOS asks for some; Mail, Messages and Safari only open with
    /// Full Disk Access, which then applies to the agents too.
    static func allowMessage(_ areas: [PrivateDataArea]) -> String {
        let asking = areas.filter { !$0.needsFullDiskAccess }
        let fullDisk = areas.filter(\.needsFullDiskAccess)
        var text = "Searches can then read there."
        if !asking.isEmpty { text += " macOS asks you too for \(list(asking.map(\.title)))." }
        if !fullDisk.isEmpty {
            text += " \(list(fullDisk.map(\.title))) can only be read with Full Disk Access for Likely, which macOS doesn't ask for: you add it in System Settings → Privacy & Security, and it applies to the search agents too."
        }
        return text + " You can turn it off again in Settings → Permissions → Private data."
    }

    static func list(_ items: [String]) -> String {
        items.count <= 1 ? items.joined() : items.dropLast().joined(separator: ", ") + " and " + items.last!
    }

    /// Turns on each area the tool needs (one macOS alert at a time), then the tool. Stops at the
    /// first area macOS refuses; the tool stays off and says why.
    private func allowNeeds(of tool: CustomTool) {
        guard !store.isPending(tool), working == nil else { return }
        needsProblem = nil
        working = tool.id
        var remaining = store.unmetNeeds(of: tool)
        func next() {
            guard let area = remaining.first else {
                working = nil
                // Never approves: a tool that became pending meanwhile stays off (see ToolStore.setEnabled).
                if !store.isPending(tool) { store.setEnabled(true, id: tool.id) }
                return
            }
            remaining.removeFirst()
            PrivateDataPermission.enable(area) { outcome in
                if case .denied(let message) = outcome {
                    working = nil
                    needsProblem = "\(tool.name) stays off: \(message)"
                } else {
                    next()
                }
            }
        }
        next()
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
    let waitingForApproval: Bool
    /// Private data areas it needs that are still off: it isn't used until they're on.
    let unmetNeeds: [PrivateDataArea]
    /// Its areas are being turned on.
    let working: Bool
    let setEnabled: (Bool) -> Void
    let allow: () -> Void
    let agentNote: String?
    let edit: () -> Void
    let test: () -> Void
    let delete: () -> Void

    var body: some View {
        let problems = tool.problems
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Toggle(isOn: Binding(get: { tool.enabled && problems.isEmpty && unmetNeeds.isEmpty },
                                     set: setEnabled)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tool.name)
                        Text(tool.cleanedCommands.isEmpty ? "No commands" : tool.cleanedCommands.joined(separator: "   "))
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .disabled(!problems.isEmpty || waitingForApproval || working)
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Test", action: test).controlSize(.small)
                Button("Edit…", action: edit).controlSize(.small)
                Button(role: .destructive, action: delete) { Image(systemName: "trash") }
                    .controlSize(.small).help("Delete")
            }
            if !problems.isEmpty {
                Text("Disabled: " + problems.joined(separator: ". "))
                    .font(.caption).foregroundStyle(.orange)
            } else if waitingForApproval {
                Text("Not used until you approve the change above").font(.caption).foregroundStyle(.orange)
            } else if tool.enabled, !unmetNeeds.isEmpty {
                HStack(spacing: 6) {
                    Text("Off: needs access to \(ToolsSettings.list(unmetNeeds.map(\.phrase))), which is off in Settings → Permissions → Private data")
                        .font(.caption).foregroundStyle(.orange)
                    Button("Allow…", action: allow).controlSize(.small).disabled(working)
                }
            }
            if !tool.neededAreas.isEmpty {
                Text("Needs access to " + ToolsSettings.list(tool.neededAreas.map(\.phrase))).font(.caption).foregroundStyle(.secondary)
            }
            if let agentNote { Text(agentNote).font(.caption).foregroundStyle(.secondary) }
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
        let directories = directories(agentID: agentID)
        return commands.map { ToolCheck(command: $0, result: AgentPath.resolve($0, in: directories)) }
    }

    /// The PATH the runner for `agentID` gives its agent.
    static func directories(agentID: String) -> [String] {
        let kind = AgentKind.with(id: agentID)
        let executable = kind.flatMap { $0.id == "claude" ? ClaudeLocator.path ?? AgentDetector.shared.path(for: $0) : AgentDetector.shared.path(for: $0) }
        return AgentPath.directories(agentExecutable: executable, inherited: ProcessInfo.processInfo.environment["PATH"])
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

/// The suggested "Photo search (rclip)" row, shown until tools.json has an rclip entry.
private struct PhotoSearchRow: View {
    let installed: Bool
    let setUp: () -> Void
    let enable: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            if installed {
                Toggle(isOn: Binding(get: { false }, set: { if $0 { enable() } })) { label }
                    .toggleStyle(.switch)
                Spacer()
            } else {
                label
                Spacer()
                Button("Set Up…", action: setUp).controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Photo search (rclip)")
            Text(installed ? "Find photos by what's in them. rclip is installed; turn on to add it." : "Find photos by what's in them")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// How to get rclip: a prompt for the user's coding agent, which installs and indexes it and adds the entry.
private struct PhotoSearchSetupSheet: View {
    let installed: Bool
    let checkAgain: () -> Void
    let done: () -> Void
    @State private var copied = false
    private let prompt = ToolPrompts.setupPrompt(request: ToolPrompts.photoSearchRequest)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Photo search").font(.headline)
            Text("Photos have no searchable names or text, so your agent needs rclip to find them by what they show. Paste this into Claude Code, Codex or another coding agent to set it up.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(prompt)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
            .frame(height: 200)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            HStack {
                Button("Check Again", action: checkAgain)
                Text(installed ? "rclip found" : "rclip not found yet")
                    .font(.caption).foregroundStyle(installed ? .green : .secondary)
                Spacer()
                if copied { Text("Copied").font(.caption).foregroundStyle(.secondary) }
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(prompt, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                }
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 540)
    }
}

/// tools.json changed outside Likely: the changed tools wait for the user.
private struct ApprovalBanner: View {
    let pending: [ToolApproval.Pending]
    let approve: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("tools.json changed outside Likely: \(pending.map(\.tool.name).joined(separator: ", ")). Review and approve.",
                  systemImage: "exclamationmark.shield.fill")
                .foregroundStyle(.orange)
            ForEach(pending) { item in
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.isNew ? "\(item.tool.name) (new)" : item.tool.name).font(.caption.bold())
                    ForEach(item.summary, id: \.self) { line in
                        Text(line).font(.caption.monospaced())
                            .foregroundStyle(line.hasPrefix("+") ? Color.green : line.hasPrefix("-") ? Color.red : Color.secondary)
                    }
                    if item.instructionsChanged, !item.tool.instructions.isEmpty {
                        Text("Instructions: " + item.tool.instructions.prefix(240) + (item.tool.instructions.count > 240 ? "…" : ""))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(4)
                    }
                }
            }
            HStack {
                Text("Until you approve, these tools aren't used.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Approve", action: approve)
            }
        }
        .padding(.vertical, 2)
    }
}
