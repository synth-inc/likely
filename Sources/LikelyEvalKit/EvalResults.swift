import Foundation

/// A FILE: line Likely would not have shown (missing file, sensitive path, Likely's own file, …).
public struct EvalRefusal: Codable, Hashable {
    public var path: String
    public var reason: String
    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }
}

/// The outcome of running one case once.
public struct EvalCaseResult: Codable {
    public var id: String
    public var query: [String]
    public var tags: [String]
    public var expectKind: Expectation.Kind
    public var expected: [String]
    /// 1-based, when a case is run several times (--repeat).
    public var attempt: Int
    /// "ok", "timeout", "error", or "unscored" (no expected files).
    public var status: String
    public var error: String?
    /// The final turn's suggestions (what the user would be looking at), best first. Scored.
    public var suggestions: [String]
    /// Every turn's suggestions, for multi-turn cases.
    public var turnSuggestions: [[String]]
    public var refused: [EvalRefusal]
    public var score: EvalScore
    public var pass: Bool { score.pass }
    public var turns: Int
    /// Seconds from start to the first FILE line Likely would have shown.
    public var firstFileSeconds: Double?
    public var totalSeconds: Double
    public var costUSD: Double?
    public var toolCalls: Int?
    /// Relative to the run folder.
    public var transcriptPath: String?
    public var promptPath: String?

    public init(id: String, query: [String], tags: [String], expectKind: Expectation.Kind, expected: [String], attempt: Int,
                status: String, error: String?, suggestions: [String], turnSuggestions: [[String]], refused: [EvalRefusal],
                score: EvalScore, turns: Int, firstFileSeconds: Double?, totalSeconds: Double, costUSD: Double?,
                toolCalls: Int?, transcriptPath: String?, promptPath: String?) {
        self.id = id
        self.query = query
        self.tags = tags
        self.expectKind = expectKind
        self.expected = expected
        self.attempt = attempt
        self.status = status
        self.error = error
        self.suggestions = suggestions
        self.turnSuggestions = turnSuggestions
        self.refused = refused
        self.score = score
        self.turns = turns
        self.firstFileSeconds = firstFileSeconds
        self.totalSeconds = totalSeconds
        self.costUSD = costUSD
        self.toolCalls = toolCalls
        self.transcriptPath = transcriptPath
        self.promptPath = promptPath
    }
}

public struct EvalSummary: Codable {
    public var cases: Int
    public var scored: Int
    public var passed: Int
    public var passRate: Double
    public var hitAt1: Double
    public var hitAt3: Double
    public var hitAtK: Double
    public var meanRecall: Double
    public var meanPrecision: Double?
    public var medianFirstFileSeconds: Double?
    public var medianTotalSeconds: Double?
    public var totalCostUSD: Double?
    public var meanToolCalls: Double?
    public var timeouts: Int
    public var errors: Int

    public static func of(_ results: [EvalCaseResult]) -> EvalSummary {
        let scored = results.filter { $0.score.scorable }
        let n = Double(max(1, scored.count))
        func rate(_ f: (EvalScore) -> Bool) -> Double { Double(scored.filter { f($0.score) }.count) / n }
        let precisions = scored.compactMap(\.score.precision)
        let costs = results.compactMap(\.costUSD)
        let tools = results.compactMap(\.toolCalls)
        return EvalSummary(
            cases: results.count, scored: scored.count, passed: scored.filter(\.pass).count,
            passRate: rate(\.pass), hitAt1: rate(\.hitAt1), hitAt3: rate(\.hitAt3), hitAtK: rate(\.hitAtK),
            meanRecall: scored.map(\.score.recall).reduce(0, +) / n,
            meanPrecision: precisions.isEmpty ? nil : precisions.reduce(0, +) / Double(precisions.count),
            medianFirstFileSeconds: median(results.compactMap(\.firstFileSeconds)),
            medianTotalSeconds: median(results.map(\.totalSeconds)),
            totalCostUSD: costs.isEmpty ? nil : costs.reduce(0, +),
            meanToolCalls: tools.isEmpty ? nil : Double(tools.reduce(0, +)) / Double(tools.count),
            timeouts: results.filter { $0.status == "timeout" }.count,
            errors: results.filter { $0.status == "error" }.count)
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}

/// Everything written to results.json for one run.
public struct EvalRun: Codable {
    public var version = 1
    /// "fixtures", "personal", "all", or the cases file's path.
    public var suite: String
    public var suiteFiles: [String]
    public var agent: String
    public var model: String
    public var startedAt: String
    public var finishedAt: String
    public var k: Int
    public var timeoutSeconds: Double
    public var tags: [String]
    public var isolated: Bool
    /// SHA-256 prefix of the prompt template, to tell prompt versions apart.
    public var promptHash: String
    public var likelyVersion: String
    public var cases: [EvalCaseResult]
    public var summary: EvalSummary
    public var byTag: [String: EvalSummary]

    public init(suite: String, suiteFiles: [String], agent: String, model: String, startedAt: String, finishedAt: String,
                k: Int, timeoutSeconds: Double, tags: [String], isolated: Bool, promptHash: String, likelyVersion: String,
                cases: [EvalCaseResult]) {
        self.suite = suite
        self.suiteFiles = suiteFiles
        self.agent = agent
        self.model = model
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.k = k
        self.timeoutSeconds = timeoutSeconds
        self.tags = tags
        self.isolated = isolated
        self.promptHash = promptHash
        self.likelyVersion = likelyVersion
        self.cases = cases
        summary = EvalSummary.of(cases)
        var byTag: [String: EvalSummary] = [:]
        for tag in Set(cases.flatMap(\.tags)) { byTag[tag] = EvalSummary.of(cases.filter { $0.tags.contains(tag) }) }
        self.byTag = byTag
    }

    public static func load(_ url: URL) -> EvalRun? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(EvalRun.self, from: data)
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// The newest earlier run of the same suite (and tag filter) in `runsDirectory`, with its folder.
    public static func previous(of run: EvalRun, in runsDirectory: URL, excluding current: URL?) -> (EvalRun, URL)? {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: runsDirectory, includingPropertiesForKeys: nil) else { return nil }
        var best: (EvalRun, URL)?
        for dir in dirs where dir.standardizedFileURL != current?.standardizedFileURL {
            guard let other = load(dir.appendingPathComponent("results.json")), other.suite == run.suite, other.tags == run.tags,
                  other.startedAt < run.startedAt else { continue }
            if best == nil || other.startedAt > best!.0.startedAt { best = (other, dir) }
        }
        return best
    }
}
