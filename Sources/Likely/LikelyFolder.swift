import AppKit
import LikelyTools

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
        dropInFlightCopies()
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

    /// Copies run here, one at a time, so a big file or folder never stalls the picker or the HUD.
    /// Bookkeeping (`added`, `sources`, the manifest) stays on the main thread.
    private let copyQueue = DispatchQueue(label: "inc.synth.likely.copies", qos: .userInitiated)
    /// Bumped whenever the current suggestions are dropped (clear, new feedback, picker closed): a copy
    /// started before that is thrown away instead of being added. Read from the copy queue too.
    private let epochLock = NSLock()
    private var _epoch = 0
    private var epoch: Int { epochLock.lock(); defer { epochLock.unlock() }; return _epoch }
    /// Sources being copied right now (main thread), so a repeated FILE line isn't copied twice.
    private var pending = Set<String>()

    private func dropInFlightCopies() {
        epochLock.lock(); _epoch += 1; epochLock.unlock()
        pending.removeAll()
    }

    /// Waits for the copy in progress (at quit, so a half-written copy isn't left behind; a copy
    /// started for a picker that has closed removes itself).
    func finishCopies() {
        dropInFlightCopies()
        copyQueue.sync {}
    }

    /// Clones `path` into ~/Likely in the background and calls `completion` on the main thread with
    /// whether it was added. Not added: duplicates, missing or sensitive files, devices/sockets/FIFOs,
    /// over-large folders, and copies whose suggestions were dropped meanwhile.
    func add(path: String, completion: @escaping (Bool) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard Self.exists else { return completion(false) }
        let source = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let likelyURL = Self.url
        guard !sources.contains(source.path), !pending.contains(source.path),
              !source.path.hasPrefix(likelyURL.path + "/") else { return completion(false) }
        // Never suggest Likely's own files (e.g. the screenshot an agent was shown).
        guard !source.path.hasPrefix(Self.supportPath) else {
            Log.write("likely", "skip Likely's own file \(source.path)")
            return completion(false)
        }
        // Credentials, keychains, dotfiles, system files: never staged where any picker can grab them.
        // Checked on the real path too (Foundation's resolution drops /private, realpath keeps it), and
        // again on the path of what actually gets opened (see `Copier`).
        let home = fm.homeDirectoryForCurrentUser.path
        if let reason = SensitivePaths.refusalReason(for: source.path, home: home)
            ?? SensitivePaths.refusalReason(for: AgentSandbox.realPath(source.path), home: home) {
            Log.write("likely", "skip sensitive \(source.path) (\(reason))")
            return completion(false)
        }

        pending.insert(source.path)
        let ticket = epoch
        let copier = Copier(likelyURL: likelyURL, home: home, supportPath: Self.supportPath,
                            isCurrent: { [weak self] in self?.epoch == ticket })
        copyQueue.async { [weak self] in
            let copied = copier.isCurrent() ? copier.copy(source) : nil
            // Dropped while copying: remove it here rather than leave it in the folder.
            if let copied, !copier.isCurrent() { try? FileManager.default.removeItem(at: copied) }
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.epoch == ticket else {
                    if let copied { self.copyQueue.async { try? FileManager.default.removeItem(at: copied) } }
                    return completion(false)
                }
                self.pending.remove(source.path)
                guard let copied else { return completion(false) }
                self.sources.insert(source.path)
                self.added.append(copied)
                self.saveManifest()
                completion(true)
            }
        }
    }

    /// Source paths of the current suggestions, e.g. to tell Claude what the user rejected.
    var suggestedSources: [String] { Array(sources) }

    /// Removes the suggested copies but keeps the status file.
    func clearSuggestions() {
        dropInFlightCopies()
        for url in added { try? fm.removeItem(at: url) }
        added.removeAll()
        sources.removeAll()
        saveManifest()
    }

    func clear() {
        dropInFlightCopies()
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

    private func saveManifest() {
        if let data = try? JSONEncoder().encode(Manifest(paths: added.map(\.path), releasedAt: releasedAt)) {
            try? data.write(to: manifestURL)
        }
    }
}

// MARK: - Copying (runs on the copy queue)

extension LikelyFolder {
    /// Folders the user asks for ("the whole K-1 folder") are rebuilt file by file rather than cloned
    /// wholesale, so hidden files, symlinks and anything sensitive inside stay out. Capped so a request
    /// like "all of Documents" can't fill the disk or take ages.
    static let folderFileLimit = 2_000
    static let folderByteLimit: Int64 = 5_000_000_000

