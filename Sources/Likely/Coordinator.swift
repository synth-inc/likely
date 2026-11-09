import AppKit
import ApplicationServices

/// Detects pickers opening and closing, and runs the screenshot → claude → ~/Likely pipeline.
final class Coordinator {
    struct Picker {
        let pid: pid_t
        let appName: String
        var element: AXUIElement?
        var cgWindowID: CGWindowID?
        var frame: CGRect?
        var buttonTitle: String?
        let source: String
        /// Title of the window behind the picker, read via Accessibility (no Screen Recording needed).
        var windowTitle: String?
    }

    /// Automatic suggestions need screenshots; without them Likely waits for the user to type.
    private var autoMode = true

    enum State { case idle, searching, done }

    var onStateChange: ((State, String) -> Void)?
    var paused = false
    /// Whether Likely may search. Without a license, pickers still get the bar, but in its unpaid state:
    /// no agent, no copies, no jumping to the Likely folder.
    var isLicensed: () -> Bool = { true }
    /// "Get Likely" in the unpaid bar.
    var onGetLikely: (() -> Void)?
    /// Opens the test editor for a run ("Save as test" in the bar, once the picker has closed).
    var onMakeTest: ((DebugRun) -> Void)?
    var verbose = false {
        didSet {
            axWatcher.verbose = verbose
            windowWatcher.verbose = verbose
        }
    }

    let supportDirectory: URL
    private let axWatcher = AXWatcher()
    private let windowWatcher = WindowListWatcher()
    private let snapshotter = PrePickerSnapshotter()
    private var runner: AgentRunner = ClaudeRunner()
    private var agentName = "Claude Code"
    private let folder: LikelyFolder
    private var active: Picker?
    private var closeTimer: Timer?
    /// Removes the last picker's copies once they've been kept long enough (see LikelyFolder.release).
    private var cleanupTimer: Timer?
    private var seenOnScreen = false
    private var missedPolls = 0
    private var foundCount = 0
    private var generation = 0
    private var debugRun: DebugRun?
    private let hud = PickerHUD()
    /// Kept so feedback can restart Claude with full context if its process has died.
    private var lastPrompt: String?
    private var lastImage: URL?
    /// Feedback typed before Claude was launched (the screenshot step takes a moment).
    private var pendingFeedback: [String] = []
    /// Everything the user typed in the bar for this picker, and the screenshot taken for it: the
    /// makings of an eval case if the user then picks a file (see EvalCapture).
    private var typedQueries: [String] = []
    private var capturedScreenshot: URL?
    private let pickTracker = PickTracker()
    /// "Save as test" was clicked in the bar for this picker.
    private var saveTestRequested = false

    init() {
        supportDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Likely", isDirectory: true)
        try? FileManager.default.createDirectory(at: supportDirectory.appendingPathComponent("run"), withIntermediateDirectories: true)
        folder = LikelyFolder(supportDirectory: supportDirectory)

        axWatcher.onEvent = { [weak self] pid, notification, element in
            self?.handleAXEvent(pid: pid, notification: notification, element: element)
        }
        windowWatcher.onPanelServiceWindow = { [weak self] window in
            self?.handlePanelServiceWindow(window)
        }
        bindRunner()
        hud.model.onSend = { [weak self] text in self?.sendFeedback(text) }
        hud.model.onRejectAll = { [weak self] in self?.sendFeedback(nil) }
        hud.model.onGetLikely = { [weak self] in self?.onGetLikely?() }
        hud.model.onSaveAsTest = { [weak self] in self?.requestSaveAsTest() }
        if let remaining = folder.remainingKeepTime { scheduleCleanup(after: remaining) }
        // No click-time snapshots at all unless the user opted into screenshots.
        snapshotter.isSuspended = { [weak self] in
            self?.paused == true || self?.active != nil || !Settings.autoSuggest || !CGPreflightScreenCaptureAccess()
                || self?.isLicensed() != true
        }
    }

