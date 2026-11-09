import CoreServices
import Foundation
#if canImport(RecentFilesCore)
import RecentFilesCore
#endif

/// The files the user added most recently (newest "Date Added", what Finder shows: downloads, saves,
/// moves, screenshots) inside the search folders. Often exactly what a picker is opened for.
/// Files apps write in the background (note vaults, sync tools, build output) are left out; see
/// `RecentSelector`. Foundation + CoreServices only, so scripts/recent-files.sh can run it outside the app.
enum RecentFiles {
    struct Result {
        var files: [(path: String, added: Date)]
        /// "spotlight", "folders" (the fallback) or "none".
        var source: String
        var milliseconds: Int
        /// Files looked at and why each was or wasn't picked (for the log).
        var verdicts: [(path: String, verdict: String)] = []
    }

    /// In-progress downloads and other half-written files.
    static let partialExtensions: Set<String> = ["crdownload", "download", "part", "partial", "opdownload"]
    /// Bigger files aren't worth cloning for a guess (and wouldn't clone at all across volumes).
    static let maxBytes: Int64 = 500_000_000

    /// Spotlight windows tried in turn, so the usual query (something added in the last hour or day)
    /// only has to sort a few hundred items.
    private static let windows: [TimeInterval] = [3_600, 86_400, 30 * 86_400]
    /// Per query: results read at most, and files checked at most (each check is an lstat and a realpath).
    private static let readLimit = 5_000
    private static let checkLimit = 200

    /// Not exported as a constant by CoreServices.
    private static let kMDItemIsScreenCapture = "kMDItemIsScreenCapture" as CFString
    private static let attributes = [kMDItemDateAdded, kMDItemContentModificationDate, kMDItemLastUsedDate,
                                     kMDItemIsScreenCapture, kMDItemWhereFroms] as CFArray

    /// The `limit` newest files under `roots`, never inside `excluded` folders (the Likely folder,
    /// Likely's support folder), hidden, dev or sensitive places, still downloading, over `maxBytes`,
    /// or (with `sameVolumeAs`) on a different volume from that folder. Blocks; run it off the main
    /// thread. Typically 20–100 ms.
    static func find(limit: Int, roots: [URL], excluding excluded: [String], home: String, sameVolumeAs volumePath: String? = nil) -> Result {
        let start = Date()
        let excluded = excluded.flatMap { [standardized($0), realPath($0)] }.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        let roots = roots.filter { FileManager.default.fileExists(atPath: $0.path) }.map { standardized($0.path) }
        var device: dev_t?
        var info = stat()
        if let volumePath, stat(volumePath, &info) == 0 { device = info.st_dev }
        let isCandidate = { (path: String) in Self.isCandidate(path, excluded: excluded, home: home, device: device) }
        var (files, verdicts) = spotlight(limit: limit, roots: roots, isCandidate: isCandidate)
        var source = "spotlight"
        if files.isEmpty {
            (files, verdicts) = topLevel(limit: limit, roots: roots, home: home, isCandidate: isCandidate)
            source = files.isEmpty ? "none" : "folders"
        }
        return Result(files: files.map { ($0.path, $0.added) }, source: source,
                      milliseconds: Int(Date().timeIntervalSince(start) * 1000),
                      verdicts: verdicts.map { ($0.path, $0.verdict.rawValue) })
    }

    private typealias Picked = (files: [RecentItem], verdicts: [(path: String, verdict: RecentSelector.Verdict)])

