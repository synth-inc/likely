import Foundation
import LikelyStorage

/// One eval case: what the user typed (and where), and which file(s) they actually wanted.
/// Stored one per line in a JSON Lines file. The format is documented in docs/EVALS.md.
public struct EvalCase: Codable, Identifiable, Hashable {
    public var id: String
    /// Successive user messages. The first starts the search; each later one is sent as feedback
    /// ("not these, …"), like typing again in the bar above the picker. Encoded as a plain string
    /// when there's only one.
    public var query: [String]
    public var context: Context?
    public var expect: Expectation
    public var tags: [String]
    /// "manual", "captured", "history" or "fixture".
    public var source: String?
    public var notes: String?
    /// ISO 8601.
    public var createdAt: String?
    /// Optional: tell the agent to search only these folders (relative paths resolve against the
    /// cases file's folder). The fixture suite uses this; it also turns on isolation (see EVALS.md).
    public var searchFolders: [String]?

    public struct Context: Codable, Hashable {
        /// Name of the app that opened the picker, e.g. "Google Chrome".
        public var app: String?
        /// Title of the window behind the picker.
        public var windowTitle: String?
        /// Optional path to a screenshot of that window. Without one, the case runs input-first.
        public var screenshot: String?
        /// The picker's confirm button ("Open", "Upload", …), if known.
        public var button: String?
        /// The user's name, sent as `{{userName}}`. Unset: personal cases send no name; fixture cases
        /// (`source: "fixture"`) use the synthetic persona, "Jordan Rivera".
        public var userName: String?
        /// Whether the agent gets the user's tools (tools.json) for this case. Unset: personal cases
        /// do, fixture cases don't unless the run passes `--with-tools` (see EvalToolPolicy).
        public var useTools: Bool?

        public init(app: String? = nil, windowTitle: String? = nil, screenshot: String? = nil, button: String? = nil,
                    userName: String? = nil, useTools: Bool? = nil) {
            self.app = app
            self.windowTitle = windowTitle
            self.screenshot = screenshot
            self.button = button
            self.userName = userName
            self.useTools = useTools
        }

        public var isEmpty: Bool {
            app == nil && windowTitle == nil && screenshot == nil && button == nil && userName == nil && useTools == nil
        }
    }

    public init(id: String, query: [String], context: Context? = nil, expect: Expectation, tags: [String] = [],
                source: String? = "manual", notes: String? = nil, createdAt: String? = EvalCase.now(),
                searchFolders: [String]? = nil) {
        self.id = id
        self.query = query
        self.context = context
        self.expect = expect
        self.tags = tags
        self.source = source
        self.notes = notes
        self.createdAt = createdAt
        self.searchFolders = searchFolders
    }

    private enum CodingKeys: String, CodingKey {
        case id, query, context, expect, tags, source, notes, createdAt, searchFolders
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        if let single = try? c.decode(String.self, forKey: .query) {
            query = [single]
        } else {
            query = try c.decodeIfPresent([String].self, forKey: .query) ?? []
        }
        context = try c.decodeIfPresent(Context.self, forKey: .context)
        expect = try c.decodeIfPresent(Expectation.self, forKey: .expect) ?? Expectation()
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        source = try c.decodeIfPresent(String.self, forKey: .source)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        searchFolders = try c.decodeIfPresent([String].self, forKey: .searchFolders)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        if query.count == 1 { try c.encode(query[0], forKey: .query) } else { try c.encode(query, forKey: .query) }
        if let context, !context.isEmpty { try c.encode(context, forKey: .context) }
        try c.encode(expect, forKey: .expect)
        try c.encode(tags, forKey: .tags)
        try c.encodeIfPresent(source, forKey: .source)
        try c.encodeIfPresent(notes, forKey: .notes)
        try c.encodeIfPresent(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(searchFolders, forKey: .searchFolders)
    }

    /// Captured drafts whose pick couldn't be read carry this tag until someone fills in `expect`.
    public static let needsExpectedTag = "needs-expected"

    public var needsExpected: Bool { expect.isEmpty }

    public static func now() -> String { ISO8601DateFormatter().string(from: Date()) }

    /// A readable, unique-enough id from a query: "my-k1s-from-2025".
    public static func slug(_ text: String, fallback: String = "case") -> String {
        let allowed = CharacterSet.alphanumerics
        let words = text.lowercased().unicodeScalars.split { !allowed.contains($0) }.map { String(String.UnicodeScalarView($0)) }
        let slug = words.prefix(6).joined(separator: "-")
        return slug.isEmpty ? fallback : slug
    }
}

/// What counts as a correct answer. Exactly one of `anyOf`, `allOf`, `folder` should be set.
public struct Expectation: Codable, Hashable {
    /// Pass if any of these is suggested within the top k.
    public var anyOf: [String]?
    /// Pass only if all of these are suggested within the top k (recall = fraction found).
    public var allOf: [String]?
    /// A folder. With `mode` "folder-or-contents" (the default) suggesting the folder or anything
    /// inside it passes; with "folder" only the folder itself does.
    public var folder: String?
    public var mode: String?