    private func bindRunner() {
        runner.onStatus = { [weak self] status in
            self?.folder.setStatus(status)
            self?.debugRun?.log(status)
            self?.hud.model.status = status
            self?.hud.model.working = true
            self?.onStateChange?(.searching, status)
        }
        runner.onFile = { [weak self] path in
            guard let self else { return }
            // Copies run in the background; the count goes up once each copy is in place.
            self.folder.add(path: path) { [weak self] added in
                guard let self else { return }
                self.debugRun?.files.append((path: path, added: added))
                if added {
                    self.foundCount += 1
                    self.hud.model.fileCount = self.foundCount
                }
            }
        }
        runner.onTurnFinished = { [weak self] outcome in self?.runFinished(outcome) }
        runner.onExit = { [weak self] outcome in
            guard let self, self.active != nil, self.hud.model.working else { return }
            self.runFinished(outcome)
        }
    }

    func start() {
        axWatcher.start()
        windowWatcher.start()
        snapshotter.start()
    }

    func stop() {
        pickerClosed(reason: "app quitting")
        axWatcher.stop()
        windowWatcher.stop()
        snapshotter.stop()
    }

    /// At quit: copies from a picker that closed within `keepAfterClose` stay (the app may still be
    /// reading them) and are removed at the next launch or picker; older ones go now.
    func quit() {
        stop()
        cleanupTimer?.invalidate()
        folder.finishCopies()
        folder.clearIfExpired()
        HermesRunner.stopGateway()
    }

