import Foundation

/// One file from the "recently added" query, with what's known about how it got there.
public struct RecentItem: Equatable {
    public var path: String
    public var added: Date
    public var modified: Date?
    /// Set when the file was opened (kMDItemLastUsedDate).
    public var lastUsed: Date?
    /// A screenshot or screen recording (kMDItemIsScreenCapture).
    public var isScreenCapture: Bool
    /// Downloaded: it has a source URL (kMDItemWhereFroms).
    public var isDownload: Bool

    public init(path: String, added: Date, modified: Date? = nil, lastUsed: Date? = nil,
                isScreenCapture: Bool = false, isDownload: Bool = false) {
        self.path = path
        self.added = added
        self.modified = modified
        self.lastUsed = lastUsed
        self.isScreenCapture = isScreenCapture
        self.isDownload = isDownload
    }
}

/// How recent files are told apart from files apps write in the background (note vaults, sync
/// tools, build output). Pure logic, so it can be tested without Spotlight.
public enum RecentRules {
    /// Loose files (right in a search folder) that land within this long of each other came in one go
    /// (several files dragged in at once). Chained: each file extends the batch. Files in a folder
    /// inside a search folder (a copied folder, an unzipped archive) are always one batch per folder.
    public static let batchGap: TimeInterval = 2
    /// This many separate arrivals in one folder within `burstWindow` of each other look like an app
    /// writing, not the user saving.
    public static let burstCount = 4
    public static let burstWindow: TimeInterval = 10 * 60
    /// A file never opened but modified this long after it was added is being rewritten by an app.
    public static let rewriteGrace: TimeInterval = 2 * 60

    /// Build output, dependencies and version control: never recent files, whatever their metadata says.
    public static let devFolderNames: Set<String> = [
        "node_modules", "bower_components", ".build", "build", "DerivedData", "Pods", "Carthage",
        ".git", ".hg", ".svn", "dist", "target", "vendor", "venv", ".venv", "__pycache__", ".gradle",
        ".next", ".nuxt", ".cache", ".tox", ".pytest_cache", ".swiftpm", "xcuserdata", ".terraform",
    ]
    /// A folder holding one of these belongs to an app or a project (a note vault, a repo), whose
    /// files change without the user adding them.
    public static let appFolderMarkers = [
        ".obsidian", ".logseq", ".git", ".hg", ".svn", "package.json", "Package.swift", "Cargo.toml",
        "go.mod", "pyproject.toml", "Gemfile", "Podfile", "build.gradle", "pom.xml",
    ]

    public static func isInDevFolder(_ path: String) -> Bool {
        let folders = path.split(separator: "/").dropLast()
        return folders.contains { devFolderNames.contains(String($0)) || $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }
    }

    /// Something only the user does: opened it, took it as a screenshot, or downloaded it.
    public static func hasUserAddedSignal(_ item: RecentItem) -> Bool {
        item.lastUsed != nil || item.isScreenCapture || item.isDownload
    }

    /// Never opened, yet modified well after it was added.
    public static func isStillRewritten(_ item: RecentItem) -> Bool {
        guard item.lastUsed == nil, let modified = item.modified else { return false }
        return modified.timeIntervalSince(item.added) > rewriteGrace
    }

    /// The top-level item of the search folder `path` is in ("~/Desktop/Photos" for anything in it),
    /// or the search folder itself for a file right in it.
    public static func batchKey(_ path: String, roots: [String]) -> String {
        for root in roots.sorted(by: { $0.count > $1.count }) where path.hasPrefix(root + "/") {
            let parts = path.dropFirst(root.count + 1).split(separator: "/", maxSplits: 1)
            return parts.count > 1 ? root + "/" + parts[0] : root
        }
        return (path as NSString).deletingLastPathComponent
    }

    /// Whether `batchKey` is a folder inside a search folder rather than the search folder itself.
    static func isFolderBatch(_ key: String, roots: [String]) -> Bool { !roots.contains(key) && roots.contains { key.hasPrefix($0 + "/") } }

    /// The folders between the search folder `path` is in and the file, nearest first. The search
    /// folder itself isn't included (a marker there would rule out everything).
    public static func foldersBelowRoot(_ path: String, roots: [String]) -> [String] {
        guard let root = roots.filter({ path.hasPrefix($0 + "/") }).max(by: { $0.count < $1.count }) else { return [] }
        var folders: [String] = []
        var folder = (path as NSString).deletingLastPathComponent
        while folder.count > root.count, folder.hasPrefix(root + "/") {
            folders.append(folder)
            folder = (folder as NSString).deletingLastPathComponent
        }
        return folders
    }
}

/// Picks the newest files the user added from query results that arrive newest first.
///
/// A file is kept if it has a user-added signal (opened, a screenshot, a download), or if it arrived
/// on its own, outside app and project folders, and isn't still being rewritten. Each batch (files
/// that came in one go, or one folder inside a search folder) gives at most one entry. Dev and build
/// folders are always skipped.
public final class RecentSelector {
    public enum Verdict: String {
        case picked, sameBatch = "same batch", devFolder = "dev folder", notCandidate = "not a candidate"
        case rewritten = "still being rewritten", appFolder = "in an app or project folder", burst = "part of a burst"
    }

