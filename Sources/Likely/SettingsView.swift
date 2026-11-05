import AppKit
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
    @AppStorage("showRecentFiles") private var showRecentFiles = true
    @AppStorage("recentFileCount") private var recentFileCount = 3
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
                    description: "Lets Likely send your agent a screenshot of the app you're uploading from, so it knows what you're uploading to when you search.",
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
