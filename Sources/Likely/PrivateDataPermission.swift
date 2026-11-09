import AppKit
import Darwin
import LikelyTools
import Photos

/// Turning a Private data area on (Settings → Permissions, or a tool that `needs` it). Its sandbox
/// deny rule goes away for the next search, and macOS's own permission alert is triggered right away,
/// by Likely, while the user is looking at the toggle, rather than in the middle of a later search when
/// an agent first reads there. If macOS says no, the area is turned back off.
///
/// - Photos: PhotoKit's `requestAuthorization` (the clean, documented alert), then a read of the
///   library folders. PhotoKit access and file access to a `.photoslibrary` may be separate grants;
///   the read makes sure any second alert comes now as well, and that the agents (whose file reads
///   macOS attributes to Likely) will actually be able to read there.
/// - Contacts & Calendars, other apps' data: a read of the protected folders from Likely itself, which
///   is what makes macOS ask.
/// - Mail, Messages, Safari: macOS has no alert for these; only Full Disk Access opens them. The read
///   tells whether Likely has it; if not, the user is pointed at that pane.
///
/// Turning an area off only restores the deny rule. The macOS grant stays in System Settings →
/// Privacy & Security until removed there.
enum PrivateDataPermission {
    enum Outcome: Equatable {
        case granted
        case denied(String)
    }

    static let fullDiskAccessURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    /// Asks macOS for `area` and turns it on if allowed (main thread completion).
    static func enable(_ area: PrivateDataArea, completion: @escaping (Outcome) -> Void) {
        let finish: (Outcome) -> Void = { outcome in
            DispatchQueue.main.async {
                PrivateDataAccess.setAllowed(outcome == .granted, area)
                Log.write("privacy", "\(area.rawValue): \(outcome == .granted ? "allowed" : "not allowed")")
                ToolStore.shared.privateDataChanged()
                completion(outcome)
            }
        }
        // Agents stay blocked until macOS has said yes (Likely itself isn't sandboxed, so it can ask).
        if area == .photos {
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                guard status == .authorized || status == .limited else {
                    return finish(.denied("macOS didn't allow access to Photos. You can change that in System Settings → Privacy & Security → Photos."))
                }
                DispatchQueue.global(qos: .userInitiated).async { finish(probe(area)) }
            }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { finish(probe(area)) }
    }

    static func disable(_ area: PrivateDataArea) {
        PrivateDataAccess.setAllowed(false, area)
        Log.write("privacy", "\(area.rawValue): blocked for agents again")
        ToolStore.shared.privateDataChanged()
    }

    /// Reads the area's folders (one listing each, plus one level into a container for app data).
    /// Blocks while macOS shows its alert, so it runs off the main thread.
    private static func probe(_ area: PrivateDataArea) -> Outcome {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var targets = area.paths(home: home).filter { FileManager.default.fileExists(atPath: $0) }
        if area == .appData {
            // Listing ~/Library/Containers is free; reading inside another app's container is what's protected.
            let containers = home + "/Library/Containers"
            let other = ((try? FileManager.default.contentsOfDirectory(atPath: containers)) ?? [])
                .filter { !$0.hasPrefix("inc.synth.") && !$0.hasPrefix(".") }.sorted().first
            if let other { targets.append(containers + "/" + other + "/Data") }
        }
        for path in targets {
            guard let dir = opendir(path) else {
                let code = errno
                if code == ENOENT { continue }
                if area.needsFullDiskAccess {
                    return .denied("macOS only lets apps read \(area.title) data with Full Disk Access, and Likely doesn't have it. Add Likely in System Settings → Privacy & Security → Full Disk Access, then turn this on again.")
                }
                return .denied("macOS didn't allow Likely to read \((path as NSString).abbreviatingWithTildeInPath) (\(String(cString: strerror(code)))). You can change that in System Settings → Privacy & Security.")
            }
            _ = readdir(dir)
            closedir(dir)
        }
        return .granted
    }
}