    private let roots: [String]
    private let next: () -> RecentItem?
    private let details: (Int, RecentItem) -> RecentItem
    private let isCandidate: (String) -> Bool
    private let isAppFolder: (String) -> Bool

    private var items: [RecentItem] = []
    /// Per item: its batch (at most one entry each) and its arrival (files that landed together in
    /// one folder, counted for bursts).
    private var batches: [Int] = []
    private var arrivals: [Int] = []
    private var lastInBatchKey: [String: (added: Date, batch: Int)] = [:]
    private var lastInFolder: [String: (added: Date, arrival: Int)] = [:]
    private var exhausted = false
    private var appFolderCache: [String: Bool] = [:]
    /// What was decided about each file looked at, in order (for logs and tests).
    public private(set) var verdicts: [(path: String, verdict: Verdict)] = []

    /// - Parameters:
    ///   - next: the next query result, newest Date Added first; nil when there are no more. Only
    ///     `path` and `added` are needed here.
    ///   - details: the item at a position with the rest of its metadata, read only for the files
    ///     actually judged (most are skipped as part of a batch).
    ///   - isCandidate: whether the file itself is fine to copy (exists, regular, not sensitive…).
    ///   - isAppFolder: whether a folder holds an app's or project's data (see `RecentRules.appFolderMarkers`).
    public init(roots: [String], next: @escaping () -> RecentItem?, details: @escaping (Int, RecentItem) -> RecentItem = { $1 },
                isCandidate: @escaping (String) -> Bool, isAppFolder: @escaping (String) -> Bool) {
        self.roots = roots
        self.next = next
        self.details = details
        self.isCandidate = isCandidate
        self.isAppFolder = isAppFolder
    }

    /// Up to `limit` files, looking closely (`isCandidate` and the folder checks) at no more than `checkLimit`.
    public func select(limit: Int, checkLimit: Int = .max) -> [RecentItem] {
        var picked: [RecentItem] = []
        var pickedBatches = Set<Int>()
        var checked = 0
        var index = 0
        while picked.count < limit, checked < checkLimit, load(upTo: index) {
            defer { index += 1 }
            let item = items[index]
            let verdict: Verdict
            if pickedBatches.contains(batches[index]) {
                verdict = .sameBatch
            } else if RecentRules.isInDevFolder(item.path) {
                verdict = .devFolder
            } else {
                checked += 1
                verdict = judge(index)
            }
            verdicts.append((item.path, verdict))
            if verdict == .picked {
                picked.append(item)
                pickedBatches.insert(batches[index])
            }
        }
        return picked
    }

    private func judge(_ index: Int) -> Verdict {
        guard isCandidate(items[index].path) else { return .notCandidate }
        let item = details(index, items[index])
        if RecentRules.hasUserAddedSignal(item) { return .picked }
        if RecentRules.isStillRewritten(item) { return .rewritten }
        if RecentRules.foldersBelowRoot(item.path, roots: roots).contains(where: cachedIsAppFolder) { return .appFolder }
        if isBurst(index) { return .burst }
        return .picked
    }

    private func cachedIsAppFolder(_ folder: String) -> Bool {
        if let known = appFolderCache[folder] { return known }
        let result = isAppFolder(folder)
        appFolderCache[folder] = result
        return result
    }

    /// Whether `RecentRules.burstCount` separate arrivals landed in this file's folder
    /// within `burstWindow` of it.
    private func isBurst(_ index: Int) -> Bool {
        let item = items[index]
        let folder = (item.path as NSString).deletingLastPathComponent
        var seen: Set<Int> = [arrivals[index]]
        func look(_ other: Int) {
            if (items[other].path as NSString).deletingLastPathComponent == folder { seen.insert(arrivals[other]) }
        }
        // Newer ones (already read), then older ones (read ahead as needed).
        var other = index - 1
        while other >= 0, items[other].added.timeIntervalSince(item.added) <= RecentRules.burstWindow {
            look(other)
            other -= 1
        }
        other = index + 1
        while load(upTo: other), item.added.timeIntervalSince(items[other].added) <= RecentRules.burstWindow {
            look(other)
            if seen.count >= RecentRules.burstCount { break }
            other += 1
        }
        return seen.count >= RecentRules.burstCount
    }

    /// Reads results until `index` is available. False if there aren't that many.
    private func load(upTo index: Int) -> Bool {
        while items.count <= index, !exhausted {
            guard let item = next() else {
                exhausted = true
                break
            }
            let key = RecentRules.batchKey(item.path, roots: roots)
            let batch: Int
            if let last = lastInBatchKey[key],
               RecentRules.isFolderBatch(key, roots: roots) || abs(last.added.timeIntervalSince(item.added)) < RecentRules.batchGap {
                batch = last.batch
            } else {
                batch = items.count
            }
            lastInBatchKey[key] = (item.added, batch)
            let folder = (item.path as NSString).deletingLastPathComponent
            let arrival: Int
            if let last = lastInFolder[folder], abs(last.added.timeIntervalSince(item.added)) < RecentRules.batchGap {
                arrival = last.arrival
            } else {
                arrival = items.count
            }
            lastInFolder[folder] = (item.added, arrival)
            items.append(item)
            batches.append(batch)
            arrivals.append(arrival)
        }
        return index < items.count
    }
}