    private static func spotlight(limit: Int, roots: [String], isCandidate: @escaping (String) -> Bool) -> Picked {
        guard !roots.isEmpty else { return ([], []) }
        var found: Picked = ([], [])
        for window in windows {
            // Folders are filtered here; packages and everything else in `isCandidate`.
            let text = "kMDItemDateAdded >= $time.now(-\(Int(window))) && kMDItemContentType != \"public.folder\""
            guard let query = MDQueryCreate(kCFAllocatorDefault, text as CFString, attributes, [kMDItemDateAdded] as CFArray) else { continue }
            MDQuerySetSearchScope(query, roots as CFArray, 0)
            MDQuerySetSortOptionFlagsForAttribute(query, kMDItemDateAdded, UInt32(kMDQueryReverseSortOrderFlag.rawValue))
            // No MDQuerySetMaxCount: it cuts the results before they're sorted.
            guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { continue }
            let count = min(MDQueryGetResultCount(query), readLimit)
            func item(at index: CFIndex) -> MDItem? {
                MDQueryGetResultAtIndex(query, index).map { Unmanaged<MDItem>.fromOpaque($0).takeUnretainedValue() }
            }
            var index = 0
            var queryIndex: [CFIndex] = []   // position handed to the selector → result index
            let selector = RecentSelector(roots: roots, next: {
                while index < count {
                    defer { index += 1 }
                    // Stored attributes come straight from the query, far faster than MDItemCopyAttribute
                    // (but the path isn't stored, so it's read from the item).
                    guard let added = value(query, kMDItemDateAdded, index) as? Date, let item = item(at: index),
                          let path = MDItemCopyAttribute(item, kMDItemPath) as? String else { continue }
                    queryIndex.append(index)
                    return RecentItem(path: path, added: added)
                }
                return nil
            }, details: { position, partial in
                let index = queryIndex[position]
                var full = partial
                full.modified = value(query, kMDItemContentModificationDate, index) as? Date
                full.lastUsed = value(query, kMDItemLastUsedDate, index) as? Date
                full.isScreenCapture = (value(query, kMDItemIsScreenCapture, index) as? Bool) == true
                full.isDownload = !((value(query, kMDItemWhereFroms, index) as? [String]) ?? []).isEmpty
                return full
            }, isCandidate: isCandidate, isAppFolder: isAppFolder)
            found = (selector.select(limit: limit, checkLimit: checkLimit), selector.verdicts)
            if found.files.count == limit { return found }
        }
        return found
    }

    private static func value(_ query: MDQuery, _ attribute: CFString, _ index: CFIndex) -> Any? {
        MDQueryGetAttributeValueOfResultAtIndex(query, attribute, index).map { Unmanaged<AnyObject>.fromOpaque($0).takeUnretainedValue() }
    }

    /// Spotlight off or not indexed yet: the top level of Desktop, Downloads and Documents. The
    /// user-added signals come from the extended attributes Spotlight would have read them from.
    private static func topLevel(limit: Int, roots: [String], home: String, isCandidate: @escaping (String) -> Bool) -> Picked {
        let folders = ["Desktop", "Downloads", "Documents"].map { standardized(home + "/" + $0) }.filter(roots.contains)
        var found: [RecentItem] = []
        let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .contentModificationDateKey]
        for folder in folders {
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: folder), includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
            for entry in entries {
                guard let values = try? entry.resourceValues(forKeys: Set(keys)), let added = values.addedToDirectoryDate else { continue }
                found.append(RecentItem(path: entry.path, added: added, modified: values.contentModificationDate,
                                        lastUsed: hasXattr(entry.path, "com.apple.lastuseddate#PS") ? added : nil,
                                        isScreenCapture: hasXattr(entry.path, "com.apple.metadata:kMDItemIsScreenCapture"),
                                        isDownload: hasXattr(entry.path, "com.apple.metadata:kMDItemWhereFroms")))
            }
        }
        var iterator = found.sorted { $0.added > $1.added }.makeIterator()
        let selector = RecentSelector(roots: roots, next: { iterator.next() }, isCandidate: isCandidate, isAppFolder: isAppFolder)
        return (selector.select(limit: limit, checkLimit: checkLimit), selector.verdicts)
    }

    /// A plain, non-empty, fully downloaded file the copy pipeline would accept.
    static func isCandidate(_ path: String, excluded: [String], home: String, device: dev_t? = nil) -> Bool {
        let name = (path as NSString).lastPathComponent
        guard !name.hasPrefix("."), !partialExtensions.contains((name as NSString).pathExtension.lowercased()) else { return false }
        // Hidden folders (.Trash, .git), ~/Library (except iCloud Drive / CloudStorage), keychains, system places.
        guard SensitivePaths.refusalReason(for: path, home: home) == nil else { return false }
        guard !excluded.contains(where: { path.hasPrefix($0) }) else { return false }
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size > 0, Int64(info.st_size) <= maxBytes,
              info.st_flags & 0x4000_0000 == 0   // SF_DATALESS: an iCloud / File Provider placeholder
        else { return false }
        // Another volume: a full copy rather than a clone, and gone when the disk is ejected.
        if let device, info.st_dev != device { return false }
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

    /// Whether `folder` holds an app's or project's data (an Obsidian vault, a repo, a package).
    private static func isAppFolder(_ folder: String) -> Bool {
        RecentRules.appFolderMarkers.contains { marker in
            var info = stat()
            return lstat(folder + "/" + marker, &info) == 0
        }
    }

    private static func hasXattr(_ path: String, _ name: String) -> Bool {
        getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    private static func standardized(_ path: String) -> String { (path as NSString).standardizingPath }

    private static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
