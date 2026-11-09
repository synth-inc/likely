import Foundation

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

        public init(app: String? = nil, windowTitle: String? = nil, screenshot: String? = nil, button: String? = nil) {
            self.app = app
            self.windowTitle = windowTitle
            self.screenshot = screenshot
            self.button = button
        }

        public var isEmpty: Bool { app == nil && windowTitle == nil && screenshot == nil && button == nil }
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
        let text = try String(contentsOf: url, encoding: .utf8)
        return parse(text)
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

    /// Rewrites the whole file (atomically). Comment lines at the top are kept.
    public static func save(_ cases: [EvalCase], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var header: [String] = []
        if let existing = try? String(contentsOf: url, encoding: .utf8) {
            for line in existing.components(separatedBy: .newlines) {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("#") || t.hasPrefix("//") { header.append(line) } else if !t.isEmpty { break }
            }
        }
        let body = (header + cases.map(encodeLine)).joined(separator: "\n") + "\n"
        try body.write(to: url, atomically: true, encoding: .utf8)
    }

    public static func append(_ c: EvalCase, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let line = Data((encodeLine(c) + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            // Make sure the previous line ended with a newline.
            if handle.offsetInFile > 0 {
                let reader = try FileHandle(forReadingFrom: url)
                defer { try? reader.close() }
                try reader.seek(toOffset: handle.offsetInFile - 1)
                if reader.readData(ofLength: 1) != Data([0x0A]) { handle.write(Data([0x0A])) }
            }
            handle.write(line)
        } else {
            try line.write(to: url)
        }
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
        if let override = ProcessInfo.processInfo.environment["LIKELY_EVALS_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Likely/evals", isDirectory: true)
    }
    public static var casesURL: URL { root.appendingPathComponent("cases.jsonl") }
    public static var draftsURL: URL { root.appendingPathComponent("drafts.jsonl") }
    public static var runsURL: URL { root.appendingPathComponent("runs", isDirectory: true) }
    /// Screenshots referenced by captured cases (copied here so they outlive the debug view).
    public static var screenshotsURL: URL { root.appendingPathComponent("screenshots", isDirectory: true) }
    /// Path of the newest run's report, written after every run.
    public static var lastRunURL: URL { root.appendingPathComponent("last-run.txt") }

    public static var lastReport: URL? {
        guard let text = try? String(contentsOf: lastRunURL, encoding: .utf8) else { return nil }
        let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }
}
