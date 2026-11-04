import AppKit
import ApplicationServices
import OnboardingKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let stateItem = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private let pauseItem = NSMenuItem(title: "Pause", action: #selector(togglePause), keyEquivalent: "")

    private let coordinator = Coordinator()
    private var debugWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var trustTimer: Timer?
    private var started = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("app", "launched, log at \(Log.fileURL.path)")
        // The login-shell part of the lookup runs in the background (it can take seconds).
        ClaudeLocator.resolve { Log.write("app", "claude: \(ClaudeLocator.path ?? "not found")") }
        buildStatusItem()
        MainActor.assumeIsolated { Updater.shared.start() }

        coordinator.verbose = Settings.verbose
        coordinator.onStateChange = { [weak self] state, message in
            self?.stateItem.title = message
            self?.setIcon(state)
        }
        // Licensing gates the search, not the watching: an unlicensed Likely still shows its bar above
        // pickers, in an unpaid state that leads to the license page.
        coordinator.isLicensed = { License.isActive }
        coordinator.onGetLikely = { [weak self] in self?.showLicense() }

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
            LicenseStore.shared.startPeriodicChecks()
        }
    }

    /// `likely://payment-success` (Stripe Checkout's success redirect) and any other likely:// link:
    /// re-check the license and bring the relevant window forward.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { $0.scheme == "likely" }) else { return }
        Log.write("app", "opened by \(url.scheme ?? "")://\(url.host ?? "")")
        Task { @MainActor in
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
        } else if !coordinator.paused {
            stateItem.title = Self.watchingTitle
        }
        setIcon(.idle)
    }

    private static var watchingTitle: String { License.isActive ? "Watching for file pickers" : "Inactive · Get Likely" }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.quit()
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

        let menu = NSMenu()
        stateItem.isEnabled = false
        menu.addItem(stateItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Likely Folder", action: #selector(openFolder), keyEquivalent: "").target = self
        pauseItem.target = self
        menu.addItem(pauseItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Debug View…", action: #selector(showDebugView), keyEquivalent: "d").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "").target = self
        if MenuBarGlyph.isDebugEnabled {
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
        statusItem.button?.image = MenuBarGlyph.image(badge: state == .searching ? .dot : .none,
                                                      dimmed: Settings.onboarded && !License.isActive, fallbackSymbol: symbol)
    }

    @objc private func nextGlyph() { MenuBarGlyph.cycle(by: 1) }
    @objc private func previousGlyph() { MenuBarGlyph.cycle(by: -1) }

    @objc private func openFolder() {
        try? LikelyFolder.create()
        NSWorkspace.shared.open(LikelyFolder.url)
    }

    @objc private func checkForUpdates() {
        MainActor.assumeIsolated { Updater.shared.checkForUpdates() }
    }

    @objc private func togglePause() {
        coordinator.paused.toggle()
        pauseItem.state = coordinator.paused ? .on : .off
        stateItem.title = coordinator.paused ? "Paused" : Self.watchingTitle
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

    @objc private func showSettings() {
        if settingsWindow == nil {
            let actions = SettingsActions(
                showOnboarding: { [weak self] in self?.showOnboarding() },
                showLicense: { [weak self] in self?.showLicense() },
                showDebugView: { [weak self] in self?.showDebugView() },
                verboseChanged: { [weak self] value in self?.coordinator.verbose = value })
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
        Log.write("app", "showing onboarding at step \(LikelyOnboardingStep.saved.rawValue)")
        CopyEditor.shared.saveURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Likely/debug/onboarding-copy.json")
        let view = LikelyOnboardingView {
            Settings.onboarded = true
            LikelyOnboardingStep.clearSaved()
            if Settings.agentID == "claude", let path = AgentDetector.shared.path(for: AgentKind.all[0]) {
                UserDefaults.standard.set(path, forKey: "claudePath")
                ClaudeLocator.resolve()
            }
            Log.write("app", "onboarding finished, agent=\(Settings.agentID)")
            self.startWhenTrusted()
            MainActor.assumeIsolated { OnboardingWindowManager.shared.closeWindow() }
        }
        // AppKit always calls this on the main thread.
        MainActor.assumeIsolated { OnboardingWindowManager.shared.showWindow(view) }
    }
}