    private func scheduleCleanup(after delay: TimeInterval) {
        cleanupTimer?.invalidate()
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: delay + 1, repeats: false) { [weak self] _ in
            guard let self, self.active == nil else { return }
            if self.folder.clearIfExpired() { Log.write("likely", "removed the last picker's copies") }
        }
    }

    // MARK: Detection

    private static let windowEvents: Set<String> = [
        kAXWindowCreatedNotification, kAXSheetCreatedNotification, kAXFocusedWindowChangedNotification,
        kAXMainWindowChangedNotification,
    ]

    private func handleAXEvent(pid: pid_t, notification: String, element: AXUIElement) {
        if notification == kAXUIElementDestroyedNotification, let picker = active?.element, CFEqual(picker, element) {
            pickerClosed(reason: "AXUIElementDestroyed")
            return
        }
        guard Self.windowEvents.contains(notification), !paused else { return }

        var window = element
        if AX.string(element, kAXRoleAttribute) == kAXApplicationRole {
            guard let focused = AX.element(element, kAXFocusedWindowAttribute) else { return }
            window = focused
        }
        let created = notification == kAXWindowCreatedNotification || notification == kAXSheetCreatedNotification
        consider(window: window, pid: pid, via: notification, retries: created ? 3 : 0)
    }

    private func consider(window: AXUIElement, pid: pid_t, via notification: String, retries: Int) {
        if let current = active?.element, CFEqual(current, window) { return }
        // One picker surfaces as several windows (app host + panel service dialog) and several events.
        if let active, active.pid == pid, let frame = active.frame, let candidate = AX.frame(window),
           candidate.roughlyEquals(frame) { return }
        let verdict = PickerHeuristics.evaluate(window)
        let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
        Log.write("detect", "\(appName) \(notification) \(AX.describe(window)) → \(verdict)")

        if verdict.isPicker {
            PickerHeuristics.logDiagnostics(window)
            let picker = Picker(pid: pid, appName: appName, element: window, cgWindowID: nil,
                                frame: AX.frame(window), buttonTitle: verdict.buttonTitle, source: "ax:\(notification)",
                                windowTitle: Self.titleBehindPicker(pid: pid, picker: window))
            pickerOpened(picker)
            axWatcher.watchDestruction(of: window)
        } else if retries > 0 {
            // Panels are often populated a beat after the window is created.
            let delay = [1.0, 0.4, 0.15][min(retries - 1, 2)]
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard AX.isAlive(window) else { return }
                self?.consider(window: window, pid: pid, via: notification + " (retry)", retries: retries - 1)
            }
        }
    }

    private func handlePanelServiceWindow(_ window: WindowInfo) {
        guard !paused, window.bounds.width > 300, window.bounds.height > 200,
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        if let active, active.pid == app.processIdentifier {
            // Same picker the AX path already found; just remember its window.
            if self.active?.cgWindowID == nil { self.active?.cgWindowID = window.id }
            return
        }
        let picker = Picker(pid: app.processIdentifier, appName: app.localizedName ?? "?", element: nil,
                            cgWindowID: window.id, frame: window.bounds, buttonTitle: nil, source: "cg:panel-service",
                            windowTitle: Self.titleBehindPicker(pid: app.processIdentifier, picker: nil))
        Log.write("detect", "panel service window #\(window.id) while \(picker.appName) is frontmost")
        pickerOpened(picker)
    }

    // MARK: Lifecycle

    private func pickerOpened(_ picker: Picker) {
        if active != nil { pickerClosed(reason: "replaced by a new picker") }
        active = picker
        generation += 1
        foundCount = 0
        seenOnScreen = false
        missedPolls = 0
        lastPrompt = nil
        pendingFeedback = []
        typedQueries = []
        capturedScreenshot = nil
        saveTestRequested = false
        autoMode = Settings.autoSuggest && CGPreflightScreenCaptureAccess()
        Log.write("picker", "OPENED in \(picker.appName) via \(picker.source) frame=\(picker.frame.map { "\($0)" } ?? "?")")

        // The previous picker's copies were kept for its app; a new picker replaces them.
        cleanupTimer?.invalidate()
        cleanupTimer = nil
        folder.clear()
        closeTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in self?.pollForClose() }

        guard isLicensed() else {
            // Unpaid: the bar explains and offers the license page; nothing is searched or copied.
            Log.write("picker", "license inactive, showing the unpaid bar")
            debugRun = nil
            hud.show(attachedTo: picker.element, fallbackFrame: picker.frame)
            hud.model.mode = .unpaid
            onStateChange?(.idle, "Inactive · Get Likely")
            return
        }

        folder.setStatus(autoMode ? "Looking at the context" : "Type what you're looking for above the picker")
        let debugRun = DebugStore.shared.begin(appName: picker.appName, detectedVia: picker.source)
        self.debugRun = debugRun
        debugRun.windowTitle = picker.windowTitle
        debugRun.buttonTitle = picker.buttonTitle
        debugRun.log("Picker opened")
        if EvalCapture.isEnabled { pickTracker.begin(window: picker.element, pid: picker.pid) }
        if Settings.openToLikely, let window = picker.element {
            let generation = generation
            PickerNavigator.selectLikelyInSidebar(of: window) { [weak self] in self?.generation == generation && self?.active != nil }
        }
        hud.show(attachedTo: picker.element, fallbackFrame: picker.frame)

        guard autoMode else {
            // Input-first: nothing runs until the user describes the file in the bar.
            hud.model.status = ""   // the empty field and its placeholder say it
            hud.model.working = false
            onStateChange?(.idle, "Waiting for a description")
            debugRun.log("Waiting for a description (screenshots off), window title: \(picker.windowTitle ?? "-")")
            return
        }
        onStateChange?(.searching, "Looking at the context")

        let generation = generation
        let screenshotURL = supportDirectory.appendingPathComponent("run/context.png")
        Task { @MainActor [weak self] in
            guard let self else { return }
            var capture: WindowCapture.Result?
            do {
                if let snapshot = await self.snapshotter.awaitSnapshot(for: picker.pid) {
                    capture = try WindowCapture.save(snapshot, to: screenshotURL)
                } else {
                    capture = try await WindowCapture.captureNow(pid: picker.pid, pickerFrame: picker.frame, to: screenshotURL)
                }
                Log.write("capture", "\(capture!.mode) title=\(capture!.windowTitle ?? "-")")
                self.capturedScreenshot = screenshotURL
                if let title = capture?.windowTitle { debugRun.windowTitle = title }
                DebugStore.shared.attachScreenshot(screenshotURL, mode: capture!.mode, to: debugRun)
                debugRun.log("Screenshot: \(capture!.mode)")
            } catch {
                Log.write("capture", "screenshot failed: \(error)")
                debugRun.captureMode = "failed: \(error)"
                debugRun.log("Screenshot failed: \(error)")
            }
            guard self.generation == generation, self.active != nil else { return }
            self.launchAgent(picker: picker, capture: capture)
        }
    }

    private func pickerClosed(reason: String) {
        guard let picker = active else { return }
        active = nil
        closeTimer?.invalidate()
        closeTimer = nil
        hud.hide()
        if runner.isBusy { debugRun?.log("Picker closed, \(agentName) cancelled") }
        runner.cancel()
        recordDraftIfPicked(picker, reason: reason)
        // Keep the copies: the app that opened the picker often reads the file after it closes
        // (browsers upload it, Mail attaches it). They go when the next picker opens or after a while.
        folder.release()
        if let remaining = folder.remainingKeepTime { scheduleCleanup(after: remaining) }
        debugRun?.closedReason = reason
        Log.write("picker", "CLOSED in \(picker.appName) (\(reason))")
        onStateChange?(.idle, isLicensed() ? "Watching for file pickers" : "Inactive · Get Likely")
    }

    /// AX destruction notifications aren't reliable (apps often reuse NSOpenPanel instead of destroying it),
    /// so also poll: the picker is closed once its frame no longer matches any on-screen window.
    private func pollForClose() {
        guard let picker = active else { return }
        pickTracker.poll()
        if let element = picker.element, !AX.isAlive(element) {
            pickerClosed(reason: "element gone")
            return
        }
        let frame = picker.element.flatMap(AX.frame) ?? picker.frame
        let windows = WindowInfo.onScreen()
        let visible: Bool
        if let id = picker.cgWindowID, picker.element == nil {
            visible = windows.contains { $0.id == id }
        } else if let frame {
            visible = windows.contains { ($0.pid == picker.pid || WindowListWatcher.isPanelService($0.pid)) && $0.bounds.roughlyEquals(frame) }
        } else {
            visible = true
        }
        if visible {
            seenOnScreen = true
            missedPolls = 0
        } else if seenOnScreen {
            missedPolls += 1
            if missedPolls >= 2 { pickerClosed(reason: "no longer on screen") }
        }
    }

    /// Evals: if the picker was confirmed (not cancelled), save what the user typed and what they
    /// actually picked as a draft test case. Off unless EvalCapture is enabled.
    private func recordDraftIfPicked(_ picker: Picker, reason: String) {
        let saveRequested = saveTestRequested
        saveTestRequested = false
        guard reason != "app quitting" else {
            pickTracker.end()
            return
        }
        var picked: [String] = []
        var how = "pick not tracked"
        if pickTracker.isTracking {
            let pick = pickTracker.end()
            how = pick.how
            if pick.confirmed {
                // Copies in the Likely folder stand for their originals.
                picked = pick.urls.map { folder.sourcePath(forPicked: $0) ?? $0.path }
                debugRun?.pickedPaths = picked
                debugRun?.log("Picked: \(picked.isEmpty ? "unknown" : picked.joined(separator: ", ")) (\(pick.how))")
            }
            if !pick.confirmed { Log.write("evals", "picker closed without a confirmed pick (\(pick.how))") }
        }
        if saveRequested, let run = debugRun {
            // Opened after the picker is gone, so it never competes with the picker for focus or selection.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.onMakeTest?(run) }
            return
        }
        guard EvalCapture.isEnabled, isLicensed(), how.hasPrefix("confirmed") else { return }
        EvalCapture.saveCaptured(app: picker.appName, windowTitle: debugRun?.windowTitle ?? picker.windowTitle,
                                 button: picker.buttonTitle, queries: typedQueries,
                                 screenshot: autoMode ? capturedScreenshot : nil, picked: picked, how: how,
                                 suggested: debugRun?.files.filter(\.added).map(\.path) ?? [])
    }

    /// "Save as test" in the bar: remember it, and start reading the picker's selection so the
    /// editor can open with the user's pick as the expected answer.
    private func requestSaveAsTest() {
        guard let picker = active, debugRun != nil else { return }
        saveTestRequested = true
        hud.model.saveRequested = true
        if !pickTracker.isTracking { pickTracker.begin(window: picker.element, pid: picker.pid) }
        pickTracker.poll()
    }

    /// For a sheet, its parent window; otherwise the app's first normal window that isn't the picker.
    static func titleBehindPicker(pid: pid_t, picker: AXUIElement?) -> String? {
        if let picker, AX.string(picker, kAXRoleAttribute) == kAXSheetRole,
           let parent = AX.element(picker, kAXParentAttribute), let title = AX.string(parent, kAXTitleAttribute), !title.isEmpty {
            return title
        }
        for window in AX.elements(AXUIElementCreateApplication(pid), kAXWindowsAttribute) {
            if let picker, CFEqual(window, picker) { continue }
            if PickerHeuristics.openPanelIdentifiers.contains(AX.string(window, kAXIdentifierAttribute) ?? "") { continue }
            if let title = AX.string(window, kAXTitleAttribute), !title.isEmpty, title != "Open" { return title }
        }
        return nil
    }

    // MARK: Agent

    private struct AgentChoice {
        let kind: AgentKind
        let path: String
        let model: String
        /// Everything except Claude Code gets the screenshot attached rather than reading it from disk.
        var takesImages: Bool { kind.id != "claude" }
    }

    /// The agent picked in onboarding/Settings, if it's installed.
    private func chosenAgent() -> AgentChoice? {
        let kind = AgentKind.with(id: Settings.agentID).flatMap { $0.isSupported ? $0 : nil } ?? AgentKind.all[0]
        let path = kind.id == "claude" ? ClaudeLocator.path ?? AgentDetector.shared.path(for: kind) : AgentDetector.shared.path(for: kind)
        guard let path else { return nil }
        return AgentChoice(kind: kind, path: path, model: AgentModels.selected(for: kind.id))
    }

    private var runnerAgentID = "claude"

    /// Swaps the runner when the chosen agent changed since the last picker.
    private func prepareRunner(for agent: AgentChoice) {
        if agent.kind.id != runnerAgentID {
            runner.cancel()
            runner = AgentModels.makeRunner(for: agent.kind.id)
            runnerAgentID = agent.kind.id
            bindRunner()
        }
        agentName = agent.kind.name
    }

    private func launchAgent(picker: Picker, capture: WindowCapture.Result?) {
        guard let agent = chosenAgent() else {
            let name = AgentKind.with(id: Settings.agentID)?.name ?? "Your agent"
            folder.setStatus("\(name) not found – see Likely settings")
            debugRun?.outcome = "\(name) not found"
            onStateChange?(.done, "\(name) not found")
            return
        }
        prepareRunner(for: agent)
        let base = Self.prompt(picker: picker, capture: capture, imageAttached: agent.takesImages)
        lastPrompt = base
        lastImage = agent.takesImages ? capture?.url : nil
        let prompt = PromptBuilder.withTyped(base, typed: pendingFeedback, autoMode: autoMode)
        pendingFeedback = []
        debugRun?.prompt = prompt
        debugRun?.model = "\(agent.kind.name) · \(agent.model)"
        debugRun?.log("\(agent.kind.name) started")
        runner.start(executable: agent.path, model: agent.model, prompt: prompt, image: lastImage,
                     workDir: supportDirectory.appendingPathComponent("run"))
    }

    private func runFinished(_ outcome: AgentOutcome) {
        guard active != nil else { return }
        let message: String
        if !outcome.success {
            message = "\(agentName) error – \(outcome.summary.prefix(60))"
        } else if foundCount == 0 {
            message = "Done – nothing likely found"
        } else {
            message = "Done – found \(foundCount) file\(foundCount == 1 ? "" : "s")"
        }
        Log.write("agent", "\(message) cost=\(outcome.costUSD.map { String(format: "$%.4f", $0) } ?? "?")")
        // Done: drop the status file so only real suggestions are left in the folder.
        folder.removeStatus()
        debugRun?.outcome = message + (outcome.costUSD.map { String(format: " · $%.4f", $0) } ?? "")
        debugRun?.log(message)
        hud.model.working = false
        hud.model.status = !outcome.success ? message
            : foundCount == 0 ? "Nothing found. Tell Likely more."
            : "\(foundCount) suggestion\(foundCount == 1 ? "" : "s") in \(LikelyFolder.url.lastPathComponent)"
        onStateChange?(.done, message)
    }

    /// User feedback from the HUD. `nil` means "Not these" with no further detail.
    /// The current suggestions are removed and Claude is told not to repeat them.
    private func sendFeedback(_ text: String?) {
        guard let picker = active, isLicensed() else { return }
        if !autoMode, lastPrompt == nil, let text {
            // First description in input-first mode: this starts the search.
            pendingFeedback = [text]
            typedQueries.append(text)
            debugRun?.queries.append(text)
            debugRun?.log("You: \(text)")
            Log.write("feedback", "request: \(text)")
            folder.setStatus("Looking for \(text)")
            hud.model.status = "Looking for \"\(text)\""
            hud.model.working = true
            onStateChange?(.searching, "Searching")
            launchAgent(picker: picker, capture: nil)
            return
        }
        let rejected = folder.suggestedSources
        folder.clearSuggestions()
        foundCount = 0
        hud.model.fileCount = 0
        if let text {
            typedQueries.append(text)
            debugRun?.queries.append(text)
        }

        let message = PromptBuilder.followUp(text, rejected: rejected)

        debugRun?.log("You: \(text ?? "Not these")")
        Log.write("feedback", text ?? "Not these")
        let status = text == nil ? "Trying a different approach" : "Got it, searching again"
        folder.setStatus(status)
        hud.model.status = status
        hud.model.working = true
        onStateChange?(.searching, status)

        if runner.send(message) { return }
        if let lastPrompt, let agent = chosenAgent() {
            // The agent's conversation is gone (crashed or never started); start over with the feedback attached.
            prepareRunner(for: agent)
            runner.start(executable: agent.path, model: agent.model, prompt: lastPrompt + "\n\n" + message, image: lastImage,
                         workDir: supportDirectory.appendingPathComponent("run"))
        } else {
            // Still taking the screenshot; launchAgent will include it.
            pendingFeedback.append(text ?? "None of the obvious candidates.")
        }
    }

    static func prompt(picker: Picker, capture: WindowCapture.Result?, imageAttached: Bool = false) -> String {
        PromptBuilder.initial(PromptBuilder.Context(appName: picker.appName, windowTitle: capture?.windowTitle ?? picker.windowTitle,
                                                    buttonTitle: picker.buttonTitle, screenshot: capture?.url),
                              imageAttached: imageAttached)
    }
}

