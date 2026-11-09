import AppKit
import ApplicationServices
import LikelyEvalKit

/// Turns real use into eval cases automatically: when a picker is confirmed, what the user typed
/// (plus the app, window title and screenshot) and the file(s) they actually picked are added to
/// cases.jsonl, tagged "captured". Cancelled pickers are never recorded. If the pick couldn't be
/// read, nothing goes into cases; a "needs expected" entry goes to drafts.jsonl instead.
///
/// Off by default in every build: "Automatically save picks as tests" in Settings → Evals.
enum EvalCapture {
    static let defaultsKey = "evalAutoCapture"
    static let capturedTag = "captured"
    static let defaultValue = false

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? defaultValue }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    /// Saves a case (or, without a known pick, a draft). Nothing is saved if there's nothing to replay
    /// (no typed query and no screenshot).
    static func saveCaptured(app: String, windowTitle: String?, button: String?, queries: [String], screenshot: Data?,
                          picked: [String], how: String, suggested: [String]) {
        guard !queries.isEmpty || screenshot != nil else {
            Log.write("evals", "picked without typing or a screenshot, not saved")
            return
        }
        let existing = (try? EvalCaseFile.load(EvalStorage.draftsURL).cases) ?? []
        let cases = (try? EvalCaseFile.load(EvalStorage.casesURL).cases) ?? []
        let stamp = Self.stamp()
        let id = EvalCaseFile.uniqueID(EvalCase.slug(queries.first ?? app, fallback: "captured") + "-" + stamp, existing: existing + cases)

        // The live screenshot is deleted when the picker closes: keep an encrypted copy with the case
        // (evals/screenshots/<id>.png.enc).
        let screenshotPath = screenshot.flatMap { EvalCaseStore.keepScreenshot(png: $0, id: id) }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let tilde: (String) -> String = { $0.hasPrefix(home + "/") ? "~" + $0.dropFirst(home.count) : $0 }
        var expect = Expectation()
        var tags = [capturedTag]
        if picked.count == 1, isDirectory(picked[0]) {
            expect = Expectation(folder: tilde(picked[0]), mode: "folder-or-contents")
            tags.append("folder")
        } else if picked.count == 1 {
            expect = Expectation(anyOf: picked.map(tilde))
        } else if picked.count > 1 {
            expect = Expectation(allOf: picked.map(tilde))
        } else {
            tags.append(EvalCase.needsExpectedTag)
        }
        if screenshotPath != nil { tags.append("screenshot") }
        if queries.count > 1 { tags.append("multi-turn") }

        var notes = "Captured \(how)."
        if !suggested.isEmpty {
            let hit = picked.contains { p in suggested.contains { EvalPath.same(EvalPath.normalize($0), EvalPath.normalize(p)) } }
            notes += " Likely suggested \(suggested.count) file\(suggested.count == 1 ? "" : "s")\(hit ? ", including the pick" : ", not the pick")."
        }
        let draft = EvalCase(id: id, query: queries.isEmpty ? [""] : queries,
                             context: EvalCase.Context(app: app, windowTitle: windowTitle, screenshot: screenshotPath, button: button),
                             expect: expect, tags: tags, source: "captured", notes: notes)
        // Unknown pick: keep it out of the tests; it waits under "Needs expected" in Settings → Evals.
        let destination = picked.isEmpty ? EvalStorage.draftsURL : EvalStorage.casesURL
        do {
            try EvalCaseFile.append(draft, to: destination)
            Log.write("evals", picked.isEmpty ? "pick unknown: \(id) saved to drafts (needs expected)" : "test \(id) saved (\(picked.count) picked)")
            DispatchQueue.main.async { EvalCaseStore.shared.reload() }
        } catch {
            Log.write("evals", "couldn't save captured test: \(error)")
            if let screenshotPath { try? FileManager.default.removeItem(atPath: screenshotPath) }
        }
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
            && !NSWorkspace.shared.isFilePackage(atPath: path)
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}

/// Watches one open picker for what the user ends up picking.
///
/// - Selection: NSOpenPanel's file browser exposes the selection through Accessibility. In list view
///   the browser is an AXOutline (identifier "ListView"); its `AXSelectedRows` are AXRows whose name
///   cell holds an AXTextField with `AXURL` (a file reference URL, resolved with `filePathURL`) and
///   `AXFilename`. Column and icon views are read the same generic way: any container's
///   `AXSelectedRows` / `AXSelectedChildren`, then `AXURL` within a few levels below each selected item.
///   The selection is read on every poll and on every click or key press, because once the panel has
///   closed there's nothing left to read.
/// - Confirm vs. cancel: a global event monitor (needs Accessibility, which Likely has) notes mouse-downs
///   on the panel's default button (`AXDefaultButton`) or cancel button (`AXCancelButton`), Return /
///   Enter, Escape / ⌘., and double-clicks in the browser. The panel closing within a few seconds of a
///   confirm counts as a pick; anything else (cancel, or no signal at all) is not recorded.
final class PickTracker {
    struct Outcome {
        let confirmed: Bool
        let urls: [URL]
        /// How the close was classified, for logs and the draft's notes.
        let how: String
    }

    private enum Intent { case confirm(String), cancel(String) }

