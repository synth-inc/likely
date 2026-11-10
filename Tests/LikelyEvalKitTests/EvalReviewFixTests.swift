import Foundation
import XCTest
@testable import LikelyEvalKit

/// Case files, results and isolation rules.
final class EvalFileTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("likely-evals-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Compares two cases files line by line, JSON lines by content (key order isn't stable).
    private func assertSameFile(_ a: String, _ b: String, file: StaticString = #filePath, line: UInt = #line) {
        let la = a.components(separatedBy: "\n"), lb = b.components(separatedBy: "\n")
        XCTAssertEqual(la.count, lb.count, "\(a) vs \(b)", file: file, line: line)
        for (x, y) in zip(la, lb) {
            if let dx = try? JSONSerialization.jsonObject(with: Data(x.utf8)) as? NSDictionary,
               let dy = try? JSONSerialization.jsonObject(with: Data(y.utf8)) as? NSDictionary {
                XCTAssertEqual(dx, dy, file: file, line: line)
            } else {
                XCTAssertEqual(x, y, file: file, line: line)
            }
        }
    }

    private func line(_ id: String) -> String {
        EvalCaseFile.encodeLine(EvalCase(id: id, query: ["q \(id)"], expect: Expectation(anyOf: ["/x/\(id)"]), createdAt: nil))
    }

    // MARK: replace

    func testReplaceKeepsCommentsAndUnparsableLines() {
        let text = "# header\n\(line("a"))\n// mid comment\n{not json\n\n\(line("b"))\n"
        let replacement = EvalCase(id: "a", query: ["new"], expect: Expectation(anyOf: ["/new"]), createdAt: nil)
        let out = EvalCaseFile.replacing(id: "a", with: replacement, in: text)
        assertSameFile(out, "# header\n\(EvalCaseFile.encodeLine(replacement))\n// mid comment\n{not json\n\n\(line("b"))\n")
    }

    func testRemoveOnlyTheTarget() {
        let text = "\(line("a"))\n{broken\n\(line("b"))\n# tail"
        assertSameFile(EvalCaseFile.replacing(id: "a", with: nil, in: text), "{broken\n\(line("b"))\n# tail\n")
    }

    func testReplaceTouchesOnlyFirstDuplicate() {
        let text = "\(line("a"))\n\(line("a"))\n"
        assertSameFile(EvalCaseFile.replacing(id: "a", with: nil, in: text), "\(line("a"))\n")
    }

    func testReplaceAppendsWhenMissing() {
        let c = EvalCase(id: "c", query: ["c"], expect: Expectation(anyOf: ["/c"]), createdAt: nil)
        assertSameFile(EvalCaseFile.replacing(id: "c", with: c, in: "# only\n"), "# only\n\(EvalCaseFile.encodeLine(c))\n")
        assertSameFile(EvalCaseFile.replacing(id: "c", with: c, in: ""), "\(EvalCaseFile.encodeLine(c))\n")
    }

    func testReplaceOnDisk() throws {
        let url = dir.appendingPathComponent("cases.jsonl")
        try "# keep\n{bad\n\(line("a"))\n".write(to: url, atomically: true, encoding: .utf8)
        try EvalCaseFile.replace(id: "a", with: nil, in: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# keep\n{bad\n")
    }

    // MARK: append

    func testAppendCreatesFile() throws {
        let url = dir.appendingPathComponent("sub/cases.jsonl")
        try EvalCaseFile.append(EvalCase(id: "a", query: ["q a"], expect: Expectation(anyOf: ["/x/a"]), createdAt: nil), to: url)
        assertSameFile(try String(contentsOf: url, encoding: .utf8), line("a") + "\n")
    }

    func testAppendKeepsExistingAndAddsMissingNewline() throws {
        let url = dir.appendingPathComponent("cases.jsonl")
        try "# c\n{unparsable".write(to: url, atomically: true, encoding: .utf8)
        try EvalCaseFile.append(EvalCase(id: "a", query: ["q a"], expect: Expectation(anyOf: ["/x/a"]), createdAt: nil), to: url)
        assertSameFile(try String(contentsOf: url, encoding: .utf8), "# c\n{unparsable\n" + line("a") + "\n")
    }

    func testAppendThrowsInsteadOfCrashingOnUnwritableFile() throws {
        let url = dir.appendingPathComponent("cases.jsonl")
        try "x\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        XCTAssertThrowsError(try EvalCaseFile.append(EvalCase(id: "a", query: ["a"], expect: Expectation()), to: url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "x\n")
    }

    // MARK: folders

    func testCaseFolderNamesAreUniquePerIndex() {
        XCTAssertEqual(EvalStorage.caseFolderName(index: 0, id: "lease/418", attempt: 1, repeated: false), "001-lease-418")
        XCTAssertNotEqual(EvalStorage.caseFolderName(index: 0, id: "dup", attempt: 1, repeated: false),
                          EvalStorage.caseFolderName(index: 1, id: "dup", attempt: 1, repeated: false))
        XCTAssertEqual(EvalStorage.caseFolderName(index: 11, id: "x", attempt: 2, repeated: true), "012-x-2")
    }
}

final class EvalResultTests: XCTestCase {
    private func result(_ id: String, status: String, hit: Bool) -> EvalCaseResult {
        let score = EvalScorer.score(suggestions: hit ? ["/a"] : ["/b"], expected: ResolvedExpectation(kind: .anyOf, paths: ["/a"]), k: 8)
        return EvalCaseResult(id: id, query: ["q"], tags: [], expectKind: .anyOf, expected: ["/a"], attempt: 1, status: status, error: nil,
                              suggestions: [], turnSuggestions: [], refused: [], score: score, turns: 1, firstFileSeconds: nil,
                              totalSeconds: 1, costUSD: nil, toolCalls: nil, transcriptPath: nil, promptPath: nil)
    }

    private func run(agent: String = "claude", model: String = "sonnet", k: Int = 8, cases: [String]? = nil, at: String,
                     results: [EvalCaseResult] = []) -> EvalRun {
        EvalRun(suite: "fixtures", suiteFiles: [], agent: agent, model: model, startedAt: at, finishedAt: at, k: k, timeoutSeconds: 60,
                tags: [], isolated: true, promptHash: "x", likelyVersion: "dev", cases: results, caseFilter: cases)
    }

    func testTimeoutWithHitDoesNotPass() {
        XCTAssertTrue(result("a", status: "ok", hit: true).pass)
        XCTAssertFalse(result("a", status: "timeout", hit: true).pass)
        XCTAssertFalse(result("a", status: "error", hit: true).pass)
        let summary = EvalSummary.of([result("a", status: "ok", hit: true), result("b", status: "timeout", hit: true)])
        XCTAssertEqual(summary.passed, 1)
        XCTAssertEqual(summary.passRate, 0.5)
    }

    func testSkippedTestsAreNeitherNowFailingNorNowPassing() {
        let before = run(at: "2026-01-01", results: [result("shot", status: "ok", hit: true), result("old", status: "skipped", hit: false),
                                                     result("a", status: "ok", hit: true)])
        let after = run(at: "2026-01-02", results: [result("shot", status: "skipped", hit: false), result("old", status: "ok", hit: true),
                                                    result("a", status: "ok", hit: false)])
        let changes = EvalReport.caseChanges(after, before)
        XCTAssertEqual(changes.broke, ["a"])
        XCTAssertEqual(changes.fixed, [])
        let lines = EvalReport.textSummary(after, previous: before).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.filter { $0.contains("now failing") || $0.contains("now passing") }, ["  now failing: a"])
    }

    func testMismatches() {
        let now = run(at: "2026-01-02")
        XCTAssertEqual(now.mismatches(with: run(at: "2026-01-01")), [])
        XCTAssertEqual(now.mismatches(with: run(agent: "codex", model: "gpt", k: 3, cases: ["x"], at: "2026-01-01")),
                       ["agent codex", "model gpt", "k=3", "cases x"])
    }

    func testPreviousPrefersMatchingSettings() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("likely-runs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        func save(_ r: EvalRun, _ name: String) throws {
            let d = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            try r.write(to: d.appendingPathComponent("results.json"))
        }
        try save(run(at: "2026-01-01"), "a-matching")
        try save(run(model: "opus", at: "2026-01-02"), "b-other-model")
        let current = run(at: "2026-01-03")
        XCTAssertEqual(EvalRun.previous(of: current, in: dir, excluding: nil)?.1.lastPathComponent, "a-matching")
        // No matching run: fall back to the newest one (labelled by mismatches).
        let other = run(model: "haiku", at: "2026-01-03")
        XCTAssertEqual(EvalRun.previous(of: other, in: dir, excluding: nil)?.1.lastPathComponent, "b-other-model")
    }

    func testOldResultsDecodeWithoutNewFields() throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(run(at: "2026-01-01"))) as! [String: Any]
        json.removeValue(forKey: "caseFilter")
        json.removeValue(forKey: "interrupted")
        let decoded = try JSONDecoder().decode(EvalRun.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.caseFilter)
    }
}