/// Builds the messages sent to the agent. Shared by the picker flow (Coordinator) and the headless
/// eval runner (EvalCLI), so evals measure exactly the prompt users get.
enum PromptBuilder {
    struct Context {
        var appName: String
        var windowTitle: String?
        var buttonTitle: String?
        /// The screenshot of the window behind the picker, if there is one.
        var screenshot: URL?
    }

    /// The first message: the prompt template filled in for this picker.
    static func initial(_ c: Context, imageAttached: Bool, template: String = Settings.promptTemplate) -> String {
        var context = "The user just opened a file picker (Open dialog) in \(c.appName)."
        if let title = c.windowTitle, !title.isEmpty { context += " The window behind it is titled \"\(title)\"." }
        if let button = c.buttonTitle { context += " The picker's confirm button says \"\(button)\"." }
        let screenshot = c.screenshot.map { url in
            imageAttached
                ? "A screenshot of what they were looking at (picker excluded) is attached. Look at it first."
                : "A screenshot of what they were looking at (picker excluded) is at \(url.path). Read it first."
        }
            ?? "No screenshot is available; work from the app name, window title and what the user says."
        return PromptTemplate.render(template, values: [
            "context": context,
            "screenshot": screenshot,
            "app": c.appName,
            "windowTitle": c.windowTitle ?? "",
            "likelyFolder": LikelyFolder.url.path,
            "searchFolders": SearchFolder.promptDescription,
        ])
    }