    private(set) var isTracking = false
    private var window: AXUIElement?
    private var pid: pid_t = 0
    private var monitor: Any?
    private var selection: [URL] = []
    private var containers: [AXUIElement] = []
    private var containersFoundAt = Date.distantPast
    private var intent: (Intent, Date)?

    func begin(window: AXUIElement?, pid: pid_t) {
        end()
        isTracking = true
        self.window = window
        self.pid = pid
        selection = []
        containers = []
        intent = nil
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { [weak self] event in
            self?.handle(event)
        }
    }

    /// Called from the coordinator's close poll.
    func poll() {
        guard isTracking else { return }
        readSelection()
    }

    @discardableResult
    func end() -> Outcome {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        defer {
            isTracking = false
            window = nil
            containers = []
        }
        guard isTracking else { return Outcome(confirmed: false, urls: [], how: "not tracked") }
        guard let (kind, at) = intent, Date().timeIntervalSince(at) < 5 else {
            return Outcome(confirmed: false, urls: [], how: "closed without a confirm")
        }
        switch kind {
        case .cancel(let how): return Outcome(confirmed: false, urls: [], how: how)
        case .confirm(let how): return Outcome(confirmed: true, urls: selection, how: how)
        }
    }

    // MARK: Events

    private func handle(_ event: NSEvent) {
        guard isTracking else { return }
        switch event.type {
        case .keyDown:
            switch event.keyCode {
            case 36, 76:   // Return, Enter
                readSelection()
                intent = (.confirm("confirmed with Return"), Date())
            case 53:       // Escape
                intent = (.cancel("cancelled with Escape"), Date())
            case 47 where event.modifierFlags.contains(.command):   // ⌘.
                intent = (.cancel("cancelled with ⌘."), Date())
            default:
                break
            }
        case .leftMouseDown:
            guard let window else { return }
            let point = Self.axPoint(NSEvent.mouseLocation)
            if let button = AX.element(window, kAXDefaultButtonAttribute), let frame = AX.frame(button), frame.contains(point) {
                readSelection()
                intent = (.confirm("confirmed with \(AX.string(button, kAXTitleAttribute).map { "“\($0)”" } ?? "the default button")"), Date())
            } else if let button = AX.element(window, kAXCancelButtonAttribute), let frame = AX.frame(button), frame.contains(point) {
                intent = (.cancel("cancelled with the Cancel button"), Date())
            } else if event.clickCount == 2, let frame = AX.frame(window), frame.contains(point) {
                // Double-clicking a file opens it (a folder just navigates, and the panel stays open).
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.readSelection()
                    self?.intent = (.confirm("confirmed with a double-click"), Date())
                }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.readSelection() }
            }
        default:
            break
        }
    }

    /// AppKit screen coordinates (origin bottom-left of the main screen) → AX (origin top-left).
    private static func axPoint(_ p: NSPoint) -> CGPoint {
        let height = NSScreen.screens.first?.frame.maxY ?? 0
        return CGPoint(x: p.x, y: height - p.y)
    }

    // MARK: Selection

    /// Reads the selected file URLs. Keeps the last good reading if the panel is gone.
    private func readSelection() {
        guard let window, AX.isAlive(window) else { return }
        if containers.isEmpty || Date().timeIntervalSince(containersFoundAt) > 10 || !containers.allSatisfy(AX.isAlive) {
            containers = Self.selectionContainers(in: window)
            containersFoundAt = Date()
        }
        var urls: [URL] = []
        for container in containers {
            for attribute in ["AXSelectedRows", "AXSelectedChildren"] {
                for item in AX.elements(container, attribute) {
                    for url in Self.urls(under: item, depth: 4) where !urls.contains(url) { urls.append(url) }
                }
            }
        }
        // Column view (and the sidebar) also show the folders above the pick as selected: keep the deepest.
        let paths = urls.map(\.path)
        selection = urls.filter { url in !paths.contains { $0 != url.path && $0.hasPrefix(url.path + "/") } }
    }

    private static func selectionContainers(in window: AXUIElement) -> [AXUIElement] {
        var found: [AXUIElement] = []
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 1500 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            let role = AX.string(element, kAXRoleAttribute) ?? ""
            if ["AXOutline", "AXTable", "AXList", "AXBrowser", "AXGrid", "AXCollection"].contains(role) {
                found.append(element)
                if role != "AXBrowser" { continue }   // rows below aren't containers; a browser's columns are
            }
            if depth < 12 { queue.append(contentsOf: AX.elements(element, kAXChildrenAttribute).map { ($0, depth + 1) }) }
        }
        return found
    }

    private static func urls(under element: AXUIElement, depth: Int) -> [URL] {
        if let value = AX.value(element, "AXURL") {
            var url: URL?
            if CFGetTypeID(value) == CFURLGetTypeID() { url = (value as! URL) } else if let s = value as? String { url = URL(string: s) }
            if let url, url.isFileURL, let path = (url as NSURL).filePathURL { return [path.standardizedFileURL] }
        }
        guard depth > 0 else { return [] }
        return AX.elements(element, kAXChildrenAttribute).flatMap { urls(under: $0, depth: depth - 1) }
    }
}