/// Runs a trivial command under the isolation rules with a stand-in home folder.
final class EvalIsolationTests: XCTestCase {
    private func canRead(_ path: String, rules: String) throws -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        p.arguments = ["-p", "(version 1)\n(allow default)\n" + rules, "/bin/cat", path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    func testOnlyFixtureWorkAndAgentStateAreReadable() throws {
        let fm = FileManager.default
        let home = EvalIsolation.realPath(fm.temporaryDirectory.path) + "/likely-home-\(UUID().uuidString)"
        defer { try? fm.removeItem(atPath: home) }
        func file(_ rel: String) throws -> String {
            let path = home + "/" + rel
            try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try "x".write(toFile: path, atomically: true, encoding: .utf8)
            return path
        }
        let fixture = try file("Apps/Likely/evals/fixtures/files/lease.pdf")
        let work = try file("Library/Application Support/Likely/evals/runs/r/cases/001-a/prompt.txt")
        let personal = try file("Library/Application Support/Likely/evals/cases.jsonl")
        let shot = try file("Library/Application Support/Likely/evals/screenshots/a.png")
        let logs = try file("Library/Logs/Likely/likely.log")
        let likelyFolder = try file("Likely/copy.pdf")
        let other = try file("Apps/other-project/secret.txt")
        let claudeState = try file(".claude/settings.json")
        let claudeJSON = try file(".claude.json")
        let agentBin = try file("tools/bin/agent")

        let rules = EvalIsolation.rules(home: home, allowed: [home + "/Apps/Likely/evals/fixtures/files", (work as NSString).deletingLastPathComponent],
                                        agentExecutable: agentBin)
        XCTAssertTrue(try canRead(fixture, rules: rules))
        XCTAssertTrue(try canRead(work, rules: rules))
        XCTAssertTrue(try canRead(claudeState, rules: rules))
        XCTAssertTrue(try canRead(claudeJSON, rules: rules))
        XCTAssertTrue(try canRead(agentBin, rules: rules))
        for denied in [personal, shot, logs, likelyFolder, other] {
            XCTAssertFalse(try canRead(denied, rules: rules), denied)
        }
        XCTAssertTrue(rules.contains("(subpath \"/Volumes\")"))
    }
}