    /// What the user typed before the agent started: their description (input-first mode), or
    /// additions typed while the screenshot was being taken (automatic mode).
    static func withTyped(_ prompt: String, typed: [String], autoMode: Bool) -> String {
        guard !typed.isEmpty else { return prompt }
        let lead = autoMode ? "The user already added:" : "The user described what they're looking for:"
        return prompt + "\n\n\(lead) " + typed.map { "\"\($0)\"" }.joined(separator: " ")
    }

    /// Feedback typed after suggestions came in (`nil`: "Not these"). The current suggestions count as rejected.
    static func followUp(_ text: String?, rejected: [String]) -> String {
        var message = text.map { "The user typed: \"\($0)\"." } ?? "The user says none of your suggestions are what they want."
        if !rejected.isEmpty {
            message += " They rejected these, so don't suggest them again: " + rejected.joined(separator: ", ") + "."
        }
        message += " Search again with this in mind. Same protocol: STATUS lines as you work, FILE lines as soon as you find candidates."
        return message
    }
}

/// The instructions sent to the agent, editable in Settings. `{{name}}` placeholders are filled per picker.
enum PromptTemplate {
    static let placeholders: [(name: String, meaning: String)] = [
        ("context", "Sentence(s) about the app, window title and picker button"),
        ("screenshot", "Where the screenshot is, or a note that there isn't one"),
        ("app", "Name of the app that opened the picker"),
        ("windowTitle", "Title of the window behind the picker"),
        ("likelyFolder", "Path of your Likely folder"),
        ("searchFolders", "Folders to search (built-in, cloud, and ones you added)"),
    ]

