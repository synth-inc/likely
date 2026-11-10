import LikelyStorage
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
        // Proxy and CA settings come from launchd only (never the caller), and never with a newline.
        let withLaunchd = EvalEnvironment.sanitized(caller.merging(["HTTPS_PROXY": "http://attacker:1"]) { $1 }, home: "/Users/me",
                                                    user: "me", shell: "/bin/zsh", tmpdir: nil,
                                                    launchd: ["HTTPS_PROXY": "http://proxy.corp:8080", "NODE_EXTRA_CA_CERTS": "/a\nb",
                                                              "DYLD_INSERT_LIBRARIES": "/tmp/x"])
        XCTAssertEqual(withLaunchd["HTTPS_PROXY"], "http://proxy.corp:8080")
        XCTAssertNil(withLaunchd["NODE_EXTRA_CA_CERTS"])
        XCTAssertNil(withLaunchd["DYLD_INSERT_LIBRARIES"])
        // Run Tests' one-time token survives the restart, only with a token's shape (RunToken).
        let token = RunToken.make()
        XCTAssertEqual(EvalEnvironment.sanitized(caller.merging([RunToken.environmentKey: token]) { $1 }, home: "/Users/me", user: "me",
                                                 shell: "/bin/zsh", tmpdir: nil)[RunToken.environmentKey], token)
        XCTAssertNil(EvalEnvironment.sanitized(caller.merging([RunToken.environmentKey: "$(id) x"]) { $1 }, home: "/Users/me", user: "me",
                                               shell: "/bin/zsh", tmpdir: nil)[RunToken.environmentKey])
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
        XCTAssertEqual([EvalExit.completed, EvalExit.failed, EvalExit.usage, EvalExit.unlicensed, EvalExit.notAllowed], [0, 1, 2, 3, 4])
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