    public enum Kind: String, Codable { case anyOf, allOf, folder, none }

    public init(anyOf: [String]? = nil, allOf: [String]? = nil, folder: String? = nil, mode: String? = nil) {
        self.anyOf = anyOf
        self.allOf = allOf
        self.folder = folder
        self.mode = mode
    }

    public static func make(kind: Kind, paths: [String]) -> Expectation {
        switch kind {
        case .anyOf: return Expectation(anyOf: paths)
        case .allOf: return Expectation(allOf: paths)
        case .folder: return Expectation(folder: paths.first, mode: "folder-or-contents")
        case .none: return Expectation()
        }
    }

    public var kind: Kind {
        if let folder, !folder.isEmpty { return .folder }
        if let allOf, !allOf.isEmpty { return .allOf }
        if let anyOf, !anyOf.isEmpty { return .anyOf }
        return .none
    }

    public var paths: [String] {
        switch kind {
        case .folder: return [folder!]
        case .allOf: return allOf!
        case .anyOf: return anyOf!
        case .none: return []
        }
    }

    public var isEmpty: Bool { kind == .none }
    /// "folder" mode: only the folder itself counts, not files inside it.
    public var folderOnly: Bool { mode == "folder" }

    public var summary: String {
        switch kind {
        case .anyOf: return "any of " + paths.map(EvalPath.display).joined(separator: ", ")
        case .allOf: return "all of " + paths.map(EvalPath.display).joined(separator: ", ")
        case .folder: return (folderOnly ? "folder " : "folder (or contents) ") + EvalPath.display(paths[0])
        case .none: return "(no expected files yet)"
        }
    }
}

/// Paths in cases: `~` expands to the home folder, relative paths resolve against the cases file's
/// folder, symlinks are resolved, and comparisons ignore case (APFS's default).
public enum EvalPath {
    public static func resolve(_ path: String, relativeTo base: URL?) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let url: URL
        if expanded.hasPrefix("/") {
            url = URL(fileURLWithPath: expanded)
        } else if let base {
            url = base.appendingPathComponent(expanded)
        } else {
            url = URL(fileURLWithPath: expanded)
        }
        return normalize(url.path)
    }

    /// The same normalization Likely applies to FILE: lines (see LikelyFolder.screen).
    public static func normalize(_ path: String) -> String {
        var p = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath().path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    public static func same(_ a: String, _ b: String) -> Bool { a.compare(b, options: .caseInsensitive) == .orderedSame }

    /// True if `path` is strictly inside `folder`.
    public static func isInside(_ path: String, _ folder: String) -> Bool {
        let f = folder.hasSuffix("/") ? folder : folder + "/"
        return path.count > f.count && path.lowercased().hasPrefix(f.lowercased())
    }

    public static func display(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }
}

/// Reads and writes JSON Lines case files. Blank lines and lines starting with `#` or `//` are skipped.
public enum EvalCaseFile {
    public struct LoadError: Error, CustomStringConvertible {
        public let line: Int
        public let message: String
        public var description: String { "line \(line): \(message)" }
    }

    public static func load(_ url: URL) throws -> (cases: [EvalCase], errors: [LoadError]) {
        guard FileManager.default.fileExists(atPath: url.path) else { return ([], []) }
        // Under the folder's lock: an append in another process (the app saving a test while an eval
        // run reads the file) is never seen half written.
        let text = try FileLock.withLock(lockURL(for: url)) { try String(contentsOf: url, encoding: .utf8) }
        return parse(text)
    }

    /// The cross-process lock for a cases file's folder (cases.jsonl and drafts.jsonl share it).
    public static func lockURL(for url: URL) -> URL { FileLock.url(for: url.deletingLastPathComponent()) }

    /// Runs `body` holding the lock for `url`'s folder (see FileLock): reads, then writes, that must not
    /// interleave with another Likely process's.
    public static func withLock<T>(_ url: URL, _ body: () throws -> T) rethrows -> T {
        try FileLock.withLock(lockURL(for: url), body)
    }

    public static func parse(_ text: String) -> (cases: [EvalCase], errors: [LoadError]) {
        var cases: [EvalCase] = []
        var errors: [LoadError] = []
        for (index, raw) in splitLines(text).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("//") { continue }
            do {
                cases.append(try JSONDecoder().decode(EvalCase.self, from: Data(line.utf8)))
            } catch {
                errors.append(LoadError(line: index + 1, message: "\(error)"))
            }
        }
        return (cases, errors)
    }

    /// Lines split on "\n" only, with a trailing "\r" dropped. Not `.newlines`: JSONEncoder leaves
    /// U+2028, U+2029 and U+0085 unescaped inside strings, so splitting on those would cut a line in half.
    public static func splitLines(_ text: String) -> [String] {
        text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    }

