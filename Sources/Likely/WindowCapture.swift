import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Screenshots the window the user was looking at when the picker opened, leaving the picker out.
///
/// Once a picker is showing it's baked into the app's window pixels (Chrome draws the sheet into its
/// own window), so the primary source is a snapshot taken on the click or ⌘-shortcut that opened it,
/// kept in memory. A live capture is the fallback. Either is only written to disk (`save`) when the
/// user submits a search.
enum WindowCapture {
    struct Result {
        let url: URL
        let windowTitle: String?
        let mode: String
    }

    struct Snapshot {
        let pid: pid_t
        let windowID: CGWindowID
        let title: String?
        let image: CGImage
        let date: Date
    }

    /// A screenshot in memory, not yet written.
    struct Image {
        let image: CGImage
        let windowTitle: String?
        let mode: String
    }

    enum CaptureError: Error { case noWindow, noDisplay, writeFailed }

    /// Front-most normal window of `pid`, optionally skipping the picker's own frame.
    static func frontWindow(pid: pid_t, excluding pickerFrame: CGRect? = nil) -> WindowInfo? {
        WindowInfo.onScreen().first { info in
            info.pid == pid && info.layer == 0 && info.bounds.width > 150 && info.bounds.height > 150
                && !(pickerFrame.map { info.bounds.roughlyEquals($0) } ?? false)
        }
    }

    static func snapshot(pid: pid_t) async throws -> Snapshot {
        guard let info = frontWindow(pid: pid) else { throw CaptureError.noWindow }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == info.id }) else { throw CaptureError.noWindow }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration(for: window.frame))
        return Snapshot(pid: pid, windowID: info.id, title: window.title, image: image, date: Date())
    }

    static func image(from snapshot: Snapshot) -> Image {
        let age = String(format: "%.1fs", Date().timeIntervalSince(snapshot.date))
        return Image(image: snapshot.image, windowTitle: snapshot.title, mode: "pre-picker snapshot of window #\(snapshot.windowID), \(age) old")
    }

    static func save(_ image: Image, to url: URL) throws -> Result {
        try write(image.image, to: url)
        return Result(url: url, windowTitle: image.windowTitle, mode: image.mode)
    }

    /// Fallback when there's no fresh snapshot. The picker may show up in the image.
    static func captureNow(pid: pid_t, pickerFrame: CGRect?) async throws -> Image {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)

        if let info = frontWindow(pid: pid, excluding: pickerFrame),
           let window = content.windows.first(where: { $0.windowID == info.id }),
           let display = content.displays.first(where: { $0.frame.intersects(window.frame) }) {
            // Draw only this window (not separately-windowed sheets) and crop to it.
            let filter = SCContentFilter(display: display, including: [window])
            let config = configuration(for: window.frame)
            config.sourceRect = window.frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return Image(image: image, windowTitle: window.title, mode: "live capture of window #\(info.id)")
        }

        // No separate underlying window (e.g. a standalone Open panel): capture the display minus the picker.
        let center = pickerFrame.map { CGPoint(x: $0.midX, y: $0.midY) } ?? .zero
        guard let display = content.displays.first(where: { $0.frame.contains(center) }) ?? content.displays.first else {
            throw CaptureError.noDisplay
        }
        let excluded = content.windows.filter { window in
            WindowListWatcher.isPanelService(window.owningApplication?.processID ?? 0)
                || (pickerFrame.map { window.frame.roughlyEquals($0) } ?? false)
        }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration(for: display.frame))
        return Image(image: image, windowTitle: nil, mode: "live capture of display minus \(excluded.count) picker windows")
    }

    /// Retina resolution, capped so the image stays a reasonable size for Claude to read.
    private static func configuration(for frame: CGRect) -> SCStreamConfiguration {
        let scale = min(NSScreen.main?.backingScaleFactor ?? 2, 2000 / max(frame.width, frame.height, 1))
        let config = SCStreamConfiguration()
        config.width = max(1, Int(frame.width * scale))
        config.height = max(1, Int(frame.height * scale))
        config.showsCursor = false
        return config
    }

    private static func write(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CaptureError.writeFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CaptureError.writeFailed }
    }
}

/// Keeps an in-memory snapshot of the front window, refreshed on every click and ⌘-shortcut,
/// i.e. the gestures that open pickers. Nothing is written to disk unless the user searches from the
/// picker that click opened. Off when "Send a screenshot with searches" is.
final class PrePickerSnapshotter {
    private(set) var latest: WindowCapture.Snapshot?
    var isSuspended: () -> Bool = { false }

    private var monitor: Any?
    private var inFlight = false
    private var lastStart = Date.distantPast

    func start() {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { [weak self] event in
            if event.type == .keyDown && !event.modifierFlags.contains(.command) { return }
            self?.refresh()
        }
    }

    func stop() {
        monitor.map(NSEvent.removeMonitor)
        monitor = nil
    }

    /// The snapshot, if it's of `pid` and recent enough to describe what opened the picker.
    func snapshot(for pid: pid_t, maxAge: TimeInterval = 15) -> WindowCapture.Snapshot? {
        guard let latest, latest.pid == pid, Date().timeIntervalSince(latest.date) < maxAge else { return nil }
        return latest
    }

    /// Forgets the snapshot (a picker closed, or screenshots were turned off).
    func discard() { latest = nil }

    /// Like `snapshot(for:)`, but first lets a capture that's still running (from the opening click) finish.
    func awaitSnapshot(for pid: pid_t) async -> WindowCapture.Snapshot? {
        for _ in 0..<20 where inFlight {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return snapshot(for: pid)
    }

    private func refresh() {
        guard !isSuspended(), !inFlight, Date().timeIntervalSince(lastStart) > 0.3,
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        inFlight = true
        lastStart = Date()
        let pid = app.processIdentifier
        Task { @MainActor [weak self] in
            defer { self?.inFlight = false }
            if let snapshot = try? await WindowCapture.snapshot(pid: pid) {
                self?.latest = snapshot
            }
        }
    }
}