final class EvalReviewFixes2Tests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("evalfix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testAgentsOnlyFromFixedFoldersAndSavedPathMustMatch() throws {
        let home = dir.path
        for sub in [".local/bin", ".nvm/versions/node/v18.2.0/bin", ".nvm/versions/node/v22.12.0/bin"] {
            try FileManager.default.createDirectory(atPath: "\(home)/\(sub)", withIntermediateDirectories: true)
        }
        for path in ["\(home)/.nvm/versions/node/v18.2.0/bin/claude", "\(home)/.nvm/versions/node/v22.12.0/bin/claude"] {
            FileManager.default.createFile(atPath: path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        }
        let folders = AgentLocations.folders(home: home)
        XCTAssertEqual(Array(folders.prefix(4)), ["\(home)/.local/bin", "\(home)/.claude/local", "/opt/homebrew/bin", "/usr/local/bin"])
        let nvm = folders.filter { $0.contains(".nvm") }
        XCTAssertEqual(nvm, ["\(home)/.nvm/versions/node/v22.12.0/bin", "\(home)/.nvm/versions/node/v18.2.0/bin"], "newest first")
        let candidates = AgentLocations.candidates("claude", in: nvm)
        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(AgentLocations.choose(saved: candidates[1], candidates: candidates), candidates[1], "a saved path detection also finds")
        XCTAssertEqual(AgentLocations.choose(saved: "/tmp/evil/claude", candidates: candidates), candidates[0], "any other saved path is ignored")
        XCTAssertNil(AgentLocations.choose(saved: "/tmp/evil/claude", candidates: []))
    }

    func testSymlinkedEvalsOrRunsFolderIsRefused() throws {
        let root = dir.appendingPathComponent("evals")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("runs"), withIntermediateDirectories: true)
        XCTAssertNil(EvalStorage.symlinkedFolder(root: root))
        try FileManager.default.removeItem(at: root.appendingPathComponent("runs"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("runs"), withDestinationURL: dir)
        XCTAssertEqual(EvalStorage.symlinkedFolder(root: root), root.appendingPathComponent("runs").path)
        let linkedRoot = dir.appendingPathComponent("evals-link")
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: root)
        XCTAssertEqual(EvalStorage.symlinkedFolder(root: linkedRoot), linkedRoot.path)
    }

    func testRunFoldersAreUnique() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let a = try EvalStorage.makeRunFolder(in: dir, date: date, agent: "claude", model: "anthropic/claude haiku")
        let b = try EvalStorage.makeRunFolder(in: dir, date: date, agent: "claude", model: "anthropic/claude haiku")
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(b.lastPathComponent.hasSuffix("-2"))
        XCTAssertFalse(a.lastPathComponent.contains("/"))
        XCTAssertFalse(a.lastPathComponent.contains(" "))
    }

    func testPruningKeeps20AndNothingOlderThan30Days() {
        let now = Date()
        let runs = (0..<25).map { (url: URL(fileURLWithPath: "/runs/\($0)"), date: now.addingTimeInterval(-Double($0) * 3600)) }
        XCTAssertEqual(Set(EvalStorage.runsToPrune(runs, now: now)), Set((20..<25).map { URL(fileURLWithPath: "/runs/\($0)") }))
        let old = [(url: URL(fileURLWithPath: "/runs/new"), date: now), (url: URL(fileURLWithPath: "/runs/old"), date: now.addingTimeInterval(-31 * 86_400))]
        XCTAssertEqual(EvalStorage.runsToPrune(old, now: now), [URL(fileURLWithPath: "/runs/old")])
        XCTAssertEqual(EvalStorage.runsToPrune(old, now: now, protected: [URL(fileURLWithPath: "/runs/old")]), [])
    }

    func testPruneRunsDeletesOnlyRunFolders() throws {
        let runs = dir.appendingPathComponent("runs")
        let old = runs.appendingPathComponent("20200101-000000-claude-haiku")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_577_836_800)], ofItemAtPath: old.path)
        let other = runs.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        XCTAssertEqual(EvalStorage.pruneRuns(in: runs), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    }

    private func run(at: String, interrupted: Bool? = nil, repeatCount: Int? = nil) -> EvalRun {
        EvalRun(suite: "personal", suiteFiles: [], agent: "claude", model: "haiku", startedAt: at, finishedAt: at, k: 8,
                timeoutSeconds: 120, tags: [], isolated: false, promptHash: "x", likelyVersion: "1", cases: [],
                interrupted: interrupted, repeatCount: repeatCount)
    }

    func testPreviousSkipsInterruptedRunsAndRepeatIsASetting() throws {
        let runs = dir.appendingPathComponent("runs")
        let first = runs.appendingPathComponent("a"), stopped = runs.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stopped, withIntermediateDirectories: true)
        try run(at: "2026-11-01T00:00:00Z").write(to: first.appendingPathComponent("results.json"))
        try run(at: "2026-11-02T00:00:00Z", interrupted: true).write(to: stopped.appendingPathComponent("results.json"))
        let now = run(at: "2026-11-03T00:00:00Z")
        XCTAssertEqual(EvalRun.previous(of: now, in: runs, excluding: nil)?.1.lastPathComponent, "a")
        XCTAssertEqual(run(at: "x", repeatCount: 3).mismatches(with: now), ["repeat 1"])
        XCTAssertEqual(run(at: "x", repeatCount: 1).mismatches(with: now), [])
    }

    /// The child exits while a grandchild still holds stdout: the result must include what the
    /// grandchild writes afterwards (Run Tests parses the JSON only after end of file).
    func testOutputCollectorWaitsForEndOfFile() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf '{\"a\":'; echo progress >&2; (sleep 0.4; printf '1}') & exit 7"]
        let done = expectation(description: "done")
        var lines: [String] = []
        var result: (Data, Int32)?
        let queue = DispatchQueue(label: "collector-test")
        let collector = ProcessOutputCollector(process: process, queue: queue, onStderrLine: { lines.append($0) },
                                               completion: { out, status in result = (out, status); done.fulfill() })
        XCTAssertNoThrow(try process.run())
        wait(for: [done], timeout: 5)
        _ = collector
        XCTAssertEqual(result.map { String(decoding: $0.0, as: UTF8.self) }, "{\"a\":1}")
        XCTAssertEqual(result?.1, 7)
        queue.sync {}
        XCTAssertEqual(lines, ["progress"])
    }
}
