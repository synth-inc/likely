import AppKit
import CoreGraphics

/// Snapshot helpers over CGWindowListCopyWindowInfo, plus a poller that logs windows appearing and
/// disappearing. The poller is a second picker detector: sandboxed apps' panels are drawn by the
/// open/save panel service, so a new window owned by that service means a picker opened.
struct WindowInfo {
    let id: CGWindowID
    let pid: pid_t
    let owner: String
    let name: String?
    let layer: Int
    let bounds: CGRect

    init?(_ dict: [String: Any]) {
        guard let id = dict[kCGWindowNumber as String] as? CGWindowID,
              let pid = dict[kCGWindowOwnerPID as String] as? pid_t,
              let boundsDict = dict[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDict) else { return nil }
        self.id = id
        self.pid = pid
        owner = dict[kCGWindowOwnerName as String] as? String ?? "?"
        name = dict[kCGWindowName as String] as? String
        layer = dict[kCGWindowLayer as String] as? Int ?? 0
        self.bounds = bounds
    }

    /// On-screen windows, front to back.
    static func onScreen() -> [WindowInfo] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap(WindowInfo.init)
    }
}

extension CGRect {
    func roughlyEquals(_ other: CGRect, tolerance: CGFloat = 3) -> Bool {
        abs(minX - other.minX) <= tolerance && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }
}

final class WindowListWatcher {
    var onPanelServiceWindow: ((WindowInfo) -> Void)?
    var verbose = false

    private var timer: Timer?
    private var known: [CGWindowID: WindowInfo] = [:]

    func start() {
        known = Dictionary(uniqueKeysWithValues: WindowInfo.onScreen().map { ($0.id, $0) })
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in self?.poll() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    static func isPanelService(_ pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == AXWatcher.panelServiceBundleID
    }

    private func poll() {
        let current = Dictionary(uniqueKeysWithValues: WindowInfo.onScreen().map { ($0.id, $0) })
        for (id, window) in current where known[id] == nil {
            let fromService = Self.isPanelService(window.pid)
            if verbose || fromService || window.layer == 0 {
                Log.write("cg-window", "appeared #\(id) owner=\(window.owner)(\(window.pid)) layer=\(window.layer) name=\(window.name ?? "-") bounds=\(window.bounds)\(fromService ? " [PANEL SERVICE]" : "")")
            }
            if fromService && window.layer == 0 { onPanelServiceWindow?(window) }
        }
        for (id, window) in known where current[id] == nil {
            if verbose || window.layer == 0 || Self.isPanelService(window.pid) {
                Log.write("cg-window", "disappeared #\(id) owner=\(window.owner)(\(window.pid))")
            }
        }
        known = current
    }
}
