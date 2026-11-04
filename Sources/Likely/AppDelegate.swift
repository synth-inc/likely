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
        ClaudeLocator.resolve()
        Log.write("app", "claude: \(ClaudeLocator.path ?? "not found")")
        buildStatusItem()

        coordinator.verbose = Settings.verbose
        coordinator.onStateChange = { [weak self] state, message in
            self?.stateItem.title = message
            self?.statusItem.button?.image = Self.icon(for: state)
        }

        AgentDetector.shared.scan()
        // Option B: setup (ending with the license page) has to be finished before Likely starts working.
        // The cached entitlement decides at launch (works offline); the server check right after can
        // still turn it on or off through `licenseChanged`.
        if Settings.onboarded && License.isActive {
            startWhenTrusted()
        } else if Settings.onboarded {
            licenseChanged(active: false)
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

    /// Start when a purchase lands (once setup is done); when a subscription lapses or the offline
    /// grace runs out, stop and say so instead of going quiet.
    private func licenseChanged(active: Bool) {
        if active {
            if Settings.onboarded { startWhenTrusted() }
            return
        }
        trustTimer?.invalidate()
        trustTimer = nil
        if started {
            coordinator.stop()
            started = false
        }
        stateItem.title = "License inactive. Open Settings to renew"
        statusItem.button?.image = Self.icon(for: .idle)
        if Settings.onboarded { showLicense() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.stop()
    }

    /// AX observers created before the Accessibility grant silently do nothing, so wait for it.
    private func startWhenTrusted() {
        guard !started else { return }
        if AXIsProcessTrusted() {
            started = true
            coordinator.start()
            stateItem.title = "Watching for file pickers"
            return
        }
        stateItem.title = "Waiting for Accessibility permission"
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            guard AXIsProcessTrusted() else { return }
            timer.invalidate()
            self?.started = true
            Log.write("app", "accessibility granted")
            self?.coordinator.start()
            self?.stateItem.title = "Watching for file pickers"
        }
    }

    // MARK: Menu

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Self.icon(for: .idle)

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
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Likely", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    private static func icon(for state: Coordinator.State) -> NSImage? {
        let name: String
        switch state {
        case .idle: name = "doc.viewfinder"
        case .searching: name = "sparkle.magnifyingglass"
        case .done: name = "checkmark.circle"
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Likely")
        image?.isTemplate = true
        return image
    }

    @objc private func openFolder() {
        try? LikelyFolder.create()
        NSWorkspace.shared.open(LikelyFolder.url)
    }

    @objc private func togglePause() {
        coordinator.paused.toggle()
        pauseItem.state = coordinator.paused ? .on : .off
        stateItem.title = coordinator.paused ? "Paused" : "Watching for file pickers"
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
