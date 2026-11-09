import XCTest
@testable import LikelyEvalKit

/// `Likely --eval` in release builds: nothing on the command line or in the environment may choose a
/// program, prompt file, cases file or results folder (see EvalOptions, EvalEnvironment, docs/EVALS.md).
final class EvalCommandLineTests: XCTestCase {
    private func release(_ args: String...) throws -> EvalOptions { try EvalOptions.parse(args, policy: .release) }
    private func dev(_ args: String...) throws -> EvalOptions { try EvalOptions.parse(args, policy: .dev) }

    private func assertRefused(_ args: [String], containing text: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try EvalOptions.parse(args, policy: .release), "\(args)", file: file, line: line) { error in
            guard let text else { return }
            XCTAssertTrue("\(error)".contains(text), "\(error)", file: file, line: line)
        }
    }

    // MARK: Release builds refuse what chooses a program or a file

    func testReleaseRefusesAgentPath() {
        assertRefused(["--eval", "personal", "--agent-path", "/tmp/evil"], containing: "--agent-path")
        assertRefused(["--agent-path", "/tmp/evil", "--eval", "personal"], containing: "--agent-path")
        // Also as the last argument, without a value.
        assertRefused(["--eval", "personal", "--agent-path"], containing: "--agent-path")
    }

    func testReleaseRefusesPromptFile() {
        assertRefused(["--eval", "personal", "--prompt-file", "/tmp/prompt.txt"], containing: "--prompt-file")
    }

    func testReleaseRefusesCasesFilesAndFixtures() {
        for suite in ["fixtures", "all", "mine", "/tmp/cases.jsonl", "~/cases.jsonl", "cases.jsonl", "../evals/fixtures/cases.jsonl", ""] {
            assertRefused(["--eval", suite], containing: suite.isEmpty ? nil : "personal")
        }
        assertRefused(["--eval"], containing: "needs a value")
        assertRefused(["--agent", "claude"], containing: "--eval needs a suite")
    }

    func testReleaseRefusesOtherDevOnlyOptions() {
        for flag in ["--out", "--no-isolate", "--isolate", "--dry-run"] {
            assertRefused(["--eval", "personal", flag, "/tmp/x"], containing: flag)
        }
    }

    func testReleaseRefusesPreferenceOverridesAndUnknownArguments() {
        // Foundation reads `-key value` anywhere on the command line as a preference (NSArgumentDomain):
        // `-claudePath /tmp/evil` would point Likely at another Claude.
        assertRefused(["--eval", "personal", "-claudePath", "/tmp/evil"], containing: "Unknown option -claudePath")
        assertRefused(["--eval", "personal", "-NSDocumentRevisionsDebugMode", "YES"])
        assertRefused(["--eval", "personal", "-approvedTools", "<data></data>"])
        // …nor hidden in an option's value.
        assertRefused(["--eval", "personal", "--model", "-claudePath", "/tmp/evil"])
        assertRefused(["--eval", "personal", "--case", "-claudePath"])
        assertRefused(["--eval", "personal", "--tag", "-agentID"])
        assertRefused(["--eval", "personal", "stray"], containing: "Unexpected argument")
        assertRefused(["--eval", "personal", "--frobnicate"], containing: "Unknown option")
    }

    func testReleaseRefusesUnknownAgentsAndOddModels() {
        assertRefused(["--eval", "personal", "--agent", "/bin/sh"], containing: "Unknown agent")
        assertRefused(["--eval", "personal", "--agent", "goose"], containing: "Unknown agent")
        for model in ["--mcp-config=/tmp/x.json", "a b", "x;rm", "sonnet\"", "$(id)", String(repeating: "a", count: 101)] {
            assertRefused(["--eval", "personal", "--model", model])
        }
    }

    func testReleaseAcceptsTheSafeSubset() throws {
        let o = try release("--eval", "personal", "--agent", "claude", "--model", "sonnet", "--case", "lease", "--case", "k1s,offer",
                            "--tag", "image", "--tags", "documents", "--k", "3", "--jobs", "1", "--timeout", "90",
                            "--without-tools", "--json", "--repeat", "2", "--verbose")
        XCTAssertEqual(o.suite, "personal")
        XCTAssertEqual(o.agent, "claude")
        XCTAssertEqual(o.model, "sonnet")
        XCTAssertEqual(o.caseIDs, ["lease", "k1s", "offer"])
        XCTAssertEqual(o.tags, ["image", "documents"])
        XCTAssertEqual(o.k, 3)
        XCTAssertEqual(o.timeout, 90)
        XCTAssertTrue(o.withoutTools)
        XCTAssertTrue(o.json)
        XCTAssertNil(o.agentPath)
        XCTAssertNil(o.promptFile)
        XCTAssertNil(o.out)
        XCTAssertTrue(o.isolate)
        for model in ["haiku", "opencode/deepseek-v4.1-flash-free", "anthropic/claude-haiku-5.5", "gpt-5.6-luna", "qwen3:8b"] {
            XCTAssertEqual(try release("--eval", "personal", "--model", model).model, model)
        }
        XCTAssertTrue(try release("--eval", "personal", "--with-tools").withTools)
        XCTAssertTrue(try release("--help").help)
    }

    func testReleaseLimits() {
        assertRefused(["--eval", "personal", "--k", "9"], containing: "between 1 and 8")
        assertRefused(["--eval", "personal", "--timeout", "5000"])
        assertRefused(["--eval", "personal", "--jobs", "64"])
        assertRefused(["--eval", "personal", "--k", "0"])
        assertRefused(["--eval", "personal", "--with-tools", "--without-tools"], containing: "can't be used together")
    }

    func testDevBuildsKeepEverything() throws {
        let o = try dev("--eval", "/tmp/cases.jsonl", "--agent-path", "/tmp/fake-claude", "--prompt-file", "/tmp/p.txt",
                        "--out", "/tmp/out", "--no-isolate", "--dry-run", "--k", "20", "-NSDocumentRevisionsDebugMode", "YES")
        XCTAssertEqual(o.suite, "/tmp/cases.jsonl")
        XCTAssertEqual(o.agentPath, "/tmp/fake-claude")
        XCTAssertEqual(o.promptFile, "/tmp/p.txt")
        XCTAssertEqual(o.out, "/tmp/out")
        XCTAssertFalse(o.isolate)
        XCTAssertTrue(o.dryRun)
        XCTAssertEqual(o.k, 20)
        XCTAssertEqual(try dev("--eval", "fixtures").suite, "fixtures")
    }

    func testJSONIsSeenBeforeParsing() {
        XCTAssertTrue(EvalOptions.wantsJSON(["Likely", "--eval", "fixtures", "--json"]))
        XCTAssertFalse(EvalOptions.wantsJSON(["Likely", "--eval", "personal"]))
    }

    // MARK: Environment

    func testCleanEnvironmentKeepsOnlyWhatLaunchdGivesTheApp() {
        let caller = [
            "HOME": "/tmp/attacker", "CFFIXED_USER_HOME": "/tmp/attacker", "PATH": "/tmp/attacker/bin:/usr/bin",
            "DYLD_INSERT_LIBRARIES": "/tmp/x.dylib", "NODE_OPTIONS": "--require /tmp/x.js", "PYTHONPATH": "/tmp",
            "ZDOTDIR": "/tmp/attacker", "BASH_ENV": "/tmp/x.sh", "CODEX_HOME": "/tmp/codex", "HERMES_HOME": "/tmp/h",
            "LIKELY_EVALS_DIR": "/tmp/cases", "LIKELY_FIXTURES": "/tmp/f", "ANTHROPIC_BASE_URL": "http://x",
            "LANG": "en_US.UTF-8", "LC_ALL": "$(id)", "__CF_USER_TEXT_ENCODING": "0x1F5:0x0:0x0", "TMPDIR": "/tmp/attacker",
        ]
        let clean = EvalEnvironment.sanitized(caller, home: "/Users/me", user: "me", shell: "/bin/zsh", tmpdir: "/var/folders/xy/T/")
        XCTAssertEqual(clean, [
            "HOME": "/Users/me", "USER": "me", "LOGNAME": "me", "SHELL": "/bin/zsh", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": "/var/folders/xy/T/", "LANG": "en_US.UTF-8", "__CF_USER_TEXT_ENCODING": "0x1F5:0x0:0x0",
        ])
        // What decides the restart: any difference but the one macOS adds itself.
        XCTAssertEqual(EvalEnvironment.differences(clean, from: clean), [])
        var started = clean
        started["__CF_USER_TEXT_ENCODING"] = "0x1F5:0x1:0x0"
        XCTAssertEqual(EvalEnvironment.differences(started, from: clean), [])
        XCTAssertEqual(EvalEnvironment.differences(caller, from: clean).contains("CFFIXED_USER_HOME"), true)
        XCTAssertEqual(EvalEnvironment.differences(caller, from: clean).contains("PATH"), true)
        // Deterministic, so the restart happens at most once.
        XCTAssertEqual(EvalEnvironment.sanitized(clean, home: "/Users/me", user: "me", shell: "/bin/zsh", tmpdir: "/var/folders/xy/T/"), clean)
    }

    func testEvalsFolderOverrideIsOnlyForDevBuilds() {
        // These tests are built without LIKELY_DEV, like a release build.
        setenv("LIKELY_EVALS_DIR", "/tmp/likely-evals-elsewhere", 1)
        defer { unsetenv("LIKELY_EVALS_DIR") }
        XCTAssertEqual(EvalStorage.root.path,
                       FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Likely/evals").path)
    }

    func testWithoutToolsWinsOverEverything() {
        let c = EvalCase(id: "c", query: ["q"], context: EvalCase.Context(useTools: true), expect: Expectation(anyOf: ["/a"]), source: "manual")
        XCTAssertTrue(EvalToolPolicy.usesTools(c, inFixtureSuite: false, withTools: false))
        XCTAssertFalse(EvalToolPolicy.usesTools(c, inFixtureSuite: false, withTools: true, withoutTools: true))
    }

    // MARK: JSON output

    private func result(_ id: String, pass: Bool, usedTools: Bool = true) -> EvalCaseResult {
        let score = EvalScorer.score(suggestions: pass ? ["/a"] : ["/b"], expected: ResolvedExpectation(kind: .anyOf, paths: ["/a"]), k: 8)
        return EvalCaseResult(id: id, query: ["q"], tags: [], expectKind: .anyOf, expected: ["/a"], attempt: 1, status: "ok", error: nil,
                              suggestions: [], turnSuggestions: [], refused: [], score: score, turns: 1, firstFileSeconds: 2,
                              totalSeconds: 5, costUSD: 0.01, toolCalls: 3, transcriptPath: nil, promptPath: nil, usedTools: usedTools)
    }

    private func run(at: String, tools: EvalToolSet, results: [EvalCaseResult]) -> EvalRun {
        EvalRun(suite: "personal", suiteFiles: [], agent: "claude", model: "haiku", startedAt: at, finishedAt: at, k: 8,
                timeoutSeconds: 120, tags: [], isolated: false, promptHash: "abc", likelyVersion: "1.0", cases: results, tools: tools)
    }

    func testJSONResultHasCountsCasesToolsAndComparison() throws {
        let rclip = EvalToolSet([(id: "rclip", commands: ["rclip -n"], instructions: "Photos.")])
        let before = run(at: "2026-11-01T00:00:00Z", tools: .empty, results: [result("lease", pass: true), result("dog", pass: false)])
        let after = run(at: "2026-11-02T00:00:00Z", tools: rclip, results: [result("lease", pass: true), result("dog", pass: true)])
        let folder = URL(fileURLWithPath: "/tmp/runs/after")
        let out = EvalCLIResult.make(run: after, runFolder: folder, previous: (before, URL(fileURLWithPath: "/tmp/runs/before")),
                                     pendingTools: ["notes"], exitCode: 0)
        XCTAssertEqual(out.status, "completed")
        XCTAssertEqual(out.summary?.passed, 2)
        XCTAssertEqual(out.summary?.scored, 2)
        XCTAssertEqual(out.summary?.failed, 0)
        XCTAssertEqual(out.cases?.map(\.id), ["lease", "dog"])
        XCTAssertEqual(out.cases?.first?.rank, 1)
        XCTAssertEqual(out.cases?.first?.costUSD, 0.01)
        XCTAssertEqual(out.tools?.active.map(\.id), ["rclip"])
        XCTAssertEqual(out.tools?.hash, rclip.hash)
        XCTAssertEqual(out.tools?.pendingApproval, ["notes"])
        XCTAssertEqual(out.reportPath, "/tmp/runs/after/report.html")
        XCTAssertEqual(out.resultsPath, "/tmp/runs/after/results.json")
        let c = try XCTUnwrap(out.comparison)
        XCTAssertEqual(c.previousPassed, 1)
        XCTAssertEqual(c.passedDelta, 1)
        XCTAssertTrue(c.toolsChanged)
        XCTAssertEqual(c.toolChanges, ["+rclip"])
        XCTAssertEqual(c.nowPassing, ["dog"])
        XCTAssertEqual(c.nowFailing, [])
        XCTAssertEqual(c.settingsDiffer, [])

        // Round-trips (Settings → Tests reads it back), and is valid JSON with stable keys.
        let text = out.encoded()
        XCTAssertEqual(try JSONDecoder().decode(EvalCLIResult.self, from: Data(text.utf8)), out)
        XCTAssertTrue(text.contains("\"toolsChanged\" : true"))
        XCTAssertTrue(text.contains("\"schema\" : \"likely-eval/1\""))
    }

    func testJSONResultWithoutPreviousRunOrOnError() {
        let first = run(at: "2026-11-01T00:00:00Z", tools: .empty, results: [result("lease", pass: false, usedTools: false)])
        let out = EvalCLIResult.make(run: first, runFolder: URL(fileURLWithPath: "/tmp/r"), previous: nil, pendingTools: [], exitCode: 0)
        XCTAssertNil(out.comparison)
        XCTAssertEqual(out.tools?.casesWithoutTools, 1)
        let error = EvalCLIResult.failure("no tests", exitCode: EvalExit.failed)
        XCTAssertEqual(error.status, "error")
        XCTAssertEqual(error.exitCode, 1)
        XCTAssertNil(error.summary)
    }

    func testExitCodes() {
        XCTAssertEqual([EvalExit.completed, EvalExit.failed, EvalExit.usage, EvalExit.unlicensed], [0, 1, 2, 3])
        XCTAssertEqual(EvalExit.interrupted(by: SIGINT), 130)
        XCTAssertEqual(EvalExit.interrupted(by: SIGTERM), 143)
    }
}

