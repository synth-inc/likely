import Foundation
import LikelyStorage

/// One search Likely ran for a picker: where, what the user typed, what the agent suggested, and what
/// the user picked in the end. Kept locally (history.jsonl, one per line) so any past search can be
/// turned into an eval case later. See docs/EVALS.md.
public struct SearchHistoryEntry: Codable, Identifiable, Hashable {
    public var id: String
    /// ISO 8601.
    public var date: String
    /// App that opened the picker.
    public var app: String
    public var windowTitle: String?
    /// The picker's confirm button ("Open", "Upload", …), if known.
    public var button: String?
    /// What the user typed in the bar, in order. Empty for a search that ran on the screenshot alone.
    public var queries: [String]
    /// Absolute paths of the originals the agent suggested (not the copies in ~/Likely), best first.
    public var suggested: [String]
    /// Absolute path(s) the user picked, when the picker was confirmed and the pick could be read.
    public var picked: [String]
    /// How the picker closed ("confirmed with Return", "cancelled with Escape", …), if known.
    public var outcome: String?
    /// Set once an eval case was made from this entry.
    public var evalCaseID: String?

    public init(id: String = UUID().uuidString, date: String = EvalCase.now(), app: String, windowTitle: String? = nil,
                button: String? = nil, queries: [String], suggested: [String], picked: [String] = [],
                outcome: String? = nil, evalCaseID: String? = nil) {
        self.id = id
        self.date = date
        self.app = app
        self.windowTitle = windowTitle
        self.button = button
        self.queries = queries
        self.suggested = suggested
        self.picked = picked
        self.outcome = outcome
        self.evalCaseID = evalCaseID
    }

    private enum CodingKeys: String, CodingKey {
        case id, date, app, windowTitle, button, queries, suggested, picked, outcome, evalCaseID
    }

    /// Lenient: only `id` is required, so entries written by other versions still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        date = try c.decodeIfPresent(String.self, forKey: .date) ?? ""
        app = try c.decodeIfPresent(String.self, forKey: .app) ?? ""
        windowTitle = try c.decodeIfPresent(String.self, forKey: .windowTitle)
        button = try c.decodeIfPresent(String.self, forKey: .button)
        if let single = try? c.decode(String.self, forKey: .queries) {
            queries = [single]
        } else {
            queries = (try? c.decodeIfPresent([String].self, forKey: .queries)) ?? []
        }
        suggested = (try? c.decodeIfPresent([String].self, forKey: .suggested)) ?? []
        picked = (try? c.decodeIfPresent([String].self, forKey: .picked)) ?? []
        outcome = try? c.decodeIfPresent(String.self, forKey: .outcome)
        evalCaseID = try? c.decodeIfPresent(String.self, forKey: .evalCaseID)
    }

    /// ISO8601DateFormatter is expensive to make and thread-safe to share.
    public static let dateFormatter = ISO8601DateFormatter()

    public var timestamp: Date? { Self.dateFormatter.date(from: date) }
    public var wasPicked: Bool { !picked.isEmpty }
    public var hasEval: Bool { evalCaseID != nil }

    /// Files to offer as the expected answer: the pick first, then the suggestions, without duplicates.
    public var candidates: [String] {
        var list: [String] = []
        for p in picked + suggested where !list.contains(where: { EvalPath.same($0, p) }) { list.append(p) }
        return list
    }

    /// An eval case from this search. `queries` and `expected` are what the user settled on in the
    /// Make Eval sheet; `kind` is `.anyOf` or `.allOf`. Paths under the home folder are stored with `~`.
    public func makeCase(queries: [String], expected: [String], kind: Expectation.Kind, existing: [EvalCase],
                         home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> EvalCase {
        let tilde: (String) -> String = { $0.hasPrefix(home + "/") ? "~" + $0.dropFirst(home.count) : $0 }
        let paths = expected.map(tilde)
        let expect = Expectation.make(kind: paths.isEmpty ? .none : (kind == .allOf ? .allOf : .anyOf), paths: paths)
        var tags = ["history"]
        if queries.count > 1 { tags.append("multi-turn") }
        var notes = "From search history (\(date.isEmpty ? "unknown date" : date))."
        if !suggested.isEmpty {
            let hit = expected.contains { e in suggested.contains { EvalPath.same(EvalPath.normalize($0), EvalPath.normalize(e)) } }
            notes += " Likely suggested \(suggested.count) file\(suggested.count == 1 ? "" : "s")\(hit ? ", including an expected one" : ", none of them expected")."
        }
        let id = EvalCaseFile.uniqueID(EvalCase.slug(queries.first ?? app, fallback: "history"), existing: existing)
        let context = EvalCase.Context(app: app.isEmpty ? nil : app, windowTitle: windowTitle, button: button)
        return EvalCase(id: id, query: queries, context: context.isEmpty ? nil : context, expect: expect, tags: tags,
                        source: "history", notes: notes)
    }
}

/// Reads and writes history.jsonl. Every line is encrypted on its own (`DataCipher.sealLine`: AES-GCM
/// with the data key from the Keychain), so the file is still JSON Lines in shape: "\n"-separated,
/// one entry per line, appended and capped as before. Per line rather than per file because a line
/// that can't be opened (damaged, or sealed by another build's key) is then skipped on its own and
/// kept in place, exactly like a line that doesn't decode was before, and the rest still reads.
///
/// Lines that don't decode are skipped on load but left in place on rewrites, until they age out past
/// the cap. A file that exists but can't be read (permissions, invalid UTF-8, I/O error) makes every
/// call throw rather than start over with an empty file, and so does a missing key when writing:
/// nothing is ever written in plaintext.
public enum SearchHistoryFile {
    public static let defaultLimit = 500

