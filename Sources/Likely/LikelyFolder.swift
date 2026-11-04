import AppKit

/// Manages ~/Likely: APFS clones of candidate files, plus a "…status…" file whose name is the
/// current progress message (the "…" sorts it above everything else in Finder and file pickers).
/// Only removes files it created itself; anything else the user puts in the folder is left alone.
final class LikelyFolder {
    static let defaultURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Likely", isDirectory: true)

    /// The folder pinned in the user's sidebar; ~/Likely unless they chose another one.
    static var url: URL {
        get { UserDefaults.standard.string(forKey: "likelyFolderPath").map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultURL }
        set { UserDefaults.standard.set(newValue.path, forKey: "likelyFolderPath") }
    }

    /// Inside a folder macOS guards with a privacy prompt (Desktop, Documents, Downloads) or one that
    /// syncs to the cloud (iCloud Drive, ~/Library/CloudStorage).
    static func isProtectedLocation(_ url: URL) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.standardizedFileURL.path
        return ["Desktop", "Documents", "Downloads", "Library/Mobile Documents", "Library/CloudStorage"]
            .contains { path == "\(home)/\($0)" || path.hasPrefix("\(home)/\($0)/") }
    }

    static func resetToDefault() {
        UserDefaults.standard.removeObject(forKey: "likelyFolderPath")
        try? create()
        Log.write("likely", "folder reset to \(defaultURL.path)")
    }

    /// Asks the user to pick the folder. Returns false if they cancelled.
    @discardableResult
    static func choose() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        panel.message = "Choose the folder Likely should fill. Pin the same folder in the Finder sidebar."
        panel.directoryURL = exists ? url : FileManager.default.homeDirectoryForCurrentUser
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let chosen = panel.url else { return false }
        if isProtectedLocation(chosen) {
            let alert = NSAlert()
            alert.messageText = "This folder may not keep working"
            alert.informativeText = "macOS protects \((chosen.path as NSString).abbreviatingWithTildeInPath), and access to protected or iCloud-synced folders can be revoked, which would stop suggestions from appearing. We recommend ~/Likely."
            alert.addButton(withTitle: "Use ~/Likely")
            alert.addButton(withTitle: "Use Anyway")
            if alert.runModal() == .alertFirstButtonReturn {
                resetToDefault()
                return true
            }
        }
        url = chosen
        Log.write("likely", "folder set to \(chosen.path)")
        return true
    }
    static var exists: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static let supportPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Likely").path + "/"

    private let fm = FileManager.default
    private let manifestURL: URL
    private var added: [URL] = []
    private var sources = Set<String>()
    private var statusURL: URL?
    /// When the picker these copies were made for closed. Copies outlive the picker, because the app
    /// that opened it often reads the file afterwards (browsers upload it, Mail attaches it); they're
    /// removed when the next picker opens, or once they're `keepAfterClose` old.
    private(set) var releasedAt: Date?

    /// How long copies stay after their picker closed.
    static let keepAfterClose: TimeInterval = 10 * 60

    var count: Int { added.count }

    private struct Manifest: Codable {
        var paths: [String]
        var releasedAt: Date?
    }

    init(supportDirectory: URL) {
        manifestURL = supportDirectory.appendingPathComponent("likely-manifest.json")
        if let data = try? Data(contentsOf: manifestURL) {
            if let manifest = try? JSONDecoder().decode(Manifest.self, from: data) {
                added = manifest.paths.map { URL(fileURLWithPath: $0) }
                releasedAt = manifest.releasedAt
            } else if let paths = try? JSONDecoder().decode([String].self, from: data) {
                added = paths.map { URL(fileURLWithPath: $0) }   // older format
            }
        }
        // Copies from a picker that closed recently stay for the rest of their time (see
        // `remainingKeepTime`); anything else (a crash with a picker open, old copies) goes now.
        if remainingKeepTime == nil {
            clear()
        } else {
            removeStatusFiles()
            saveManifest()
        }
    }

    /// The picker closed: drop the status file, keep the copies for `keepAfterClose`.
    func release() {
        removeStatusFiles()
        statusURL = nil
        if !added.isEmpty { releasedAt = Date() }
        saveManifest()
    }

    /// Seconds until released copies should go, or nil if there's nothing to keep (none, not
    /// released, or already old enough).
    var remainingKeepTime: TimeInterval? {
        guard !added.isEmpty, let releasedAt else { return nil }
        let remaining = Self.keepAfterClose - Date().timeIntervalSince(releasedAt)
        return remaining > 0 ? remaining : nil
    }

    /// Clears released copies that are old enough. Returns true if it cleared.
    @discardableResult
    func clearIfExpired() -> Bool {
        guard releasedAt != nil, remainingKeepTime == nil else { return false }
        clear()
        return true
    }

    static func create() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func setStatus(_ message: String) {
        guard Self.exists else { return }
        var text = message.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: " -")
            .components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " .…"))
        if text.count > 100 { text = String(text.prefix(100)) }
        let target = Self.url.appendingPathComponent("…\(text)…")
        guard target != statusURL else { return }
        do {
            if let statusURL, fm.fileExists(atPath: statusURL.path) {
                try fm.moveItem(at: statusURL, to: target)
            } else {
                fm.createFile(atPath: target.path, contents: nil)
            }
            statusURL = target
        } catch {
            Log.write("likely", "status rename failed: \(error.localizedDescription)")
        }
    }

    /// Clones `path` into ~/Likely. Returns false for duplicates, missing files and folders.
    @discardableResult
    func add(path: String) -> Bool {
        guard Self.exists else { return false }
        let source = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard !sources.contains(source.path), !source.path.hasPrefix(Self.url.path + "/") else { return false }
        // Never suggest Likely's own files (e.g. the screenshot an agent was shown).
        guard !source.path.hasPrefix(Self.supportPath) else {
            Log.write("likely", "skip Likely's own file \(source.path)")
            return false
        }
        // Credentials, keychains, dotfiles, system files: never staged where any picker can grab them.
        // Checked on the real path too (Foundation's resolution drops /private, realpath keeps it).
        let home = fm.homeDirectoryForCurrentUser.path
        if let reason = SensitivePaths.refusalReason(for: source.path, home: home)
            ?? SensitivePaths.refusalReason(for: AgentSandbox.realPath(source.path), home: home) {
            Log.write("likely", "skip sensitive \(source.path) (\(reason))")
            return false
        }

        // Only regular files and packages (no folders, devices, sockets, FIFOs).
        var info = stat()
        guard lstat(source.path, &info) == 0 else {
            Log.write("likely", "skip missing \(source.path)")
            return false
        }
        let isRegular = (info.st_mode & S_IFMT) == S_IFREG
        let isDirectory = ObjCBool((info.st_mode & S_IFMT) == S_IFDIR)
        if isDirectory.boolValue && !NSWorkspace.shared.isFilePackage(atPath: source.path) {
            Log.write("likely", "skip folder \(source.path)")
            return false
        }
        guard isRegular || isDirectory.boolValue else {
            Log.write("likely", "skip non-regular file \(source.path)")
            return false
        }

        let destination = uniqueDestination(for: source.lastPathComponent)
        // COPYFILE_CLONE clones on APFS and falls back to a regular copy elsewhere.
        let flags = copyfile_flags_t(COPYFILE_CLONE) | (isDirectory.boolValue ? copyfile_flags_t(COPYFILE_RECURSIVE) : 0)
        guard copyfile(source.path, destination.path, nil, flags) == 0 else {
            Log.write("likely", "copy failed \(source.path): \(String(cString: strerror(errno)))")
            return false
        }
        Self.copyDateAdded(from: source, to: destination)
        sources.insert(source.path)
        added.append(destination)
        saveManifest()
        Log.write("likely", "added \(source.path)")
        return true
    }

    /// Source paths of the current suggestions, e.g. to tell Claude what the user rejected.
    var suggestedSources: [String] { Array(sources) }

    /// Removes the suggested copies but keeps the status file.
    func clearSuggestions() {
        for url in added { try? fm.removeItem(at: url) }
        added.removeAll()
        sources.removeAll()
        saveManifest()
    }

    func clear() {
        for url in added { try? fm.removeItem(at: url) }
        removeStatusFiles()
        added.removeAll()
        sources.removeAll()
        statusURL = nil
        releasedAt = nil
        saveManifest()
    }

    /// Removes the "…status…" file, e.g. once a search has finished, so it can't be picked by accident.
    func removeStatus() {
        removeStatusFiles()
        statusURL = nil
    }

    /// The current status file, plus strays from a crash ("…" names are only ever Likely's status files).
    private func removeStatusFiles() {
        if let statusURL { try? fm.removeItem(at: statusURL) }
        if let names = try? fm.contentsOfDirectory(atPath: Self.url.path) {
            for name in names where name.hasPrefix("…") {
                try? fm.removeItem(at: Self.url.appendingPathComponent(name))
            }
        }
    }

    /// Copies keep their modification date, but macOS stamps "Date Added" with now. Put the original
    /// back (APFS lets setattrlist write ATTR_CMN_ADDEDTIME) so pickers sorted by Date Added stay useful.
    private static func copyDateAdded(from source: URL, to destination: URL) {
        guard let date = try? source.resourceValues(forKeys: [.addedToDirectoryDateKey]).addedToDirectoryDate else { return }
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_ADDEDTIME)
        let seconds = date.timeIntervalSince1970.rounded(.down)
        var time = timespec(tv_sec: Int(seconds), tv_nsec: Int((date.timeIntervalSince1970 - seconds) * 1_000_000_000))
        if setattrlist(destination.path, &list, &time, MemoryLayout<timespec>.size, 0) != 0 {
            Log.write("likely", "couldn't set Date Added on \(destination.lastPathComponent): \(String(cString: strerror(errno)))")
        }
    }

    private func uniqueDestination(for name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = Self.url.appendingPathComponent(name)
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = Self.url.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }

    private func saveManifest() {
        if let data = try? JSONEncoder().encode(Manifest(paths: added.map(\.path), releasedAt: releasedAt)) {
            try? data.write(to: manifestURL)
        }
    }
}