    /// Does the copying for `add`. Touches no LikelyFolder state, so it's safe off the main thread.
    ///
    /// The sensitive-path check and the copy can't be done on a path alone: between the two, the file
    /// (or a folder above it) could be swapped for a symlink to ~/.ssh. So each item is opened once
    /// with O_NOFOLLOW (a symlink at the end fails), the real path of what was opened is read back
    /// from the descriptor (F_GETPATH, which catches a swapped parent folder) and checked again, and
    /// the copy is made from that descriptor (fclonefileat, or fcopyfile off APFS).
    struct Copier {
        let likelyURL: URL
        let home: String
        let supportPath: String
        let isCurrent: () -> Bool

        private var fm: FileManager { .default }

        /// Copies a file, package or folder into the Likely folder. Returns the copy, or nil.
        func copy(_ source: URL) -> URL? {
            guard let item = Opened(source.path) else {
                Log.write("likely", "skip missing or unreadable \(source.path)")
                return nil
            }
            defer { close(item.fd) }
            if let reason = refusal(for: item.realPath) {
                Log.write("likely", "skip \(source.path) (opened \(item.realPath): \(reason))")
                return nil
            }
            if item.isDirectory && !NSWorkspace.shared.isFilePackage(atPath: item.realPath) {
                return copyFolder(item, source: source)
            }
            guard item.isRegular || item.isDirectory else {
                Log.write("likely", "skip non-regular file \(source.path)")
                return nil
            }
            guard let destination = clone(item, toFolder: likelyURL, name: source.lastPathComponent) else { return nil }
            Self.copyDateAdded(from: URL(fileURLWithPath: item.realPath), to: destination)
            Log.write("likely", "added \(source.path)")
            return destination
        }

        /// Why `realPath` (what was actually opened) must not be copied, if it mustn't.
        private func refusal(for realPath: String) -> String? {
            if realPath.hasPrefix(supportPath) || realPath.hasPrefix(AgentSandbox.realPath(likelyURL.path) + "/") {
                return "Likely's own file"
            }
            return SensitivePaths.refusalReason(for: realPath, home: home)
        }

        /// Rebuilds a folder file by file: no hidden files, symlinks or sensitive files, and within the caps.
        private func copyFolder(_ folder: Opened, source: URL) -> URL? {
            let root = URL(fileURLWithPath: folder.realPath, isDirectory: true)
            let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .isPackageKey]
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
                Log.write("likely", "skip unreadable folder \(source.path)")
                return nil
            }
            // Plan first: which files go in, and whether the folder is too big.
            var files: [String] = []   // relative to root
            var bytes: Int64 = 0
            for case let entry as URL in walker {
                let values = try? entry.resourceValues(forKeys: Set(keys))
                if values?.isSymbolicLink == true { continue }
                if SensitivePaths.refusalReason(for: entry.path, home: home) != nil {
                    if values?.isDirectory == true { walker.skipDescendants() }
                    continue
                }
                let isPackage = values?.isPackage == true
                if isPackage { walker.skipDescendants() }
                guard isPackage || values?.isRegularFile == true else { continue }
                guard entry.path.hasPrefix(root.path + "/") else { continue }
                files.append(String(entry.path.dropFirst(root.path.count + 1)))
                bytes += Int64(values?.fileSize ?? 0)
                if files.count > LikelyFolder.folderFileLimit || bytes > LikelyFolder.folderByteLimit {
                    Log.write("likely", "skip folder \(source.path): over \(LikelyFolder.folderFileLimit) files or 5 GB")
                    return nil
                }
            }
            guard !files.isEmpty else {
                Log.write("likely", "skip empty folder \(source.path)")
                return nil
            }