    public static func encodeLine(_ c: EvalCase) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(c)) ?? Data(), as: UTF8.self)
    }

    public struct WriteError: Error, CustomStringConvertible {
        public let description: String
        public init(_ description: String) { self.description = description }
    }

    /// Replaces the first case whose id is `id` with `replacement` (or removes it when `replacement`
    /// is nil), keeping every other line exactly as it was: comments anywhere in the file, blank
    /// lines, and lines this version can't parse. If no line has that id, `replacement` is appended.
    /// Writes atomically.
    public static func replace(id: String, with replacement: EvalCase?, in url: URL) throws {
        try withLock(url) {
            let fm = FileManager.default
            let text = fm.fileExists(atPath: url.path) ? try String(contentsOf: url, encoding: .utf8) : ""
            let updated = replacing(id: id, with: replacement, in: text)
            try OwnerOnly.write(Data(updated.utf8), to: url)
        }
    }

    /// The text of a cases file with one case replaced or removed (see `replace(id:with:in:)`).
    public static func replacing(id: String, with replacement: EvalCase?, in text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        // A trailing newline leaves an empty last element; keep it out of the edit and add it back.
        if lines.last == "" { lines.removeLast() }
        var done = false
        var out: [String] = []
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if !done, !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("//"),
               let c = try? JSONDecoder().decode(EvalCase.self, from: Data(line.utf8)), c.id == id {
                done = true
                if let replacement { out.append(encodeLine(replacement)) }
                continue
            }
            out.append(raw)
        }
        if !done, let replacement { out.append(encodeLine(replacement)) }
        return out.isEmpty ? "" : out.joined(separator: "\n") + "\n"
    }

    /// Adds one case at the end of the file. The file is created only if it doesn't exist; an
    /// existing file is never truncated.
    public static func append(_ c: EvalCase, to url: URL) throws {
        try OwnerOnly.createDirectory(url.deletingLastPathComponent())
        try withLock(url) { try appendLocked(c, to: url) }
    }

    private static func appendLocked(_ c: EvalCase, to url: URL) throws {
        // Owner-only (0600) from creation; never truncates a file another writer created meanwhile.
        do {
            try OwnerOnly.createExclusive(url)
        } catch {
            throw WriteError("\(error)")
        }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        var data = Data()
        // Make sure the previous line ended with a newline.
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            if try handle.read(upToCount: 1) != Data([0x0A]) { data.append(0x0A) }
            try handle.seekToEnd()
        }
        data.append(Data((encodeLine(c) + "\n").utf8))
        try handle.write(contentsOf: data)
    }

    /// An id not used by `existing`: `base`, `base-2`, `base-3`, …
    public static func uniqueID(_ base: String, existing: [EvalCase]) -> String {
        let ids = Set(existing.map(\.id))
        if !ids.contains(base) { return base }
        var n = 2
        while ids.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }
}

/// Where personal cases, drafts and results live: ~/Library/Application Support/Likely/evals.
public enum EvalStorage {
    public static var root: URL {
        // Dev builds (and the CLI test build) may point it elsewhere. Release builds never do: their
        // `--eval personal` reads only the user's own cases, in the protected data folder.
        #if LIKELY_DEV || LIKELY_EVAL_TEST_SEAM
        if let override = ProcessInfo.processInfo.environment["LIKELY_EVALS_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Likely/evals", isDirectory: true)
    }
    public static var casesURL: URL { root.appendingPathComponent("cases.jsonl") }
    public static var draftsURL: URL { root.appendingPathComponent("drafts.jsonl") }
    public static var runsURL: URL { root.appendingPathComponent("runs", isDirectory: true) }
    /// Screenshots referenced by captured cases (copied here so they outlive the debug view).
    public static var screenshotsURL: URL { root.appendingPathComponent("screenshots", isDirectory: true) }
    /// A case's folder in a run: `<index>-<slug>` (1-based index in the suite, so cases that share an
    /// id don't overwrite each other's files), plus `-<attempt>` when cases are repeated.
    public static func caseFolderName(index: Int, id: String, attempt: Int, repeated: Bool) -> String {
        String(format: "%03d-", index + 1) + EvalCase.slug(id, fallback: "case") + (repeated ? "-\(attempt)" : "")
    }

    /// Held (FileLock.tryHold) for the whole of an eval run, so only one runs at a time: the app's
    /// Settings and the user's coding agent can both start one, and they'd share the runs folder,
    /// last-run.txt and Hermes' eval gateway.
    public static var runLockURL: URL { root.appendingPathComponent(".run.lock") }

    /// Path of the newest run's report, written after every run.
    public static var lastRunURL: URL { root.appendingPathComponent("last-run.txt") }

    public static var lastReport: URL? {
        guard let text = try? String(contentsOf: lastRunURL, encoding: .utf8) else { return nil }
        let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }
}
