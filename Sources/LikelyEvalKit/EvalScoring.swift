import Foundation

/// An expectation with its paths resolved to absolute, normalized paths.
public struct ResolvedExpectation: Codable, Hashable {
    public var kind: Expectation.Kind
    public var paths: [String]
    public var folderOnly: Bool
    /// For folder expectations: the files inside the folder (for recall when only some are suggested).
    public var folderFiles: [String]
    /// For anyOf/allOf: the expected paths that are folders. Suggesting the folder or anything
    /// inside it counts for that entry, e.g. allOf [the K1s folder, a K-1 kept elsewhere].
    public var folderEntries: [String]

    public init(kind: Expectation.Kind, paths: [String], folderOnly: Bool = false, folderFiles: [String] = [],
                folderEntries: [String] = []) {
        self.kind = kind
        self.paths = paths
        self.folderOnly = folderOnly
        self.folderFiles = folderFiles
        self.folderEntries = folderEntries
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Expectation.Kind.self, forKey: .kind)
        paths = try c.decode([String].self, forKey: .paths)
        folderOnly = try c.decodeIfPresent(Bool.self, forKey: .folderOnly) ?? false
        folderFiles = try c.decodeIfPresent([String].self, forKey: .folderFiles) ?? []
        folderEntries = try c.decodeIfPresent([String].self, forKey: .folderEntries) ?? []
    }

    /// True if suggestion `s` covers expected entry `e`: the same path, or inside it when `e` is a folder.
    func covers(_ s: String, _ e: String) -> Bool {
        EvalPath.same(e, s) || (folderEntries.contains { EvalPath.same($0, e) } && EvalPath.isInside(s, e))
    }

    /// Resolves `expect` relative to `base` (the cases file's folder). Folder contents are listed
    /// (non-hidden files, up to `maxFolderFiles`) so recall can credit partial answers.
    public static func resolve(_ expect: Expectation, relativeTo base: URL?, maxFolderFiles: Int = 500) -> ResolvedExpectation {
        let paths = expect.paths.map { EvalPath.resolve($0, relativeTo: base) }
        var files: [String] = []
        if expect.kind == .folder, let folder = paths.first,
           let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: folder),
                                                        includingPropertiesForKeys: [.isRegularFileKey],
                                                        options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let url as URL in walker {
                if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                    files.append(EvalPath.normalize(url.path))
                    if files.count >= maxFolderFiles { break }
                }
            }
        }
        var folderEntries: [String] = []
        if expect.kind == .anyOf || expect.kind == .allOf {
            folderEntries = paths.filter { path in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            }
        }
        return ResolvedExpectation(kind: expect.kind, paths: paths, folderOnly: expect.folderOnly, folderFiles: files,
                                   folderEntries: folderEntries)
    }
}

/// How one answer (an ordered list of suggested paths) did against an expectation.
public struct EvalScore: Codable, Hashable {
    /// False when the case has no expected files yet (a draft): nothing else is meaningful then.
    public var scorable: Bool
    public var pass: Bool
    /// 1-based rank of the first suggestion that matched, if any.
    public var firstHitRank: Int?
    public var hitAt1: Bool
    public var hitAt3: Bool
    public var hitAtK: Bool
    /// anyOf: 1 or 0. allOf: fraction of expected paths suggested in the top k. folder: 1 if the
    /// folder itself was suggested, else the fraction of its files that were.
    public var recall: Double
    /// Fraction of the top-k suggestions that matched; nil when nothing was suggested.
    public var precision: Double?
    /// Suggestions (top k) that matched, in order.
    public var matched: [String]
    /// Suggestions that didn't match anything expected (all of them, not just the top k).
    public var extras: [String]
    /// Expected paths (allOf/anyOf) that were not suggested in the top k.
    public var missing: [String]

    public static let unscorable = EvalScore(scorable: false, pass: false, firstHitRank: nil, hitAt1: false, hitAt3: false,
                                            hitAtK: false, recall: 0, precision: nil, matched: [], extras: [], missing: [])
}

public enum EvalScorer {
    /// Scores `suggestions` (normalized paths, best first) against `expected`, counting only the top `k`.
    public static func score(suggestions rawSuggestions: [String], expected: ResolvedExpectation, k: Int) -> EvalScore {
        guard expected.kind != .none, !expected.paths.isEmpty else { return .unscorable }
        // Drop repeats (case-insensitively), keeping the first position.
        var suggestions: [String] = []
        for s in rawSuggestions where !suggestions.contains(where: { EvalPath.same($0, s) }) { suggestions.append(s) }
        let k = max(1, k)
        let top = Array(suggestions.prefix(k))

        func matches(_ s: String) -> Bool {
            switch expected.kind {
            case .anyOf, .allOf:
                return expected.paths.contains { expected.covers(s, $0) }
            case .folder:
                let folder = expected.paths[0]
                return EvalPath.same(folder, s) || (!expected.folderOnly && EvalPath.isInside(s, folder))
            case .none:
                return false
            }
        }

        let firstHit = suggestions.firstIndex(where: matches).map { $0 + 1 }
        let matchedTop = top.filter(matches)
        let extras = suggestions.filter { !matches($0) }
        var missing: [String] = []
        let recall: Double
        let pass: Bool
        switch expected.kind {
        case .anyOf:
            recall = matchedTop.isEmpty ? 0 : 1
            pass = !matchedTop.isEmpty
            if !pass { missing = expected.paths }
        case .allOf:
            missing = expected.paths.filter { e in !top.contains { expected.covers($0, e) } }
            recall = Double(expected.paths.count - missing.count) / Double(expected.paths.count)
            pass = missing.isEmpty
        case .folder:
            let folder = expected.paths[0]
            if top.contains(where: { EvalPath.same($0, folder) }) {
                recall = 1
            } else if expected.folderOnly || expected.folderFiles.isEmpty {
                recall = 0
            } else {
                // A suggested subfolder covers the files inside it.
                let covered = expected.folderFiles.filter { f in
                    matchedTop.contains { EvalPath.same($0, f) || EvalPath.isInside(f, $0) }
                }
                recall = min(1, Double(covered.count) / Double(expected.folderFiles.count))
            }
            pass = !matchedTop.isEmpty
            if !pass { missing = [folder] }
        case .none:
            return .unscorable
        }
        return EvalScore(scorable: true, pass: pass, firstHitRank: firstHit,
                         hitAt1: firstHit.map { $0 <= 1 } ?? false,
                         hitAt3: firstHit.map { $0 <= 3 } ?? false,
                         hitAtK: firstHit.map { $0 <= k } ?? false,
                         recall: recall,
                         precision: top.isEmpty ? nil : Double(matchedTop.count) / Double(top.count),
                         matched: matchedTop, extras: extras, missing: missing)
    }
}