    static let `default` = """
    {{context}}
    {{screenshot}}

    Your job: figure out which file(s) on this Mac they most likely want to pick, and find them fast. The user is waiting with the picker open.

    Output protocol (an app parses your text; nothing else you write is shown):
    - Before each step, write a line `STATUS: <what you're doing, under 8 words>`, e.g. `STATUS: Looking at the context`, `STATUS: Searching Documents for app icons`, `STATUS: Checking recent downloads`.
    - The moment you find a strong candidate, write a line `FILE: /absolute/path/to/file`. Don't wait until the end. Best first, at most 8 total. Files that exist, or a whole folder (its path) when the user asks for a folder.
    - Aim for 3–6 tool calls, then stop.

    Search tips:
    - Spotlight: `mdfind -onlyin ~ 'kMDItemDisplayName == "*invoice*"cd'`, full text `mdfind -onlyin ~/Documents "quarterly report"`, by source site `mdfind 'kMDItemWhereFroms == "*example.com*"'`, by type `mdfind -onlyin ~ 'kMDItemContentTypeTree == "public.image" && kMDItemFSContentChangeDate >= $time.today(-7)'`.
    - Recency: `ls -lt ~/Downloads ~/Desktop ~/Documents | head -40`.
    - Where to look: {{searchFolders}}. Folders the user added are good bets. Elsewhere in ~ is fine too.
    - Hidden or app-specific folders only if the obvious places come up empty.
    - Ignore {{likelyFolder}} itself. Never modify anything.
    """

