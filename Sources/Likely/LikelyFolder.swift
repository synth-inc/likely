import AppKit
import LikelyTools

/// Manages ~/Likely: APFS clones of candidate files, plus a " …status…" file whose name is the
/// current progress message (the leading space sorts it above everything else in Finder and file
/// pickers). When a picker opens, before anything is searched, it holds the most recently added files
/// under a " …Recent…" header file (see `showRecent`).
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
    /// Copy path → source path, for mapping a picked copy back to the original (evals).
    private var sourceByCopy: [String: String] = [:]
    /// The recent-file clones and their "…Recent…" header (separate from the agent's suggestions,
    /// which replace them once a search starts).
    private var recent: [URL] = []
    private var statusURL: URL?
    /// When the picker these copies were made for closed. Copies outlive the picker, because the app
    /// that opened it often reads the file afterwards (browsers upload it, Mail attaches it); they're
    /// removed when the next picker opens, or once they're `keepAfterClose` old.
    private(set) var releasedAt: Date?

    /// How long copies stay after their picker closed.
    static let keepAfterClose: TimeInterval = 10 * 60

    var count: Int { added.count }

    /// Heads the recent files. Its Date Added is set newer than theirs, so it's on top by Date Added.
    /// By name, Finder's sort (`localizedStandardCompare`) puts a leading space before every
    /// punctuation mark and symbol ("_", "-", "!", "(", "…"), so it's on top by name too.
    static let recentHeaderName = " …Recent…"
    /// Names of earlier versions, removed like the current ones.
    private static let legacyRecentHeaderName = "…Recent…"
    private static let statusPrefix = " …"

    /// Likely's status and header files (current and earlier names).
    private static func isStatusOrHeader(_ name: String) -> Bool { name.hasPrefix("…") || name.hasPrefix(statusPrefix) }
    private static func isRecentHeader(_ name: String) -> Bool { name == recentHeaderName || name == legacyRecentHeaderName }

    private struct Manifest: Codable {
        var paths: [String]
        var releasedAt: Date?
        var recent: [String]?
    }

    init(supportDirectory: URL) {
        manifestURL = supportDirectory.appendingPathComponent("likely-manifest.json")
        if let data = try? Data(contentsOf: manifestURL) {
            if let manifest = try? JSONDecoder().decode(Manifest.self, from: data) {
                added = manifest.paths.map { URL(fileURLWithPath: $0) }
                recent = (manifest.recent ?? []).map { URL(fileURLWithPath: $0) }
                releasedAt = manifest.releasedAt
            } else if let paths = try? JSONDecoder().decode([String].self, from: data) {
                added = paths.map { URL(fileURLWithPath: $0) }   // older format
            }
        }
        // Copies made just before a crash, before they were in the manifest.
        removeUnlistedCopies()
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
        if !added.isEmpty || !recent.isEmpty { releasedAt = Date() }
        saveManifest()
    }

    /// Seconds until released copies should go, or nil if there's nothing to keep (none, not
    /// released, or already old enough).
    var remainingKeepTime: TimeInterval? {
        guard !added.isEmpty || !recent.isEmpty, let releasedAt else { return nil }
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
        let target = Self.url.appendingPathComponent("\(Self.statusPrefix)\(text)…")
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
    /// The recent-files query, so it never waits behind a big copy (and vice versa).
    private let recentQueue = DispatchQueue(label: "inc.synth.likely.recent", qos: .userInitiated)
    /// Bumped whenever the current suggestions are dropped (clear, new feedback, picker closed): a copy
    /// started before that is thrown away instead of being added. Read from the copy queue too.
    private let epochLock = NSLock()
    private var _epoch = 0
    private var epoch: Int { epochLock.lock(); defer { epochLock.unlock() }; return _epoch }
    /// The same for the recent files, which outlive "Not these" but not the start of a search.
    private var _recentEpoch = 0
    private var recentEpoch: Int { epochLock.lock(); defer { epochLock.unlock() }; return _recentEpoch }
    /// Copies made on the copy queue but not yet handed to the main thread (guarded by `epochLock`).
    /// Each copy is staged under the lock only if its epoch is still current, and dropping the epoch
    /// takes and removes whatever is staged, so every copy is removed exactly once: by its own job
    /// (dropped before it was staged) or by the drop (dropped after).
    private var staged: [Made] = []
    private var stagedRecent: [Made] = []
    /// Sources being copied right now (main thread), so a repeated FILE line isn't copied twice.
    private var pending = Set<String>()

    private func dropInFlightCopies(includingRecent: Bool = true) {
        epochLock.lock()
        _epoch += 1
        var dropped = staged
        staged.removeAll()
        if includingRecent {
            _recentEpoch += 1
            dropped += stagedRecent
            stagedRecent.removeAll()
        }
        epochLock.unlock()
        dropped.forEach { $0.remove() }
        pending.removeAll()
    }

    private func dropInFlightRecent() {
        epochLock.lock()
        _recentEpoch += 1
        let dropped = stagedRecent
        stagedRecent.removeAll()
        epochLock.unlock()
        dropped.forEach { $0.remove() }
    }

    /// Copy queue: hands `made` to the main thread if `ticket` is still current. False if it was
    /// dropped meanwhile; the caller removes it then.
    private func stage(_ made: Made, ticket: Int, recent: Bool) -> Bool {
        epochLock.lock(); defer { epochLock.unlock() }
        guard (recent ? _recentEpoch : _epoch) == ticket else { return false }
        if recent { stagedRecent.append(made) } else { staged.append(made) }
        return true
    }

    /// Main thread: takes a staged copy over. False if a drop already took (and removed) it.
    private func unstage(_ made: Made, recent: Bool) -> Bool {
        epochLock.lock(); defer { epochLock.unlock() }
        if recent {
            guard let index = stagedRecent.firstIndex(of: made) else { return false }
            stagedRecent.remove(at: index)
        } else {
            guard let index = staged.firstIndex(of: made) else { return false }
            staged.remove(at: index)
        }
        return true
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
        let screened = Self.screen(path: path)
        let source = screened.source
        let likelyURL = Self.url
        guard !sources.contains(source.path), !pending.contains(source.path) else { return completion(false) }
        if let reason = screened.refusal {
            if reason != "in the Likely folder" { Log.write("likely", "skip \(source.path) (\(reason))") }
            return completion(false)
        }
        let home = fm.homeDirectoryForCurrentUser.path

        pending.insert(source.path)
        let ticket = epoch
        let copier = Copier(likelyURL: likelyURL, home: home, supportPath: Self.supportPath,
                            isCurrent: { [weak self] in self?.epoch == ticket })
        copyQueue.async { [weak self] in
            let made = (copier.isCurrent() ? copier.copy(source) : nil).flatMap(Made.init)
            let kept = made.map { self?.stage($0, ticket: ticket, recent: false) == true } ?? false
            // Dropped while copying: remove it here, the only place that will.
            if let made, !kept { made.remove() }
            DispatchQueue.main.async {
                guard let self else { return }
                if self.epoch == ticket { self.pending.remove(source.path) }
                guard let made, kept, self.unstage(made, recent: false) else { return completion(false) }
                self.sources.insert(source.path)
                self.sourceByCopy[made.url.path] = source.path
                self.added.append(made.url)
                self.saveManifest()
                completion(true)
            }
        }
    }

    /// Source paths of the current suggestions, e.g. to tell Claude what the user rejected.
    var suggestedSources: [String] { Array(sources) }

    /// The path a FILE: line stands for (symlinks resolved), and why Likely wouldn't show it, if it
    /// wouldn't. Shared with the eval runner, which records suggestions without copying anything.
    /// (What actually gets copied is checked again when it's opened; see `Copier`.)
    /// The real path an agent meant when its spelling differs only in look-alike characters.
    /// macOS puts a narrow no-break space (U+202F) before AM/PM in screenshot names, and agents
    /// write it back as a plain space; other names carry no-break spaces or decomposed accents.
    /// Each missing component is matched against its folder's entries with those differences
    /// evened out. Returns `path` unchanged if it exists or nothing matches.
    static func existingPath(for path: String) -> String {
        let fm = FileManager.default
        if fm.fileExists(atPath: path) { return path }
        func key(_ name: String) -> String {
            let spaced = name.unicodeScalars.map { CharacterSet.whitespaces.contains($0) ? " " : String($0) }.joined()
            return spaced.precomposedStringWithCanonicalMapping.lowercased()
        }
        var resolved = "/"
        for component in (path as NSString).pathComponents.dropFirst() {
            let direct = (resolved as NSString).appendingPathComponent(component)
            if fm.fileExists(atPath: direct) { resolved = direct; continue }
            let wanted = key(component)
            guard let match = (try? fm.contentsOfDirectory(atPath: resolved))?.first(where: { key($0) == wanted }) else { return path }
            resolved = (resolved as NSString).appendingPathComponent(match)
        }
        Log.write("likely", "matched \(path) to \(resolved)")
        return resolved
    }

    static func screen(path: String) -> (source: URL, refusal: String?) {
        let source = URL(fileURLWithPath: existingPath(for: (path as NSString).expandingTildeInPath)).resolvingSymlinksInPath()
        if source.path.hasPrefix(url.path + "/") { return (source, "in the Likely folder") }
        // Never suggest Likely's own files (e.g. the screenshot an agent was shown).
        if source.path.hasPrefix(supportPath) { return (source, "Likely's own file") }
        // Credentials, keychains, dotfiles, system files: never staged where any picker can grab them.
        // Checked on the real path too (Foundation's resolution drops /private, realpath keeps it), and
        // again on the path of what actually gets opened (see `Copier`).
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if let reason = SensitivePaths.refusalReason(for: source.path, home: home)
            ?? SensitivePaths.refusalReason(for: AgentSandbox.realPath(source.path), home: home) {
            return (source, "sensitive: \(reason)")
        }
        return (source, nil)
    }

    /// Where a file picked from the Likely folder came from: copies (and files inside copied
    /// folders) map back to their source. Nil if `picked` isn't one of the current copies.
    func sourcePath(forPicked picked: URL) -> String? {
        let path = picked.resolvingSymlinksInPath().path
        for (copy, source) in sourceByCopy {
            let resolvedCopy = URL(fileURLWithPath: copy).resolvingSymlinksInPath().path
            if path == resolvedCopy { return source }
            if path.hasPrefix(resolvedCopy + "/") { return source + path.dropFirst(resolvedCopy.count) }
        }
        return nil
    }

    /// Removes the suggested copies but keeps the status file (and the recent files).
    func clearSuggestions() {
        dropInFlightCopies(includingRecent: false)
        for url in added { try? fm.removeItem(at: url) }
        added.removeAll()
        sources.removeAll()
        sourceByCopy.removeAll()
        saveManifest()
    }

    func clear() {
        dropInFlightCopies()
        for url in added + recent { try? fm.removeItem(at: url) }
        removeStatusFiles(includingRecentHeader: true)
        added.removeAll()
        sources.removeAll()
        sourceByCopy.removeAll()
        recent.removeAll()
        statusURL = nil
        releasedAt = nil
        saveManifest()
    }

    /// Removes the "…status…" file, e.g. once a search has finished, so it can't be picked by accident.
    func removeStatus() {
        removeStatusFiles()
        statusURL = nil
    }

    /// The current status file, plus strays from a crash (" …" and "…" names are only ever Likely's
    /// status files and the recent-files header, which stays unless `includingRecentHeader`).
    private func removeStatusFiles(includingRecentHeader: Bool = false) {
        if let statusURL { try? fm.removeItem(at: statusURL) }
        if let names = try? fm.contentsOfDirectory(atPath: Self.url.path) {
            for name in names where Self.isStatusOrHeader(name) && (includingRecentHeader || !Self.isRecentHeader(name)) {
                try? fm.removeItem(at: Self.url.appendingPathComponent(name))
            }
        }
    }

    /// Copies Likely made (see `Copier.tag`) that the manifest doesn't list: made just before a crash
    /// or quit, before the main thread recorded them.
    private func removeUnlistedCopies() {
        let listed = Set((added + recent).map { $0.standardizedFileURL.path })
        guard let names = try? fm.contentsOfDirectory(atPath: Self.url.path) else { return }
        for name in names {
            let url = Self.url.appendingPathComponent(name)
            guard Copier.isTagged(url), !listed.contains(url.standardizedFileURL.path) else { continue }
            try? fm.removeItem(at: url)
            Log.write("likely", "removed unlisted copy \(name)")
        }
    }

    // MARK: Recent files

    /// Clones the `limit` files added most recently under `roots` (see `RecentFiles`) into the folder,
    /// with a "…Recent…" header above them, in the background through the same checked copy path as
    /// the agent's suggestions. `completion` runs on the main thread with the query result and the
    /// source paths that were actually cloned.
    func showRecent(limit: Int, roots: [URL], completion: @escaping (RecentFiles.Result, [String]) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard Self.exists else { return }
        let likelyURL = Self.url
        let home = fm.homeDirectoryForCurrentUser.path
        let ticket = recentEpoch
        let copier = Copier(likelyURL: likelyURL, home: home, supportPath: Self.supportPath,
                            isCurrent: { [weak self] in self?.recentEpoch == ticket })
        recentQueue.async { [weak self] in
            let result = RecentFiles.find(limit: limit, roots: roots, excluding: [likelyURL.path, Self.supportPath], home: home,
                                          sameVolumeAs: likelyURL.path)
            guard copier.isCurrent(), let queue = self?.copyQueue else {
                return DispatchQueue.main.async { completion(result, []) }
            }
            queue.async { [weak self] in
                // Each copy is staged as soon as it's made (see `stage`); once one is refused, the
                // rest would be too.
                func keep(_ url: URL) -> Made? {
                    guard let made = Made(url) else { return nil }
                    if self?.stage(made, ticket: ticket, recent: true) == true { return made }
                    made.remove()
                    return nil
                }
                var copies: [(source: String, made: Made)] = []
                for file in result.files where copier.isCurrent() {
                    guard let copy = copier.copy(URL(fileURLWithPath: file.path)) else { continue }
                    guard let made = keep(copy) else { break }
                    copies.append((file.path, made))
                }
                var header: Made?
                if !copies.isEmpty, copier.isCurrent(),
                   let url = Copier.makeHeader(named: Self.recentHeaderName, in: likelyURL,
                                               newerThan: result.files.map(\.added).max() ?? Date()) {
                    header = keep(url)
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    let kept = copies.filter { self.unstage($0.made, recent: true) }
                    self.recent += kept.map(\.made.url)
                    if let header, self.unstage(header, recent: true) { self.recent.append(header.url) }
                    self.saveManifest()
                    completion(result, kept.map(\.source))
                }
            }
        }
    }

    /// Removes the recent files and their header, e.g. when a typed search starts, so its results
    /// aren't mixed with them.
    func clearRecent() {
        dropInFlightRecent()
        for url in recent { try? fm.removeItem(at: url) }
        recent.removeAll()
        saveManifest()
    }

    private func saveManifest() {
        if let data = try? JSONEncoder().encode(Manifest(paths: added.map(\.path), releasedAt: releasedAt,
                                                          recent: recent.map(\.path))) {
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
                if fclonefileat(item.fd, AT_FDCWD, destination.path, 0) == 0 { return tagged(destination, unique) }
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
                if copied { return tagged(destination, unique) }
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
                if mkdir(destination.path, 0o755) == 0 { return Self.tag(destination) }
                if errno != EEXIST {
                    Log.write("likely", "couldn't create \(destination.path): \(String(cString: strerror(errno)))")
                    return nil
                }
            }
            return nil
        }

        /// Top-level copies (`unique`) are tagged; files inside a copied folder go with the folder.
        private func tagged(_ url: URL, _ topLevel: Bool) -> URL { topLevel ? Self.tag(url) : url }

        private static let tagName = "inc.synth.likely.copy"

        /// Marks something Likely made in the Likely folder, so a copy made just before a crash (not
        /// yet in the manifest) is recognized and removed at the next launch. The value is the item's
        /// inode, so a Finder duplicate of it (which keeps extended attributes) isn't mistaken for one.
        @discardableResult
        static func tag(_ url: URL) -> URL {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return url }
            let value = Array(String(info.st_ino).utf8)
            if setxattr(url.path, tagName, value, value.count, 0, XATTR_NOFOLLOW) != 0 {
                Log.write("likely", "couldn't tag \(url.lastPathComponent): \(String(cString: strerror(errno)))")
            }
            return url
        }

        static func isTagged(_ url: URL) -> Bool {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return false }
            var buffer = [UInt8](repeating: 0, count: 32)
            let length = getxattr(url.path, tagName, &buffer, buffer.count, 0, XATTR_NOFOLLOW)
            guard length > 0 else { return false }
            return String(decoding: buffer.prefix(length), as: UTF8.self) == String(info.st_ino)
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
            setDateAdded(date, on: destination)
        }

        /// An empty placeholder file (like the status file) whose Date Added is just after `date`, so it
        /// lists above files added up to then when a picker sorts by Date Added. Never reuses an
        /// existing file (O_EXCL), so it only ever returns a file this call made.
        static func makeHeader(named name: String, in folder: URL, newerThan date: Date) -> URL? {
            let url = folder.appendingPathComponent(name)
            let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
            guard fd >= 0 else {
                Log.write("likely", "couldn't create \(name): \(String(cString: strerror(errno)))")
                return nil
            }
            close(fd)
            setDateAdded(max(Date(), date.addingTimeInterval(1)), on: url)
            return tag(url)
        }

        static func setDateAdded(_ date: Date, on destination: URL) {
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

    /// A copy (or header) as made: its path and which file it is (device and inode), so removing it
    /// later can't remove a same-named file made since, e.g. by the next picker.
    struct Made: Equatable {
        let url: URL
        let device: dev_t
        let inode: ino_t

        init?(_ url: URL) {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return nil }
            self.url = url
            device = info.st_dev
            inode = info.st_ino
        }

        /// Removes it if the path still holds this very file.
        func remove() {
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_dev == device, info.st_ino == inode else { return }
            try? FileManager.default.removeItem(at: url)
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
