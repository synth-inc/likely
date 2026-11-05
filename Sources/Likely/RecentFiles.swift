import CoreServices
import Foundation

/// The files the user added most recently (newest "Date Added", what Finder shows: downloads, saves,
/// moves, screenshots) inside the search folders. Often exactly what a picker is opened for.
/// Foundation + CoreServices only, so scripts/recent-files.sh can run it outside the app.
enum RecentFiles {
    struct Result {
        var files: [(path: String, added: Date)]
        /// "spotlight", "folders" (the fallback) or "none".
        var source: String
        var milliseconds: Int
    }

    /// In-progress downloads and other half-written files.
    static let partialExtensions: Set<String> = ["crdownload", "download", "part", "partial", "opdownload"]

    /// Spotlight windows tried in turn, so the usual query (something added in the last hour or day)
    /// only has to sort a few hundred items.
    private static let windows: [TimeInterval] = [3_600, 86_400, 30 * 86_400]
    /// Per query: results read at most, and files checked at most (each check is an lstat and a realpath).
    private static let readLimit = 5_000
    private static let checkLimit = 200

    /// The `limit` newest files under `roots`, never inside `excluded` folders (the Likely folder,
    /// Likely's support folder), hidden or sensitive places, or still downloading. Blocks; run it
    /// off the main thread. Typically 20–100 ms.
    static func find(limit: Int, roots: [URL], excluding excluded: [String], home: String) -> Result {
        let start = Date()
        let excluded = excluded.flatMap { [standardized($0), realPath($0)] }.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        let roots = roots.filter { FileManager.default.fileExists(atPath: $0.path) }
        var files = spotlight(limit: limit, roots: roots, excluded: excluded, home: home)
        var source = "spotlight"
        if files.isEmpty {
            files = topLevel(limit: limit, roots: roots, excluded: excluded, home: home)
            source = files.isEmpty ? "none" : "folders"
        }
        return Result(files: files, source: source, milliseconds: Int(Date().timeIntervalSince(start) * 1000))
    }

    private static func spotlight(limit: Int, roots: [URL], excluded: [String], home: String) -> [(path: String, added: Date)] {
        guard !roots.isEmpty else { return [] }
        var found: [(path: String, added: Date)] = []
        for window in windows {
            // Folders are filtered here; packages and everything else in `isCandidate`.
            let text = "kMDItemDateAdded >= $time.now(-\(Int(window))) && kMDItemContentType != \"public.folder\""
            guard let query = MDQueryCreate(kCFAllocatorDefault, text as CFString,
                                            [kMDItemPath, kMDItemDateAdded] as CFArray, [kMDItemDateAdded] as CFArray) else { continue }
            MDQuerySetSearchScope(query, roots.map(\.path) as CFArray, 0)
            MDQuerySetSortOptionFlagsForAttribute(query, kMDItemDateAdded, UInt32(kMDQueryReverseSortOrderFlag.rawValue))
            // No MDQuerySetMaxCount: it cuts the results before they're sorted.
            guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { continue }
            found = []
            var checked = 0
            for index in 0..<min(MDQueryGetResultCount(query), readLimit) where checked < checkLimit {
                guard let raw = MDQueryGetResultAtIndex(query, index) else { continue }
                let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
                guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String,
                      let added = MDItemCopyAttribute(item, kMDItemDateAdded) as? Date,
                      !isSameBatch(path, added, as: found, roots: roots) else { continue }
                checked += 1
                guard isCandidate(path, excluded: excluded, home: home) else { continue }
                found.append((path, added))
                if found.count == limit { return found }
            }
        }
        return found
    }

    /// Spotlight off or not indexed yet: the top level of Desktop, Downloads and Documents.
    private static func topLevel(limit: Int, roots: [URL], excluded: [String], home: String) -> [(path: String, added: Date)] {
        let homeURL = URL(fileURLWithPath: home, isDirectory: true)
        let folders = ["Desktop", "Downloads", "Documents"].map { homeURL.appendingPathComponent($0) }
            .filter { folder in roots.contains { $0.standardizedFileURL.path == folder.path } }
        var found: [(path: String, added: Date)] = []
        for folder in folders {
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.addedToDirectoryDateKey], options: [.skipsHiddenFiles])) ?? []
            for entry in entries {
                guard let added = try? entry.resourceValues(forKeys: [.addedToDirectoryDateKey]).addedToDirectoryDate,
                      isCandidate(entry.path, excluded: excluded, home: home) else { continue }
                found.append((entry.path, added))
            }
        }
        var picked: [(path: String, added: Date)] = []
        for file in found.sorted(by: { $0.added > $1.added }) where !isSameBatch(file.path, file.added, as: picked, roots: roots) {
            picked.append(file)
            if picked.count == limit { break }
        }
        return picked
    }

    /// Files that landed within a second or two of one already picked, under the same top-level item
    /// of a search folder, came in one go (a copied folder, an unzipped archive, a clone): one of them
    /// stands for the rest.
    private static func isSameBatch(_ path: String, _ added: Date, as found: [(path: String, added: Date)], roots: [URL]) -> Bool {
        let key = batchKey(path, roots: roots)
        return found.contains { abs($0.added.timeIntervalSince(added)) < 2 && batchKey($0.path, roots: roots) == key }
    }

    /// The top-level item of the search folder `path` is in ("~/Desktop/Photos" for anything in it).
    private static func batchKey(_ path: String, roots: [URL]) -> String {
        for root in roots.map(\.path) where path.hasPrefix(root + "/") {
            let parts = path.dropFirst(root.count + 1).split(separator: "/", maxSplits: 1)
            return parts.count > 1 ? root + "/" + parts[0] : root
        }
        return (path as NSString).deletingLastPathComponent
    }

    /// A plain, non-empty, fully downloaded file the copy pipeline would accept.
    static func isCandidate(_ path: String, excluded: [String], home: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        guard !name.hasPrefix("."), !partialExtensions.contains((name as NSString).pathExtension.lowercased()) else { return false }
        // Hidden folders (.Trash, .git), ~/Library (except iCloud Drive / CloudStorage), keychains, system places.
        guard SensitivePaths.refusalReason(for: path, home: home) == nil else { return false }
        guard !excluded.contains(where: { path.hasPrefix($0) }) else { return false }
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size > 0,
              info.st_flags & 0x4000_0000 == 0   // SF_DATALESS: an iCloud / File Provider placeholder
        else { return false }
        // A file inside a package (an .app, a .photoslibrary, a .key bundle) isn't something to upload.
        var parent = (path as NSString).deletingLastPathComponent
        while parent.count > 1 {
            if !(parent as NSString).pathExtension.isEmpty,
               (try? URL(fileURLWithPath: parent).resourceValues(forKeys: [.isPackageKey]).isPackage) == true { return false }
            parent = (parent as NSString).deletingLastPathComponent
        }
        let real = realPath(path)
        guard !excluded.contains(where: { real.hasPrefix($0) }),
              SensitivePaths.refusalReason(for: real, home: home) == nil else { return false }
        return true
    }

    private static func standardized(_ path: String) -> String { (path as NSString).standardizingPath }

    private static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