    static func render(_ template: String, values: [String: String]) -> String {
        values.reduce(template) { $0.replacingOccurrences(of: "{{\($1.key)}}", with: $1.value) }
    }
}

/// Per-agent runner construction and model choice.
enum AgentModels {
    static func makeRunner(for agentID: String) -> AgentRunner {
        switch agentID {
        case "codex": return CodexRunner()
        case "gemini": return GeminiRunner()
        case "opencode": return OpenCodeRunner()
        case "hermes": return HermesRunner()
        default: return ClaudeRunner()
        }
    }

    static func available(for agentID: String) -> [String] {
        switch agentID {
        case "claude": return ["haiku", "sonnet", "opus"]
        case "codex": return CodexRunner.availableModels
        case "gemini": return GeminiRunner.availableModels
        case "opencode": return OpenCodeRunner.availableModels
        case "hermes": return HermesRunner.availableModels
        default: return []
        }
    }

    static func defaultModel(for agentID: String) -> String {
        switch agentID {
        case "claude": return "sonnet"
        case "codex": return "gpt-5.6-luna"
        case "gemini": return GeminiRunner.defaultModel
        case "opencode": return OpenCodeRunner.defaultModel
        case "hermes": return HermesRunner.defaultModel
        default: return ""
        }
    }

    /// UserDefaults key (Claude and Codex keep their original keys).
    static func key(for agentID: String) -> String {
        switch agentID {
        case "claude": return "model"
        case "codex": return "codexModel"
        default: return "model.\(agentID)"
        }
    }

    static func selected(for agentID: String) -> String {
        UserDefaults.standard.string(forKey: key(for: agentID)) ?? defaultModel(for: agentID)
    }
}

