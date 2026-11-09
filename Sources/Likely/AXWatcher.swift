import AppKit
import ApplicationServices

/// Registers an AXObserver on every regular app (plus the system open/save panel service),
/// logs every notification it receives, and forwards them to `onEvent`.
final class AXWatcher {
    /// Logged always. These are the candidates for "a file picker just opened / closed".
    static let primaryNotifications: [String] = [
        kAXWindowCreatedNotification,
        kAXSheetCreatedNotification,
        kAXDrawerCreatedNotification,
        kAXFocusedWindowChangedNotification,
        kAXMainWindowChangedNotification,
        kAXUIElementDestroyedNotification,
        kAXApplicationActivatedNotification,
        kAXApplicationDeactivatedNotification,
        kAXApplicationHiddenNotification,
        kAXApplicationShownNotification,
        kAXWindowMiniaturizedNotification,
        kAXWindowDeminiaturizedNotification,
    ]

    /// Logged only with verbose logging on; they fire constantly.
    static let noisyNotifications: [String] = [
        kAXCreatedNotification,
        kAXFocusedUIElementChangedNotification,
        kAXTitleChangedNotification,
        kAXWindowMovedNotification,
        kAXWindowResizedNotification,
        kAXLayoutChangedNotification,
        kAXMenuOpenedNotification,
        kAXMenuClosedNotification,
        kAXRowCountChangedNotification,
        kAXSelectedChildrenChangedNotification,
    ]

    static let panelServiceBundleID = "com.apple.appkit.xpc.openAndSavePanelService"

    var onEvent: ((_ pid: pid_t, _ notification: String, _ element: AXUIElement) -> Void)?
    var verbose = false

    private var observers: [pid_t: AXObserver] = [:]
    private var workspaceTokens: [NSObjectProtocol] = []

    func start() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)
        for app in NSWorkspace.shared.runningApplications where shouldWatch(app) {
            attach(to: app)
        }
        let center = NSWorkspace.shared.notificationCenter
        workspaceTokens.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  self.shouldWatch(app) else { return }
            // Freshly launched apps often aren't AX-ready yet.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.attach(to: app) }
        })
        workspaceTokens.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.detach(pid: app.processIdentifier)
        })
        Log.write("ax", "watching \(observers.count) apps")
    }

    func stop() {
        workspaceTokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceTokens.removeAll()
        for pid in Array(observers.keys) { detach(pid: pid) }
    }

    /// Also listen for destruction of a specific element (e.g. the picker window itself).
    func watchDestruction(of element: AXUIElement) {
        guard let observer = observers[AX.pid(element)] else { return }
        AXObserverAddNotification(observer, element, kAXUIElementDestroyedNotification as CFString,
                                  Unmanaged.passUnretained(self).toOpaque())
    }

    private func shouldWatch(_ app: NSRunningApplication) -> Bool {
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }
        return app.activationPolicy == .regular || app.bundleIdentifier == Self.panelServiceBundleID
    }

    private func attach(to app: NSRunningApplication, attempt: Int = 0) {
        let pid = app.processIdentifier
        guard observers[pid] == nil, !app.isTerminated else { return }

        var observer: AXObserver?
        guard AXObserverCreate(pid, axCallback, &observer) == .success, let observer else {
            Log.write("ax", "AXObserverCreate failed for \(meta: app.localizedName) (\(pid))")
            return
        }
        let appElement = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        // Probe with one registration first: an unresponsive app would otherwise stall every call below.
        let probe = AXObserverAddNotification(observer, appElement, kAXWindowCreatedNotification as CFString, refcon)
        if probe == .cannotComplete {
            if attempt < 5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.attach(to: app, attempt: attempt + 1) }
            }
            Log.write("ax", "\(meta: app.localizedName) (\(pid)) not responding, retry \(attempt + 1)/5")
            return
        }
        var registered = 0
        var notReady = false
        for name in Self.primaryNotifications + Self.noisyNotifications {
            let err = AXObserverAddNotification(observer, appElement, name as CFString, refcon)
            if err == .success { registered += 1 }
            if err == .cannotComplete { notReady = true }
        }
        if registered == 0 {
            if notReady && attempt < 5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.attach(to: app, attempt: attempt + 1) }
            } else if verbose {
                Log.write("ax", "no notifications registered for \(meta: app.localizedName) (\(pid))")
            }
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
        if verbose { Log.write("ax", "attached \(meta: app.localizedName) (\(pid)), \(registered) notifications") }
    }

    private func detach(pid: pid_t) {
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    fileprivate func handle(element: AXUIElement, notification: String) {
        let pid = AX.pid(element)
        if verbose || !Self.noisyNotifications.contains(notification) {
            let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
            // Destroyed elements can't be described anymore.
            let detail: LogMessage = notification == kAXUIElementDestroyedNotification ? "" : " \(AX.describe(element))"
            Log.write("ax-event", "\(meta: appName): \(meta: notification)\(detail)")
        }
        onEvent?(pid, notification, element)
    }
}

private func axCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    Unmanaged<AXWatcher>.fromOpaque(refcon).takeUnretainedValue()
        .handle(element: element, notification: notification as String)
}