            guard let destination = makeUniqueFolder(named: source.lastPathComponent) else { return nil }
            var copiedCount = 0
            for relative in files {
                // Picker closed or suggestions dropped: stop early; `add` removes what was copied.
                guard isCurrent() else { return destination }
                let path = root.path + "/" + relative
                guard let item = Opened(path) else { continue }
                defer { close(item.fd) }
                // The opened file must still be inside the folder and not sensitive (a folder in the
                // path could have been swapped for a symlink since the plan was made).
                guard item.realPath.hasPrefix(root.path + "/"), refusal(for: item.realPath) == nil,
                      item.isRegular || item.isDirectory else {
                    Log.write("likely", "skip \(path) in folder (changed or not allowed)")
                    continue
                }
                let target = destination.appendingPathComponent(relative)
                do {
                    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                } catch {
                    continue
                }
                guard let copied = clone(item, toFolder: target.deletingLastPathComponent(), name: target.lastPathComponent,
                                         unique: false) else { continue }
                Self.copyDateAdded(from: URL(fileURLWithPath: item.realPath), to: copied)
                copiedCount += 1
            }
            guard copiedCount > 0 else {
                try? fm.removeItem(at: destination)
                Log.write("likely", "folder copy failed \(source.path)")
                return nil
            }
            Self.copyDateAdded(from: root, to: destination)
            Log.write("likely", "added folder \(source.path) (\(copiedCount) files)")
            return destination
        }

        /// Copies an opened file or package into `folder` from its descriptor: an APFS clone when
        /// possible, otherwise a regular copy. `unique` picks "name 2" etc. if the name is taken.
        private func clone(_ item: Opened, toFolder folder: URL, name: String, unique: Bool = true) -> URL? {
            var attempt = 1
            while true {
                let destination = folder.appendingPathComponent(unique ? Self.numbered(name, attempt) : name)
                if fclonefileat(item.fd, AT_FDCWD, destination.path, 0) == 0 { return destination }
                let cloneError = errno
                if cloneError == EEXIST && unique && attempt < 1000 { attempt += 1; continue }
                if cloneError == EEXIST { return nil }
                // Not APFS, or across volumes: copy instead, still from the descriptor.
                var copied = false
                if item.isDirectory {
                    // fcopyfile can't copy a folder: copy the package by its opened (already checked)
                    // path, never following symlinks inside it.
                    let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW | COPYFILE_EXCL)
                    copied = copyfile(item.realPath, destination.path, nil, flags) == 0
                } else {
                    let out = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                    if out >= 0 {
                        copied = fcopyfile(item.fd, out, nil, copyfile_flags_t(COPYFILE_ALL)) == 0
                        close(out)
                        if !copied { unlink(destination.path) }
                    }
                }
                if copied { return destination }
                let copyError = errno
                if copyError == EEXIST && unique && attempt < 1000 { attempt += 1; continue }
                Log.write("likely", "copy failed \(item.realPath): \(String(cString: strerror(copyError)))")
                if copyError != EEXIST, item.isDirectory { try? fm.removeItem(at: destination) }
                return nil
            }
        }

        private func makeUniqueFolder(named name: String) -> URL? {
            for attempt in 1..<1000 {
                let destination = likelyURL.appendingPathComponent(Self.numbered(name, attempt))
                if mkdir(destination.path, 0o755) == 0 { return destination }
                if errno != EEXIST {
                    Log.write("likely", "couldn't create \(destination.path): \(String(cString: strerror(errno)))")
                    return nil
                }
            }
            return nil
        }

        /// "Report.pdf", then "Report 2.pdf", "Report 3.pdf"…
        private static func numbered(_ name: String, _ n: Int) -> String {
            guard n > 1 else { return name }
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            return ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
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
            if setattrlist(destination.path, &list, &time, MemoryLayout<timespec>.size, UInt32(FSOPT_NOFOLLOW)) != 0 {
                Log.write("likely", "couldn't set Date Added on \(destination.lastPathComponent): \(String(cString: strerror(errno)))")
            }
        }
    }

    /// A file or folder opened without following a symlink at the end of its path, with what it
    /// really is (fstat) and where it really is (F_GETPATH). The caller closes `fd`.
    struct Opened {
        let fd: Int32
        let realPath: String
        let isRegular: Bool
        let isDirectory: Bool

        init?(_ path: String) {
            // O_NONBLOCK: opening a FIFO mustn't hang (it's rejected right after, by fstat).
            let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { return nil }
            var info = stat()
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard fstat(fd, &info) == 0, fcntl(fd, F_GETPATH, &buffer) != -1 else {
                close(fd)
                return nil
            }
            self.fd = fd
            realPath = String(cString: buffer)
            isRegular = (info.st_mode & S_IFMT) == S_IFREG
            isDirectory = (info.st_mode & S_IFMT) == S_IFDIR
        }
    }
}