enum Settings {
    static var model: String {
        get { UserDefaults.standard.string(forKey: "model") ?? "sonnet" }
        set { UserDefaults.standard.set(newValue, forKey: "model") }
    }
    static var verbose: Bool {
        get { UserDefaults.standard.bool(forKey: "verbose") }
        set { UserDefaults.standard.set(newValue, forKey: "verbose") }
    }
    static var openToLikely: Bool {
        get { UserDefaults.standard.object(forKey: "openToLikely") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "openToLikely") }
    }
    static var onboarded: Bool {
        // New key for the OnboardingKit flow, so people who saw the old setup window see it once.
        get { UserDefaults.standard.bool(forKey: "onboardingCompleted") }
        set { UserDefaults.standard.set(newValue, forKey: "onboardingCompleted") }
    }
    /// Folders the user added with "Add Folder…" (paths).
    static var extraSearchFolders: [String] {
        get { UserDefaults.standard.stringArray(forKey: "extraSearchFolders") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "extraSearchFolders") }
    }
    /// Suggest files as soon as a picker opens. Only takes effect with the Screenshots permission.
    static var autoSuggest: Bool {
        get { UserDefaults.standard.object(forKey: "autoSuggest") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoSuggest") }
    }
    static var codexModel: String {
        get { UserDefaults.standard.string(forKey: "codexModel") ?? "gpt-5.6-luna" }
        set { UserDefaults.standard.set(newValue, forKey: "codexModel") }
    }
    static var agentID: String {
        get { UserDefaults.standard.string(forKey: "agentID") ?? "claude" }
        set { UserDefaults.standard.set(newValue, forKey: "agentID") }
    }
    /// The user's edited prompt, or the default.
    static var promptTemplate: String {
        get { UserDefaults.standard.string(forKey: "promptTemplate") ?? PromptTemplate.default }
        set {
            if newValue == PromptTemplate.default { UserDefaults.standard.removeObject(forKey: "promptTemplate") }
            else { UserDefaults.standard.set(newValue, forKey: "promptTemplate") }
        }
    }
}

/// Finds the `claude` binary. GUI apps don't inherit the shell's PATH, so check common install
/// locations, then ask an interactive login shell (which loads nvm etc.) in the background.
enum ClaudeLocator {
    private(set) static var path: String?

    /// Cheap checks run right away; the login-shell lookup (slow, and a broken ~/.zshrc can hang it)
    /// runs off the main thread with a timeout and calls `completion` on the main thread.
    static func resolve(completion: (() -> Void)? = nil) {
        if let saved = UserDefaults.standard.string(forKey: "claudePath"), FileManager.default.isExecutableFile(atPath: saved) {
            path = saved
            completion?()
            return
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        if let found = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) {
            path = found
            completion?()
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let output = LoginShell.run("command -v claude") ?? ""
            let found = output.split(whereSeparator: \.isNewline).map(String.init)
                .last(where: { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) })
            DispatchQueue.main.async {
                if let found {
                    path = found
                    UserDefaults.standard.set(found, forKey: "claudePath")
                }
                Log.write("claude", "shell lookup: \(found ?? "not found")")
                completion?()
            }
        }
    }
}

/// Runs a script in an interactive login zsh (to get the user's PATH: nvm, Homebrew, …). Blocking:
/// call off the main thread. Gives up after `timeout` seconds (a slow or interactive ~/.zshrc).
enum LoginShell {
    static func run(_ script: String, timeout: TimeInterval = 5) -> String? {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-lic", script]
        let out = Pipe()
        shell.standardOutput = out
        shell.standardError = FileHandle.nullDevice
        shell.standardInput = FileHandle.nullDevice
        // Collect output as it comes: a background job the rc files start can keep the pipe open
        // after zsh exits, so reading to EOF could block forever.
        let lock = NSLock()
        var data = Data()
        out.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            lock.lock(); data.append(chunk); lock.unlock()
        }
        let done = DispatchSemaphore(value: 0)
        shell.terminationHandler = { _ in done.signal() }
        do {
            try shell.run()
        } catch {
            out.fileHandleForReading.readabilityHandler = nil
            Log.write("shell", "login shell failed: \(error)")
            return nil
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            Log.write("shell", "login shell timed out after \(Int(timeout))s")
            shell.terminate()
            kill(-shell.processIdentifier, SIGKILL)
            kill(shell.processIdentifier, SIGKILL)
            out.fileHandleForReading.readabilityHandler = nil
            return nil
        }
        // Let the last buffered output arrive.
        Thread.sleep(forTimeInterval: 0.05)
        out.fileHandleForReading.readabilityHandler = nil
        lock.lock(); defer { lock.unlock() }
        return String(data: data, encoding: .utf8)
    }
}