/// cases.jsonl and history are written by the app while `Likely --eval` may read them.
final class EvalFileLockingTests: XCTestCase {
    func testConcurrentAppendsKeepEveryLine() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cases-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("cases.jsonl")
        DispatchQueue.concurrentPerform(iterations: 40) { i in
            try? EvalCaseFile.append(EvalCase(id: "c\(i)", query: ["q \(i)"], expect: Expectation(anyOf: ["/a"])), to: url)
        }
        let (cases, errors) = try EvalCaseFile.load(url)
        XCTAssertEqual(errors.count, 0)
        XCTAssertEqual(Set(cases.map(\.id)).count, 40)
        // The lock file sits next to the data, owner-only.
        let lock = EvalCaseFile.lockURL(for: url)
        XCTAssertEqual(lock.lastPathComponent, ".likely.lock")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: lock.path)[.posixPermissions] as? Int, 0o600)
    }

    func testHistoryWritesTakeTheFolderLock() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("history.jsonl")
        let entry = SearchHistoryEntry(date: "2026-11-09T10:00:00Z", app: "Safari", windowTitle: nil, button: nil,
                                       queries: ["q"], suggested: [], picked: [], outcome: "confirmed")
        DispatchQueue.concurrentPerform(iterations: 20) { _ in
            try? SearchHistoryFile.append(entry, to: url, cipher: nil)
        }
        XCTAssertEqual(try SearchHistoryFile.load(url, cipher: nil).count, 20)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(".likely.lock").path))
    }
}
