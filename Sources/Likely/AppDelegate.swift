import AppKit
import LikelyStorage
import ApplicationServices
import OnboardingKit
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let stateItem = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private let jumpItem = NSMenuItem(title: "Jump to Likely Folder When a Picker Opens", action: #selector(toggleJump), keyEquivalent: "")
    private let improveItem = NSMenuItem(title: "Improve Results…", action: #selector(showToolSettings), keyEquivalent: "")

    private let coordinator = Coordinator()
    private var debugWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var testWindow: NSWindow?
    private var trustTimer: Timer?
    private var logDetailsTimer: Timer?
    private var started = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("app", "launched, log at \(path: Log.fileURL)")
        // The login-shell part of the lookup runs in the background (it can take seconds).
        ClaudeLocator.resolve { Log.write("app", "claude: \(path: ClaudeLocator.path)") }
        buildStatusItem()
        toolApprovalChanged()   // loads tools.json; anything changed while Likely was closed shows up now
        if Settings.agentID == "codex" { PhotoLibraries.refresh() }   // for Codex's sandbox (see PhotoLibraries)
        if Updater.isEnabled { MainActor.assumeIsolated { Updater.shared.start() } }

        applyLogDetails()
        // A timer doesn't notice the clock moving: check again after sleep or a clock change.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.applyLogDetails()
        }
        NotificationCenter.default.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.applyLogDetails()
        }
        coordinator.onStateChange = { [weak self] state, message in
            self?.stateItem.title = message
            self?.setIcon(state)
        }
        // Licensing gates the search, not the watching: an unlicensed Likely still shows its bar above
        // pickers, in an unpaid state that leads to the license page.
        coordinator.isLicensed = { License.isActive }
        coordinator.onGetLikely = { [weak self] in self?.showLicense() }
        coordinator.onMakeTest = { [weak self] run in self?.showTestEditor(for: run) }

        AgentDetector.shared.scan()
        // Setup (ending with the license page) has to be finished before Likely starts watching.
        // The cached entitlement decides at launch (works offline); the server check right after can
        // still flip it through `licenseChanged`.
        if Settings.onboarded {
            startWhenTrusted()
        } else {
            stateItem.title = "Finish setup to start Likely"
            showOnboarding()
        }
        MainActor.assumeIsolated {
            LicenseStore.shared.onActiveChange = { [weak self] active in self?.licenseChanged(active: active) }
            // Waits for the welcome screen's notice on a fresh install (see `License.mayContactServer`);
            // onboarding starts it once the user continues past that screen.
            LicenseStore.shared.startPeriodicChecks()
        }
    }

    /// `likely://payment-success` (Stripe Checkout's success redirect) and any other likely:// link:
    /// re-check the license and bring the relevant window forward.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { $0.scheme == "likely" }) else { return }
        Log.write("app", "opened by \(meta: url.scheme)://\(meta: url.host)")
        Task { @MainActor in
            // Not past the welcome notice yet: show it rather than skipping ahead to the license page.
            guard License.mayContactServer || License.isFreeBuild else { return self.showOnboarding() }
            await LicenseStore.shared.refresh()
            if !Settings.onboarded || !License.isActive || OnboardingWindowManager.shared.isVisible {
                self.showLicense()
            } else {
                self.showSettings()
            }
        }
    }

    /// Watching continues either way; the next picker searches (license active) or shows the unpaid
    /// bar. Only the menu's status line changes here.
    private func licenseChanged(active: Bool) {
        guard Settings.onboarded else { return }
        if !started {
            startWhenTrusted()
        } else {
            stateItem.title = Self.watchingTitle
        }
        setIcon(.idle)
    }

    private static var watchingTitle: String { License.isActive ? "Watching for file pickers" : "Inactive · Get Likely" }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.quit()
        if Log.details.isSwitchedOn { setLogDetails(false, why: "Likely quit") }
    }

    /// Settings → General → "Log details for troubleshooting".
    func setLogDetails(_ on: Bool, why: StaticString) {
        if on { Log.details.turnOn() } else { Log.details.turnOff() }
        Log.write("app", "log details \(public: on ? "on for 24 hours" : "off") (\(public: why))")
        applyLogDetails()
    }

    /// Details also log every accessibility event and window (the old "verbose" setting), and keep
    /// the agent's transcript. A timer turns them off when the 24 hours are up.
    private func applyLogDetails() {
        // Expired while asleep, or the clock moved past the end: off, and the stored copy too.
        if !Log.details.isSwitchedOn && UserDefaults.standard.object(forKey: LogDetailsSwitch.defaultsKey) != nil {
            Log.details.turnOff()
            Log.write("app", "log details off (24 hours passed)")
        }
        logDetailsTimer?.invalidate()
        logDetailsTimer = nil
        coordinator.verbose = Log.details.isSwitchedOn
        if !Log.details.showsDetails {
            Log.removeDetails()
            try? FileManager.default.removeItem(at: coordinator.transcriptURL)
        }
        guard let expiry = Log.details.expiry else { return }
        let timer = Timer(fire: expiry, interval: 0, repeats: false) { [weak self] _ in
            self?.setLogDetails(false, why: "24 hours passed")
        }
        RunLoop.main.add(timer, forMode: .common)
        logDetailsTimer = timer
    }

    /// AX observers created before the Accessibility grant silently do nothing, so wait for it.
    private func startWhenTrusted() {
        guard !started else { return }
        if AXIsProcessTrusted() {
            started = true
            coordinator.start()
            stateItem.title = Self.watchingTitle
            return
        }
        stateItem.title = "Waiting for Accessibility permission"
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            guard AXIsProcessTrusted() else { return }
            timer.invalidate()
            self?.started = true
            Log.write("app", "accessibility granted")
            self?.coordinator.start()
            self?.stateItem.title = Self.watchingTitle
        }
    }

    // MARK: Menu

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setIcon(.idle)
        NotificationCenter.default.addObserver(forName: MenuBarGlyph.didChange, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.setIcon(self.iconState)
        }

        NotificationCenter.default.addObserver(forName: ToolStore.approvalNeeded, object: nil, queue: .main) { [weak self] _ in
            self?.toolApprovalChanged()
        }

        let menu = NSMenu()
        stateItem.isEnabled = false
        menu.addItem(stateItem)
        menu.addItem(.separator())
        jumpItem.target = self
        menu.addItem(jumpItem)
        menu.delegate = self
        menu.addItem(.separator())
        improveItem.target = self
        menu.addItem(improveItem)
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        if Updater.isEnabled {
            menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "").target = self
        }
        if MenuBarGlyph.isDebugEnabled {
            menu.addItem(withTitle: "Debug View…", action: #selector(showDebugView), keyEquivalent: "d").target = self
            // Dev builds only: flip through the candidate menu bar glyphs in place.
            let debug = NSMenu()
            debug.addItem(withTitle: "Next Glyph", action: #selector(nextGlyph), keyEquivalent: "").target = self
            debug.addItem(withTitle: "Previous Glyph", action: #selector(previousGlyph), keyEquivalent: "").target = self
            let item = NSMenuItem(title: "Debug", action: nil, keyEquivalent: "")
            item.submenu = debug
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Likely", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    private var iconState = Coordinator.State.idle

    /// The glyph, with a dot while searching; dimmed while the license is inactive.
    private func setIcon(_ state: Coordinator.State) {
        iconState = state
        let symbol: String
        switch state {
        case .idle: symbol = "doc.viewfinder"
        case .searching: symbol = "sparkle.magnifyingglass"
        case .done: symbol = "checkmark.circle"
        }
        let approvalNeeded = !ToolStore.shared.pending.isEmpty
        statusItem.button?.image = MenuBarGlyph.image(badge: state == .searching || approvalNeeded ? .dot : .none,
                                                      dimmed: Settings.onboarded && !License.isActive, fallbackSymbol: symbol)
    }

    /// tools.json changed outside Likely: badge the menu bar, retitle the Tools item, and post a
    /// notification if Likely is allowed to (it never asks for that permission just for this).
    private func toolApprovalChanged() {
        let pending = ToolStore.shared.pending
        improveItem.title = pending.isEmpty ? "Improve Results…" : "Approve Tool Changes…"
        setIcon(iconState)
        guard !pending.isEmpty, Bundle.main.bundleURL.pathExtension == "app" else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = "Approve tool changes"
            content.body = "tools.json changed outside Likely: \(pending.map(\.tool.name).joined(separator: ", ")). Open Settings → Tools to review."
            center.add(UNNotificationRequest(identifier: "tool-approval", content: content, trigger: nil))
        }
    }

    @objc private func nextGlyph() { MenuBarGlyph.cycle(by: 1) }
    @objc private func previousGlyph() { MenuBarGlyph.cycle(by: -1) }

    @objc private func checkForUpdates() {
        MainActor.assumeIsolated { Updater.shared.checkForUpdates() }
    }

    /// Settings has the same switch, so the check mark is refreshed each time the menu opens.
    func menuWillOpen(_ menu: NSMenu) {
        jumpItem.state = Settings.openToLikely ? .on : .off
    }

    @objc private func toggleJump() {
        Settings.openToLikely.toggle()
        jumpItem.state = Settings.openToLikely ? .on : .off
        Log.write("app", "jump to Likely folder when a picker opens: \(Settings.openToLikely)")
    }

    @objc private func showDebugView() {
        if debugWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: DebugView(store: .shared)))
            window.title = "Likely Debug"
            window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 980, height: 720))
            window.center()
            debugWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        debugWindow?.makeKeyAndOrderFront(nil)
    }

    /// The eval test editor in its own small window, prefilled from a run.
    func showTestEditor(for run: DebugRun) {
        testWindow?.close()
        EvalCaseStore.shared.reload()
        let request = EditorRequest.from(run: run)
        let window = NSWindow(contentViewController: NSHostingController(rootView: EvalCaseEditor(request: request) { [weak self] in
            self?.testWindow?.close()
        }))
        window.title = "Save Search as Test"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        testWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Settings on the Tools tab: extra tools such as photo search give the agent better results.
    @objc private func showToolSettings() {
        SettingsNavigation.shared.tab = .tools
        showSettings()
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let actions = SettingsActions(
                showOnboarding: { [weak self] in self?.showOnboarding() },
                showLicense: { [weak self] in self?.showLicense() },
                showDebugView: { [weak self] in self?.showDebugView() },
                logDetailsChanged: { [weak self] on in self?.setLogDetails(on, why: "Settings") })
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(actions: actions)))
            window.title = "Likely Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// Onboarding opened straight on the license page (lapsed subscription, "Buy…" in Settings).
    func showLicense() {
        if !License.isFreeBuild { LikelyOnboardingStep.saved = .license }
        showOnboarding()
    }

    @objc func showOnboarding() {
        Log.write("app", "showing onboarding at step \(meta: LikelyOnboardingStep.saved.rawValue)")
        CopyEditor.shared.saveURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Likely/debug/onboarding-copy.json")
        let view = LikelyOnboardingView {
            Settings.onboarded = true
            LikelyOnboardingStep.clearSaved()
            if Settings.agentID == "claude", let path = AgentDetector.shared.path(for: AgentKind.all[0]) {
                UserDefaults.standard.set(path, forKey: "claudePath")
                ClaudeLocator.resolve()
            }
            Log.write("app", "onboarding finished, agent=\(meta: Settings.agentID)")
            self.startWhenTrusted()
            MainActor.assumeIsolated { OnboardingWindowManager.shared.closeWindow() }
        }
        // AppKit always calls this on the main thread.
        MainActor.assumeIsolated { OnboardingWindowManager.shared.showWindow(view) }
    }
}