    /// ~/Library/Application Support/Likely/History: a folder of its own (0700) so the agent sandboxes
    /// can deny reading it as a whole (see AgentSandbox).
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Likely/History", isDirectory: true)
    }

    /// ~/Library/Application Support/Likely/History/history.jsonl.
    public static var defaultURL: URL { defaultDirectory.appendingPathComponent("history.jsonl") }

    /// Where pre-release builds kept it (next to the evals folder); moved by `migrate`.
    public static var legacyURL: URL {
        defaultDirectory.deletingLastPathComponent().appendingPathComponent("history.jsonl")
    }

    /// What a read found: the entries this build can open, and how many lines it couldn't.
    public struct Contents {
        public var entries: [SearchHistoryEntry]
        /// Encrypted lines that couldn't be opened (another build's key, no key, damaged).
        public var unreadable: Int
        /// Why the first of them couldn't be opened.
        public var problem: DataCipher.CipherError?
    }

    /// Moves `legacy` to `url` if there's nothing at `url` yet, with the new permissions.
    public static func migrate(from legacy: URL, to url: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacy.path), !fm.fileExists(atPath: url.path) else { return }
        try OwnerOnly.createDirectory(url.deletingLastPathComponent())
        try fm.moveItem(at: legacy, to: url)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Encrypts every plaintext line (history written before encryption), keeping the order and the
    /// lines already encrypted as they are. Lines are sealed as they are, even ones that don't decode,
    /// so nothing readable is left. Returns how many lines were encrypted; throws without writing if
    /// the file can't be read or there's no key.
    @discardableResult
    public static func encryptPlaintext(_ url: URL, cipher: DataCipher) throws -> Int {
        let all = try rawLines(url)
        guard all.contains(where: { !DataCipher.isSealedLine($0) }) else { return 0 }
        var count = 0
        let sealed = try all.map { line -> String in
            if DataCipher.isSealedLine(line) { return line }
            count += 1
            return try cipher.sealLine(line)
        }
        try write(sealed, to: url)
        return count
    }

    /// Entries oldest first (file order). No file means no entries; an unreadable file throws.
    public static func load(_ url: URL, cipher: DataCipher) throws -> [SearchHistoryEntry] {
        try read(url, cipher: cipher).entries
    }

    public static func read(_ url: URL, cipher: DataCipher) throws -> Contents {
        var contents = Contents(entries: [], unreadable: 0, problem: nil)
        for line in try rawLines(url) {
            switch open(line, cipher: cipher) {
            case .success(let entry?): contents.entries.append(entry)
            case .success(nil): break
            case .failure(let error):
                contents.unreadable += 1
                if contents.problem == nil { contents.problem = error }
            }
        }
        return contents
    }

    /// Plaintext JSON Lines (history from before encryption, and tests).
    public static func parse(_ text: String) -> [SearchHistoryEntry] {
        lines(text).compactMap(decode)
    }

    public static func encodeLine(_ e: SearchHistoryEntry) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return String(decoding: (try? encoder.encode(e)) ?? Data(), as: UTF8.self)
    }

    /// Adds an entry, then drops the oldest lines beyond `limit`. Throws without writing if the
    /// existing file can't be read or the entry can't be encrypted.
    public static func append(_ e: SearchHistoryEntry, to url: URL, cipher: DataCipher, limit: Int = defaultLimit) throws {
        var all = try rawLines(url)
        all.append(try cipher.sealLine(encodeLine(e)))
        if all.count > limit { all.removeFirst(all.count - limit) }
        try write(all, to: url)
    }

    /// Rewrites the entry with `id`, if there is one. Returns the updated entry, or nil if no line this
    /// build can read has that id. Lines it can't read are kept as they are.
    @discardableResult
    public static func update(id: String, in url: URL, cipher: DataCipher,
                              _ change: (inout SearchHistoryEntry) -> Void) throws -> SearchHistoryEntry? {
        var updated: SearchHistoryEntry?
        let all = try rawLines(url).map { line -> String in
            guard updated == nil, case .success(var e?) = open(line, cipher: cipher), e.id == id else { return line }
            change(&e)
            updated = e
            return try cipher.sealLine(encodeLine(e))
        }
        if updated != nil { try write(all, to: url) }
        return updated
    }

    public static func clear(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    /// One line: `.success(entry)`, `.success(nil)` for a (plaintext or decrypted) line that doesn't
    /// decode, `.failure` for an encrypted line that can't be opened.
    private static func open(_ line: String, cipher: DataCipher) -> Result<SearchHistoryEntry?, DataCipher.CipherError> {
        guard DataCipher.isSealedLine(line) else { return .success(decode(line)) }
        do {
            return .success(decode(try cipher.openLine(line)))
        } catch let error as DataCipher.CipherError {
            return .failure(error)
        } catch {
            return .failure(.damaged)
        }
    }

    private static func decode(_ line: String) -> SearchHistoryEntry? {
        try? JSONDecoder().decode(SearchHistoryEntry.self, from: Data(line.utf8))
    }

    /// "\n"-separated lines (see EvalCaseFile.splitLines: not every Unicode newline).
    static func lines(_ text: String) -> [String] {
        EvalCaseFile.splitLines(text).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func rawLines(_ url: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return lines(try String(contentsOf: url, encoding: .utf8))
    }

    /// Atomic, owner-only (0600 from creation) file in an owner-only (0700) folder.
    private static func write(_ lines: [String], to url: URL) throws {
        try OwnerOnly.write(Data((lines.joined(separator: "\n") + "\n").utf8), to: url)
    }
}
