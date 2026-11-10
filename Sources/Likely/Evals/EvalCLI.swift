import AppKit
import CryptoKit
import Darwin
import LikelyEvalKit
import LikelyStorage
import LikelyTools

/// `Likely --eval …`: runs eval cases headlessly through the app's own prompt and agent runners, and
/// writes results.json + report.html. No menu bar item, onboarding, AX watching or copying into the
/// Likely folder: FILE lines go to a dry-run sink that records what Likely would have shown.
/// See docs/EVALS.md.
///
/// Every build has it. Release builds accept only a safe subset (`EvalOptions.Policy.release`): the
/// user's own cases (`--eval personal`), agents Likely detected itself, the prompt saved in Settings,
/// the same license check as searches, and a clean environment (`EvalEnvironment`). Dev builds
/// (`./build.sh`, LIKELY_DEV) accept everything: fixtures, any cases file, `--agent-path`, `--prompt-file`, ….
enum EvalCLI {
    /// The made-up person the fixture files belong to (evals/fixtures/generate.py).
    static let fixturePersona = "Jordan Rivera"

    static var policy: EvalOptions.Policy {
        #if LIKELY_DEV
        return .dev
        #else
        return .release
        #endif
    }

    /// The command a user (or their coding agent) runs: this executable, quoted for the shell.
    static var commandPath: String {
        let path = (Bundle.main.executablePath ?? "/Applications/Likely.app/Contents/MacOS/Likely").filter { !$0.isNewline }
        return path.contains(where: { " '\"$`\\!&;()<>|*?[]#~".contains($0) }) ? "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" : path
    }

    static let releaseUsage = """
    Usage: Likely --eval personal [options]

    Runs your own tests (Likely → Settings → Tests) through the agent and prompt Likely uses, and compares
    the results with your previous run. Nothing opens on screen; it works while Likely is running.

    Options:
      --agent <id>        claude, codex, gemini, opencode or hermes (default: the one chosen in Settings).
                          Only agents Likely found on this Mac, at the path it found them.
      --model <name>      model for that agent (default: the one chosen in Settings)
      --case <id>         only this test (repeat, or separate with commas)
      --tag <tag>         only tests with this tag (repeat, or separate with commas)
      --k <n>             pass if an expected file is in the top n suggestions (1-8, default 8)
      --timeout <sec>     per test, all turns included (10-600, default 120)
      --jobs <n>          tests run in parallel (1-4, default 1; times are only comparable at 1)
      --repeat <n>        run every test n times (1-5, default 1)
      --with-tools        give the agent your approved tools (the default)
      --without-tools     run on the built-in search commands only, to measure what your tools add
      --json              print machine-readable results on stdout (progress still goes to stderr)
      --verbose           also print Likely's log lines on stderr

    Progress goes to stderr; the summary (or, with --json, the results) to stdout. Every run also writes
    results.json and report.html to ~/Library/Application Support/Likely/evals/runs/<time>-<agent>-<model>/.

    Command-line runs are off until you turn on “Allow command-line test runs” in Settings → Tests.

    Exit status: 0 the run completed (whatever the pass rate); 1 error (no agent found, no tests, another
    run in progress, results not written); 2 usage error; 3 Likely isn't licensed; 4 command-line runs
    are off; 130/143 stopped by SIGINT/SIGTERM (partial results are written).
    """

    static let devUsage = """
    Usage: Likely --eval <fixtures|personal|all|cases.jsonl> [options]

      fixtures            the repo's public suite (evals/fixtures/cases.jsonl, synthetic files only)
      personal            your cases: ~/Library/Application Support/Likely/evals/cases.jsonl
      all                 personal + fixtures
      <file.jsonl>        any cases file (relative paths in it resolve against its folder)

    Options:
      --agent <id>        claude, codex, gemini, opencode, hermes (default: the one chosen in Settings)
      --model <name>      model for that agent (default: the one chosen in Settings)
      --agent-path <path> agent executable (default: auto-detected)
      --k <n>             cutoff for hit@k and pass/fail (default 8, Likely's maximum)
      --timeout <sec>     per case, all turns included (default 120)
      --repeat <n>        run every case n times (default 1)
      --jobs <n>          cases run in parallel (default 1; latency is only comparable at 1)
      --tags <a,b>        only cases with any of these tags (also --tag, repeatable)
      --case <id,id>      only these cases (repeatable)
      --prompt-file <f>   use this prompt template instead of the one in Settings
      --out <dir>         results folder (default: …/Likely/evals/runs/<time>-<agent>-<model>)
      --no-isolate        don't sandbox cases that set searchFolders (see EVALS.md)
      --with-tools        give fixture cases your tools too (personal cases always get them; see EVALS.md)
      --without-tools     no case gets your tools
      --json              machine-readable results on stdout
      --dry-run           print the prompts that would be sent; run nothing
      --verbose           also print Likely's log lines

    This is a dev build: release builds accept only --eval personal and the safe options (see EVALS.md).

    Exit status: 0 when the run completed (whatever the pass rate), 1 on errors (results couldn't be
    written, no agent, no cases), 2 on a usage error, 130/143 when stopped by SIGINT/SIGTERM (partial
    results are written).
    """

    static var usage: String { policy == .release ? releaseUsage : devUsage }

    static func isRequested(_ arguments: [String]) -> Bool { arguments.contains("--eval") }

    private static var current: EvalSession?
    /// Held for the whole run (see EvalStorage.runLockURL).
    private static var runLock: FileLock.Held?
    /// `--json`: errors are also reported as JSON on stdout.
    private(set) static var json = false

    /// The user's enabled, approved tools (tools.json), read once at the start so every case of a
    /// run sees the same set. Cases that use tools get exactly these (see EvalToolPolicy).
    static let userTools: [CustomTool] = ToolStore.shared.activeTools

    static func toolSet(_ tools: [CustomTool]) -> EvalToolSet {
        EvalToolSet(tools.map { (id: $0.id, commands: $0.cleanedCommands, instructions: $0.instructions) })
    }

    /// Never returns.
    static func main(_ arguments: [String]) -> Never {
        json = EvalOptions.wantsJSON(arguments)
        var options: EvalOptions
        do {
            options = try EvalOptions.parse(Array(arguments.dropFirst()), policy: policy)
        } catch {
            usageError("\(error)")
        }
        if options.help {
            print(usage)
            exit(EvalExit.completed)
        }
        if policy == .release {
            // Before anything reads a preference, a file in ~ or starts a process. (No `-key value`
            // preference overrides can be on the command line: EvalOptions refuses every such argument.)
            restartWithCleanEnvironmentIfNeeded(arguments)
        }
        Log.echoToStderr = options.verbose
        Log.write("eval", "eval mode: \(sensitive: arguments.dropFirst().joined(separator: " "))")

        // Off by default: the user turns it on in Settings → Tests (sealed, see ProtectedSettings).
        if policy == .release, !commandLineRunsAllowed {
            fail(EvalExit.notAllowed, "Command-line test runs are off. Turn on “Allow command-line test runs” in Likely → Settings → Tests, then run this again.")
        }
        // Same gate as searches (License.permitsSearches): no network, no UI.
        // Dev builds don't check: eval mode there is a developer tool.
        if policy == .release, !License.permitsSearches() {
            fail(EvalExit.unlicensed, "Likely isn't licensed on this Mac, so it can't run searches or tests. Open Likely to buy or "
                 + "restore a license (a subscription is re-checked when Likely runs), then try again.")
        }

        // Results, transcripts and run files stay in the data folder: never through a symlinked evals/ or runs/.
        if let link = EvalStorage.symlinkedFolder() {
            fail("\(link) is a symbolic link; Likely only writes test runs into its own folder. Remove the link and try again.")
        }

        let suite: Suite
        do { suite = try Suite.load(options.suite) } catch { fail("\(error)") }
        for warning in suite.warnings { printErr("warning: \(warning)") }
        var cases = suite.cases.filter { !$0.evalCase.needsExpected }
        let skipped = suite.cases.count - cases.count
        if !options.tags.isEmpty { cases = cases.filter { !Set($0.evalCase.tags).isDisjoint(with: options.tags) } }
        if !options.caseIDs.isEmpty { cases = cases.filter { options.caseIDs.contains($0.evalCase.id) } }
        if let unknown = options.caseIDs.subtracting(suite.cases.map(\.evalCase.id)).sorted().first {
            printErr("warning: no test with id \(unknown)")
        }
        guard !cases.isEmpty else {
            fail(suite.cases.isEmpty && options.suite == "personal"
                 ? "You have no saved tests yet. Save one with “Save as test” in the bar above a picker, Settings → History → Make Eval, or Settings → Tests → New Test…."
                 : "No cases to run in \(options.suite)\(options.tags.isEmpty ? "" : " with tags \(options.tags.sorted())").")
        }
        if skipped > 0 { printErr("note: skipped \(skipped) case\(skipped == 1 ? "" : "s") with no expected files") }
        // Likely never shows files in some places (/tmp, hidden folders, ~/Library, …): such cases can't pass.
        for item in cases {
            for path in ResolvedExpectation.resolve(item.evalCase.expect, relativeTo: item.base, maxFolderFiles: 0).paths {
                if let reason = LikelyFolder.screen(path: path).refusal {
                    printErr("warning: \(item.evalCase.id) expects \(path), which Likely never shows (\(reason)); it can't pass.")
                } else if !FileManager.default.fileExists(atPath: path) {
                    printErr("warning: \(item.evalCase.id) expects \(path), which doesn't exist.")
                }
            }
        }

        var template = Settings.promptTemplate
        if let file = options.promptFile {   // dev builds only (EvalOptions refuses it in release builds)
            guard let text = try? String(contentsOfFile: (file as NSString).expandingTildeInPath, encoding: .utf8) else { fail("Can't read \(file)") }
            template = text
        }

        let agentID = options.agent ?? Settings.agentID
        guard let kind = AgentKind.with(id: agentID), kind.isSupported else {
            // The agent saved in Settings: not a usage error.
            if options.agent == nil { fail("The agent chosen in Settings (\(agentID)) can't run tests. Choose another in Settings → Agent, or pass --agent.") }
            usageError("Unknown or unsupported agent \"\(agentID)\". Supported: \(AgentKind.all.filter(\.isSupported).map(\.id).joined(separator: ", "))")
        }
        let model = options.model ?? AgentModels.selected(for: agentID)
        if policy == .release, !EvalOptions.isValidModel(model) { usageError("Invalid model name \(model) (Settings → Agent)") }

        let wantsIsolation = options.isolate && cases.contains { $0.evalCase.searchFolders != nil }
        if wantsIsolation, kind.id == "codex" {
            printErr("warning: Codex runs inside its own sandbox, which can't be nested, so these cases are NOT isolated: "
                     + "Codex can read any of your files (only the prompt asks it to stay in the test folder). "
                     + "The run is recorded as not isolated.")
        }
        // Hermes serves every case through one gateway, which runs inside the sandbox of the case that
        // started it (that case's folder readable): with cases in parallel, one case's agent could read
        // another's folder, or each would restart the gateway under the other. So one at a time.
        if kind.id == "hermes", options.jobs > 1 {
            usageError("Hermes runs one test at a time (its gateway is shared by every case): use --jobs 1.")
        }
        // Screenshots aren't part of test runs (Likely no longer sends them with searches).
        let withScreenshots = cases.filter { $0.evalCase.context?.screenshot != nil }.count
        if withScreenshots > 0 {
            printErr("note: \(withScreenshots) test\(withScreenshots == 1 ? " has" : "s have") a screenshot; test runs don't use screenshots, so \(withScreenshots == 1 ? "it runs" : "they run") without")
        }

        if options.dryRun {   // dev builds only
            for item in cases {
                let run = EvalCaseRun(item: item, agent: EvalCaseRun.Agent(kind: kind, path: "-", model: model), template: template,
                                      options: options, attempt: 1, workDir: FileManager.default.temporaryDirectory)
                print("=== \(item.evalCase.id) (\(item.evalCase.expect.summary))")
                print(run.firstPrompt())
                for (i, text) in item.evalCase.query.dropFirst().enumerated() {
                    print("--- turn \(i + 2):\n" + PromptBuilder.followUp(text, rejected: ["<turn \(i + 1) suggestions>"]))
                }
                print()
            }
            exit(EvalExit.completed)
        }

        // Release builds: only where Likely found the agent itself (the same lookup as the app).
        guard let path = options.agentPath ?? locate(agentID) else {
            fail(policy == .release ? "\(kind.name) isn't installed (Likely looked where the app looks). Install it, or pick another agent with --agent."
                                    : "\(kind.name) not found. Install it, or pass --agent-path.")
        }

        // One run at a time: the app's Settings and a coding agent may both start one.
        do {
            guard let held = try FileLock.tryHold(EvalStorage.runLockURL) else {
                fail("Another test run is in progress (from Likely's Settings or another command). Wait for it to finish, then run again.")
            }
            runLock = held
        } catch {
            fail("Can't start the run: \(error)")
        }
        // Hermes: a profile of its own, so the run never stops or reuses the app's gateway (see HermesRunner).
        HermesRunner.usesEvalProfile = true
        // Codex and Hermes keep each conversation; they're deleted right away, not in the background,
        // since this process exits as soon as the run ends.
        AgentSessionCleanup.synchronous = true
        // Codex can't use sandbox patterns: find Photos libraries now, as the app does at launch.
        if kind.id == "codex", PrivateDataAccess.blocked().contains(.photos) { PhotoLibraries.refreshNow() }

        let agent = EvalCaseRun.Agent(kind: kind, path: path, model: model)
        let session = EvalSession(suite: suite, cases: cases, agent: agent, template: template, options: options)
        // Held for the life of the process (a local could be released early by the optimizer).
        current = session
        handleSignals(session)
        DispatchQueue.main.async { session.start() }
        // Agent runners deliver output on the main queue; keep the run loop alive until the session exits.
        RunLoop.main.add(Port(), forMode: .default)
        while true { RunLoop.main.run(mode: .default, before: .distantFuture) }
    }

    /// Release builds: run in the environment the app gets from launchd, rebuilt from the user
    /// database (EvalEnvironment), by exec'ing this same executable again if the caller's differs. The
    /// caller's environment could otherwise steer which programs Likely and its agents load or run
    /// (DYLD_*, NODE_OPTIONS, PATH, ZDOTDIR, …) or which "home" Likely reads (CFFIXED_USER_HOME, which
    /// Foundation reads at launch, so it can't be unset in-process).
    private static func restartWithCleanEnvironmentIfNeeded(_ arguments: [String]) {
        guard let pw = getpwuid(getuid()) else { fail("Can't read your user account") }
        let home = String(cString: pw.pointee.pw_dir)
        let user = String(cString: pw.pointee.pw_name)
        let shell = String(cString: pw.pointee.pw_shell)
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let tmpdir = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0 ? String(cString: buffer) : nil
        var passThrough: Set<String> = []
        #if LIKELY_EVAL_TEST_SEAM
        // scripts/test-eval-cli.sh only: a build made for that test lets it use a fake home folder.
        passThrough = ["CFFIXED_USER_HOME", "HOME", "LIKELY_EVALS_DIR", "LIKELY_EVAL_TEST_ALLOW"]
        #endif
        let marker = "__LIKELY_EVAL_CLEAN_ENV"
        let current = ProcessInfo.processInfo.environment
        var clean = EvalEnvironment.sanitized(current, home: home, user: user, shell: shell, tmpdir: tmpdir,
                                              launchd: launchdValues(EvalEnvironment.launchdKeys), passThrough: passThrough)
        clean[marker] = "1"
        let differences = EvalEnvironment.differences(current, from: clean)
        guard !differences.isEmpty else { return }
        // Never loop: after one restart the environment is the clean one.
        if current[marker] != nil { fail("Can't run with a clean environment (\(differences.joined(separator: ", ")))") }

        var size = UInt32(0)
        _NSGetExecutablePath(nil, &size)
        var raw = [CChar](repeating: 0, count: Int(size) + 1)
        guard _NSGetExecutablePath(&raw, &size) == 0, let real = realpath(raw, nil) else { fail("Can't find Likely's executable") }
        let executable = String(cString: real)
        free(real)
        let argv = [executable] + arguments.dropFirst()
        let envp = clean.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        var cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        var cEnv: [UnsafeMutablePointer<CChar>?] = envp.map { strdup($0) } + [nil]
        fflush(stdout)
        fflush(stderr)
        execve(executable, &cArgs, &cEnv)
        let code = errno
        fail("Can't restart with a clean environment: \(String(cString: strerror(code)))")
    }

    /// `launchctl getenv` for each key (what launchd gives GUI apps, e.g. a proxy set with `launchctl
    /// setenv`). /bin/launchctl, with an empty environment; values with newlines are dropped later.
    private static func launchdValues(_ keys: [String]) -> [String: String] {
        var values: [String: String] = [:]
        for key in keys {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            p.arguments = ["getenv", key]
            p.environment = [:]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            guard (try? p.run()) != nil else { continue }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            var value = String(decoding: data, as: UTF8.self)
            if value.hasSuffix("\n") { value.removeLast() }
            if p.terminationStatus == 0, !value.isEmpty { values[key] = value }
        }
        return values
    }

    /// Whether this run may start: "Allow command-line test runs" is on (sealed setting; plain in builds
    /// without a profile), or Settings → Tests → Run Tests started it (the parent process is this same
    /// app; nothing else starts Likely's executable as a child of Likely).
    static var commandLineRunsAllowed: Bool {
        #if LIKELY_EVAL_TEST_SEAM
        if let value = ProcessInfo.processInfo.environment["LIKELY_EVAL_TEST_ALLOW"] { return value == "1" }
        #endif
        return ProtectedSettings.bool(ProtectedSettings.allowCommandLineTests) == true || startedByThisApp
    }

    /// The parent process runs this very executable (Settings → Tests → Run Tests).
    static var startedByThisApp: Bool {
        let parent = getppid()
        guard parent > 1 else { return false }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(parent, &buffer, UInt32(buffer.count)) > 0,
              let parentPath = realpath(buffer, nil) else { return false }
        defer { free(parentPath) }
        var size = UInt32(0)
        _NSGetExecutablePath(nil, &size)
        var own = [CChar](repeating: 0, count: Int(size) + 1)
        guard _NSGetExecutablePath(&own, &size) == 0, let ownPath = realpath(own, nil) else { return false }
        defer { free(ownPath) }
        return strcmp(parentPath, ownPath) == 0
    }

    private static var signalSources: [DispatchSourceSignal] = []

    /// Ctrl-C, or Stop in Settings (SIGTERM): stop the agents and write what finished. The signals get a
    /// do-nothing handler rather than SIG_IGN (the dispatch sources do the work): a handled signal goes
    /// back to its default in the agents Likely starts, an ignored one would be inherited, and an agent
    /// that ignores SIGTERM couldn't be stopped.
    private static func handleSignals(_ session: EvalSession) {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, evalSignalNoop)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { session.interrupt(signal: sig) }
            source.resume()
            signalSources.append(source)
        }
    }

    /// Where the app would run the agent from: the saved Claude path, then AgentDetector's lookup (fixed
    /// install folders, then the user's login shell).
    /// Release builds: fixed install folders only (AgentLocations), never a login shell, and the saved
    /// Claude path only if it's one of the places found. Dev builds: the app's lookup.
    static func locate(_ agentID: String) -> String? {
        guard let kind = AgentKind.with(id: agentID) else { return nil }
        if policy == .release {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let folders = AgentLocations.folders(home: home)
            let candidates = kind.executables.flatMap { AgentLocations.candidates($0, in: folders) }
            let saved = agentID == "claude" ? ProtectedSettings.string(ProtectedSettings.claudePath) : nil
            return AgentLocations.choose(saved: saved, candidates: candidates)
        }
        let fm = FileManager.default
        if agentID == "claude", let saved = ProtectedSettings.string(ProtectedSettings.claudePath), fm.isExecutableFile(atPath: saved) {
            return saved
        }
        return AgentDetector.locateAll()[agentID]
    }

    /// Exits after stopping the running cases' agents, deleting their Codex/Hermes sessions and stopping
    /// the eval's Hermes gateway: every way out of a run goes through here.
    static func terminate(_ status: Int32) -> Never {
        current?.cancelRunning()
        HermesRunner.stopEvalGateway()
        fflush(stdout)
        exit(status)
    }

    /// A setup or run error: exit 1 (or `status`).
    static func fail(_ status: Int32 = EvalExit.failed, _ message: String) -> Never {
        printErr(message)
        if json { print(EvalCLIResult.failure(message, exitCode: status).encoded()) }
        terminate(status)
    }

    static func fail(_ message: String) -> Never { fail(EvalExit.failed, message) }

    /// Exit 2, with the usage.
    static func usageError(_ message: String) -> Never {
        printErr("\(message)\n\n\(usage)")
        if json { print(EvalCLIResult.failure(message, exitCode: EvalExit.usage).encoded()) }
        fflush(stdout)
        exit(EvalExit.usage)
    }

    static func printErr(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

// MARK: - Suites

struct SuiteCase {
    let evalCase: EvalCase
    /// The folder of the cases file: relative paths in the case resolve against it.
    let base: URL
    /// From the repo's public fixtures file (evals/fixtures/cases.jsonl).
    var inFixtureSuite = false
}

struct Suite {
    let name: String
    let files: [URL]
    let cases: [SuiteCase]
    let warnings: [String]

    struct LoadError: Error, CustomStringConvertible { let description: String }

    static func load(_ spec: String) throws -> Suite {
        // Release builds: the user's own cases file only (EvalOptions refuses anything else first).
        if EvalCLI.policy == .release, !EvalOptions.releaseSuites.contains(spec) {
            throw LoadError(description: "Release builds run only your own tests (--eval personal).")
        }
        var files: [URL]
        switch spec {
        case "fixtures":
            files = [try fixturesFile()]
        case "personal", "mine":
            files = [EvalStorage.casesURL]
        case "all":
            files = [EvalStorage.casesURL] + ((try? fixturesFile()).map { [$0] } ?? [])
        default:
            files = [URL(fileURLWithPath: (spec as NSString).expandingTildeInPath).standardizedFileURL]
        }
        var cases: [SuiteCase] = []
        var warnings: [String] = []
        var seen = Set<String>()
        let fixtures = (try? fixturesFile())?.resolvingSymlinksInPath()
        for file in files {
            let isFixtures = file.standardizedFileURL.resolvingSymlinksInPath() == fixtures
            guard FileManager.default.fileExists(atPath: file.path) else {
                if spec == "all" { warnings.append("\(file.path) doesn't exist"); continue }
                if spec == "personal" || spec == "mine" { continue }   // no tests saved yet: said by the caller
                throw LoadError(description: "No cases file at \(file.path)")
            }
            let (loaded, errors) = try EvalCaseFile.load(file)
            warnings += errors.map { "\(file.lastPathComponent) \($0)" }
            for c in loaded {
                if seen.contains(c.id) { warnings.append("duplicate case id \(c.id) in \(file.lastPathComponent); both run") }
                seen.insert(c.id)
                cases.append(SuiteCase(evalCase: c, base: file.deletingLastPathComponent(), inFixtureSuite: isFixtures))
            }
        }
        let name = ["fixtures", "personal", "mine", "all"].contains(spec) ? (spec == "mine" ? "personal" : spec) : files[0].path
        return Suite(name: name, files: files, cases: cases, warnings: warnings)
    }

    /// evals/fixtures/cases.jsonl: $LIKELY_FIXTURES, the app bundle (dev builds), or the repo the binary
    /// was built in (walking up from the executable), or the current directory.
    static func fixturesFile() throws -> URL {
        guard EvalCLI.policy == .dev else { throw LoadError(description: "The public fixtures are in dev builds only.") }
        let fm = FileManager.default
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["LIKELY_FIXTURES"] {
            candidates.append(URL(fileURLWithPath: (env as NSString).expandingTildeInPath))
        }
        if let resources = Bundle.main.resourceURL { candidates.append(resources.appendingPathComponent("evals/fixtures")) }
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<8 {
            candidates.append(dir.appendingPathComponent("evals/fixtures"))
            dir = dir.deletingLastPathComponent()
        }
        candidates.append(URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("evals/fixtures"))
        for candidate in candidates {
            let file = candidate.pathExtension == "jsonl" ? candidate : candidate.appendingPathComponent("cases.jsonl")
            if fm.fileExists(atPath: file.path) { return file.standardizedFileURL }
        }
        throw LoadError(description: "Can't find evals/fixtures/cases.jsonl. Run from the repo, or set LIKELY_FIXTURES=/path/to/evals/fixtures.")
    }
}

// MARK: - Session

/// Runs the cases (`--jobs` at a time), then writes results.json and report.html.
final class EvalSession {
    let suite: Suite
    let cases: [SuiteCase]
    let agent: EvalCaseRun.Agent
    let template: String
    let options: EvalOptions
    let runDir: URL
    private let startedAt = Date()
    /// (index in `cases`, case, attempt)
    private var queue: [(Int, SuiteCase, Int)] = []
    private var running: [EvalCaseRun] = []
    /// With the case's index, so the report keeps suite order (ids needn't be unique).
    private var results: [(index: Int, result: EvalCaseResult)] = []
    private var total = 0
    private var interruptedBy: Int32?
    /// Tools changed outside Likely and not approved yet: not used, and said so.
    let pendingTools: [String] = ToolStore.shared.pending.map(\.tool.id).sorted()

    init(suite: Suite, cases: [SuiteCase], agent: EvalCaseRun.Agent, template: String, options: EvalOptions) {
        self.suite = suite
        self.cases = cases
        self.agent = agent
        self.template = template
        self.options = options
        if let out = options.out {   // dev builds only
            runDir = URL(fileURLWithPath: (out as NSString).expandingTildeInPath, isDirectory: true)
        } else if let made = try? EvalStorage.makeRunFolder(date: startedAt, agent: agent.kind.id, model: agent.model) {
            runDir = made
        } else {
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd-HHmmss"
            let model = agent.model.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: " ", with: "_")
            runDir = EvalStorage.runsURL.appendingPathComponent("\(f.string(from: startedAt))-\(agent.kind.id)-\(model)", isDirectory: true)
        }
        for (i, c) in cases.enumerated() { for attempt in 1...options.repeatCount { queue.append((i, c, attempt)) } }
        total = queue.count
    }

    func start() {
        do {
            try OwnerOnly.createDirectory(runDir)
        } catch {
            EvalCLI.fail("Can't create \(runDir.path): \(error)")
        }
        // Progress goes to stderr; stdout gets only the summary (or the JSON).
        EvalCLI.printErr("Running \(total) case\(total == 1 ? "" : "s") from \(suite.name) with \(agent.kind.name) · \(agent.model)")
        let withTools = cases.filter { EvalCaseRun.usesTools($0, options: options) }.count
        let tools = EvalCLI.userTools.isEmpty ? "none" : EvalCLI.userTools.map(\.id).joined(separator: ", ")
        EvalCLI.printErr("Your tools: \(tools)" + (EvalCLI.userTools.isEmpty || withTools == cases.count ? ""
              : " (\(cases.count - withTools) of \(cases.count) cases run without them)"))
        if !pendingTools.isEmpty {
            EvalCLI.printErr("note: waiting for your approval in Likely → Settings → Tools, so not used in this run: "
                             + pendingTools.joined(separator: ", "))
        }
        EvalCLI.printErr("Results: \(runDir.path)")
        fill()
    }

    private func fill() {
        while interruptedBy == nil, running.count < options.jobs, !queue.isEmpty {
            let (index, item, attempt) = queue.removeFirst()
            let folder = EvalStorage.caseFolderName(index: index, id: item.evalCase.id, attempt: attempt, repeated: options.repeatCount > 1)
            let workDir = runDir.appendingPathComponent("cases/\(folder)", isDirectory: true)
            try? OwnerOnly.createDirectory(workDir)
            let run = EvalCaseRun(item: item, agent: agent, template: template, options: options, attempt: attempt, workDir: workDir)
            running.append(run)
            run.start { [weak self, weak run] result in
                guard let self else { return }
                self.running.removeAll { $0 === run }
                self.finished(result, index: index, relativeTo: workDir)
            }
        }
        if running.isEmpty && (queue.isEmpty || interruptedBy != nil) { finish() }
    }

    /// SIGINT/SIGTERM: cancel the running cases (their agents are stopped), skip the rest, and write
    /// partial results. A second signal, or 10 s without the cases settling, exits at once.
    func interrupt(signal: Int32) {
        if interruptedBy != nil { finish() }
        interruptedBy = signal
        EvalCLI.printErr("\nStopping: cancelling \(running.count) running case\(running.count == 1 ? "" : "s"), skipping \(queue.count); writing partial results…")
        queue.removeAll()
        if running.isEmpty { return finish() }
        for run in running { run.cancel() }
        // Cases that don't settle within 10 s are dropped; what finished is still written.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.finish() }
    }

    private func finished(_ raw: EvalCaseResult, index: Int, relativeTo workDir: URL) {
        var result = raw
        let rel = workDir.path.replacingOccurrences(of: runDir.path + "/", with: "")
        if result.transcriptPath != nil { result.transcriptPath = rel + "/transcript.jsonl" }
        if result.promptPath != nil { result.promptPath = rel + "/prompt.txt" }
        results.append((index, result))
        let mark = result.status == "skipped" ? "SKIP" : !result.score.scorable ? "?" : result.pass ? "PASS" : "FAIL"
        var line = "[\(results.count)/\(total)] \(mark) \(result.id)"
        if options.repeatCount > 1 { line += " #\(result.attempt)" }
        line += "  rank \(result.score.firstHitRank.map(String.init) ?? "–")  \(String(format: "%.1fs", result.totalSeconds))"
        if let cost = result.costUSD { line += String(format: "  $%.4f", cost) }
        if result.status != "ok" { line += "  [\(result.status)\(result.error.map { ": \($0.prefix(80))" } ?? "")]" }
        EvalCLI.printErr(line)
        fill()
    }

    /// Cancels the cases still running (their agents stop and their sessions are deleted).
    func cancelRunning() {
        let runs = running
        running.removeAll()
        for run in runs { run.cancel() }
    }

    private var finishing = false

    private func finish() {
        guard !finishing else { return }
        finishing = true
        cancelRunning()
        let iso = ISO8601DateFormatter()
        HermesRunner.stopEvalGateway()
        // Keep suite order stable (parallel runs finish out of order). By index: ids can repeat.
        let ordered = results.sorted { ($0.index, $0.result.attempt) < ($1.index, $1.result.attempt) }.map(\.result)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let hash = SHA256.hash(data: Data(template.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8)
        let run = EvalRun(suite: suite.name, suiteFiles: suite.files.map(\.path), agent: agent.kind.id, model: agent.model,
                          startedAt: iso.string(from: startedAt), finishedAt: iso.string(from: Date()), k: options.k,
                          timeoutSeconds: options.timeout, tags: options.tags.sorted(),
                          isolated: options.isolate && agent.canIsolate && cases.contains { $0.evalCase.searchFolders != nil },
                          promptHash: String(hash), likelyVersion: version, cases: ordered,
                          caseFilter: options.caseIDs.isEmpty ? nil : options.caseIDs.sorted(),
                          interrupted: interruptedBy == nil ? nil : true,
                          tools: EvalCLI.toolSet(cases.contains { EvalCaseRun.usesTools($0, options: options) } ? EvalCLI.userTools : []),
                          repeatCount: options.repeatCount)
        let previous = EvalRun.previous(of: run, in: runDir.deletingLastPathComponent(), excluding: runDir)
        let status: Int32 = interruptedBy.map(EvalExit.interrupted(by:)) ?? EvalExit.completed
        let report = runDir.appendingPathComponent("report.html")
        do {
            try run.write(to: runDir.appendingPathComponent("results.json"))
            try OwnerOnly.write(template, to: runDir.appendingPathComponent("prompt-template.txt"))
            try OwnerOnly.write(EvalReport.html(run, previous: previous?.0, previousPath: previous?.1.path), to: report)
            try? OwnerOnly.write(report.path, to: EvalStorage.lastRunURL)
        } catch {
            EvalCLI.fail("Couldn't write results: \(error)")
        }
        // Keep the newest 20 runs, none older than 30 days (docs/PRIVACY.md).
        if options.out == nil {
            EvalStorage.pruneRuns(in: runDir.deletingLastPathComponent(), protected: [runDir] + (previous.map { [$0.1] } ?? []))
        }
        var summary = EvalReport.textSummary(run, previous: previous?.0)
        if !pendingTools.isEmpty { summary += "\nNot used (waiting for approval in Settings → Tools): " + pendingTools.joined(separator: ", ") }
        summary += "\nResults: \(runDir.appendingPathComponent("results.json").path)\nReport: \(report.path)"
        if options.json {
            EvalCLI.printErr("\n" + summary)
            print(EvalCLIResult.make(run: run, runFolder: runDir, previous: previous, pendingTools: pendingTools, exitCode: status).encoded())
        } else {
            print("")
            print(summary)
        }
        EvalCLI.terminate(status)
    }
}

// MARK: - One case

/// Runs one case through a fresh AgentRunner: the same first prompt the picker flow builds, each
/// later query sent as feedback (`runner.send`), FILE lines screened like LikelyFolder would but
/// never copied.
final class EvalCaseRun {
    struct Agent {
        let kind: AgentKind
        let path: String
        let model: String
        /// Codex runs under its own sandbox, which can't be nested: no isolation rules for it.
        var canIsolate: Bool { kind.id != "codex" }
    }

    let item: SuiteCase
    let agent: Agent
    let template: String
    let options: EvalOptions
    let attempt: Int
    /// The case's folder: its prompt, transcript and results. Agents can't read it.
    let workDir: URL
    /// What the agent may read (and runs in): `<case>/agent`, holding only the agent's config files.
    /// Transcripts stay one level up, out of its reach (Codex's sandbox can't deny a file pattern
    /// inside a folder it may read).
    var agentDir: URL { workDir.appendingPathComponent("agent", isDirectory: true) }

    private var runner: AgentRunner?
    private var completion: ((EvalCaseResult) -> Void)?
    private var turn = 0
    private var turnSuggestions: [[String]] = [[]]
    private var refused: [EvalRefusal] = []
    private var firstFile: Date?
    private var started = Date()
    private var costUSD: Double?
    private var lastPrompt = ""
    private var finished = false
    private var timeoutWork: DispatchWorkItem?

    private var evalCase: EvalCase { item.evalCase }
    private var searchFolders: [String]? { evalCase.searchFolders?.map { EvalPath.resolve($0, relativeTo: item.base) } }
    /// The case asks for isolation: the prompt points at its folders only.
    private var wantsIsolation: Bool { options.isolate && searchFolders != nil }
    /// … and the sandbox enforces it (not for Codex).
    private var isolated: Bool { wantsIsolation && agent.canIsolate }

    static func usesTools(_ item: SuiteCase, options: EvalOptions) -> Bool {
        EvalToolPolicy.usesTools(item.evalCase, inFixtureSuite: item.inFixtureSuite, withTools: options.withTools,
                                 withoutTools: options.withoutTools)
    }
    /// The user's tools this case runs with: all of the app's, or none (prompt, allowlist and sandbox
    /// profile alike).
    private var tools: [CustomTool] { Self.usesTools(item, options: options) ? EvalCLI.userTools : [] }

    init(item: SuiteCase, agent: Agent, template: String, options: EvalOptions, attempt: Int, workDir: URL) {
        self.item = item
        self.agent = agent
        self.template = template
        self.options = options
        self.attempt = attempt
        self.workDir = workDir
    }

    /// The first message, exactly as the picker flow would build it (plus a note for isolated runs).
    func firstPrompt() -> String {
        applyEnvironment()
        let context = evalCase.context
        // Never the real user's name: the case's own, the fixture persona, or none.
        let userName = context?.userName ?? (evalCase.source == "fixture" ? EvalCLI.fixturePersona : nil)
        let base = PromptBuilder.initial(PromptBuilder.Context(appName: context?.app ?? "an app", windowTitle: context?.windowTitle,
                                                               buttonTitle: context?.button,
                                                               userName: userName, tools: tools, agentID: agent.kind.id),
                                         template: template)
        var prompt = base
        if wantsIsolation, let folders = searchFolders {
            // The default template invites searching the rest of ~; a test run must not.
            prompt = prompt.replacingOccurrences(of: " Elsewhere in ~ is fine too.", with: "")
                .replacingOccurrences(of: "Elsewhere in ~ is fine too.", with: "")
            prompt += "\n\n(Test run: the user's files for this task are only in "
                + folders.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: ", ")
                + ". Search there only." + (isolated ? " Spotlight/mdfind is unavailable here; use ls, find and grep." : "") + ")"
        }
        lastPrompt = prompt
        let typed = evalCase.query.first.map { $0.isEmpty ? [] : [$0] } ?? []
        return PromptBuilder.withTyped(prompt, typed: typed)
    }

    /// Search folders are process-wide (read synchronously while building the prompt and launching);
    /// set them for this case before each launch.
    private func applyEnvironment() {
        SearchFolder.evalOverride = searchFolders
    }

    /// This case's launch settings, handed to its own runner (never shared between cases).
    private var launchOptions: AgentLaunchOptions {
        var o = AgentLaunchOptions()
        o.isEval = true
        o.appendTranscript = true
        o.transcriptURL = workDir.appendingPathComponent("last-run.jsonl")
        o.tools = tools
        if isolated, let folders = searchFolders {
            // All of ~ and /Volumes denied; the case's folders, its work folder and the agents' own
            // config/state allowed back (see EvalIsolation).
            o.extraSandboxRules = EvalIsolation.rules(home: FileManager.default.homeDirectoryForCurrentUser.path,
                                                      allowed: folders + [agentDir.path], agentExecutable: agent.path,
                                                      extraDenied: Settings.extraSearchFolders)
        }
        return o
    }

    /// Stops the agent and records the case as cancelled (SIGINT/SIGTERM).
    func cancel() {
        finish(status: "cancelled", error: "stopped before it finished")
    }

    func start(completion: @escaping (EvalCaseResult) -> Void) {
        self.completion = completion
        // Saved by an older version that searched on a screenshot alone: nothing to replay.
        guard evalCase.hasQuery else { return finish(status: "skipped", error: "screenshot-only case") }
        let prompt = firstPrompt()
        try? OwnerOnly.write(prompt, to: workDir.appendingPathComponent("prompt.txt"))
        try? OwnerOnly.createDirectory(agentDir)
        if wantsIsolation, !agent.canIsolate {
            Log.write("eval", "\(sensitive: evalCase.id): Codex runs under its own sandbox, so this case is not isolated (prompt only)")
        }
        let runner = AgentModels.makeRunner(for: agent.kind.id)
        runner.launchOptions = launchOptions
        self.runner = runner
        runner.onFile = { [weak self] path in self?.file(path) }
        runner.onTurnFinished = { [weak self] outcome in self?.turnFinished(outcome) }
        runner.onExit = { [weak self] outcome in
            guard let self, !self.finished else { return }
            self.finish(status: outcome.success ? "ok" : "error", error: outcome.success ? nil : outcome.summary)
        }
        started = Date()
        let work = DispatchWorkItem { [weak self] in self?.finish(status: "timeout", error: "no answer within \(Int(self?.options.timeout ?? 0))s") }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + options.timeout, execute: work)
        runner.start(executable: agent.path, model: agent.model, prompt: prompt, workDir: agentDir)
    }

    /// The dry-run sink: what LikelyFolder.add would accept, without copying.
    private func file(_ path: String) {
        guard !finished else { return }
        let screened = LikelyFolder.screen(path: path)
        let normalized = EvalPath.normalize(screened.source.path)
        if let reason = screened.refusal {
            refused.append(EvalRefusal(path: normalized, reason: reason))
            return
        }
        guard FileManager.default.fileExists(atPath: normalized) else {
            refused.append(EvalRefusal(path: normalized, reason: "doesn't exist"))
            return
        }
        guard !turnSuggestions[turn].contains(where: { EvalPath.same($0, normalized) }) else { return }
        turnSuggestions[turn].append(normalized)
        if firstFile == nil { firstFile = Date() }
    }

    private func turnFinished(_ outcome: AgentOutcome) {
        guard !finished else { return }
        if let cost = outcome.costUSD { costUSD = cost }   // Claude reports the session's running total
        guard outcome.success else { return finish(status: "error", error: outcome.summary) }
        let next = turn + 1
        guard next < evalCase.query.count, let runner else { return finish(status: "ok", error: nil) }
        // Like typing again in the bar: the current suggestions count as rejected.
        let message = PromptBuilder.followUp(evalCase.query[next], rejected: turnSuggestions[turn])
        turn = next
        turnSuggestions.append([])
        applyEnvironment()
        if !runner.send(message) {
            runner.start(executable: agent.path, model: agent.model, prompt: lastPrompt + "\n\n" + message, workDir: agentDir)
        }
    }

    private func finish(status: String, error: String?) {
        guard !finished else { return }
        finished = true
        timeoutWork?.cancel()
        runner?.cancel()
        runner = nil
        let total = Date().timeIntervalSince(started)
        let transcript = workDir.appendingPathComponent("last-run.jsonl")
        let transcriptCopy = workDir.appendingPathComponent("transcript.jsonl")
        try? FileManager.default.removeItem(at: transcriptCopy)
        let hasTranscript = (try? FileManager.default.moveItem(at: transcript, to: transcriptCopy)) != nil
        let tools = hasTranscript ? Self.countToolCalls(in: transcriptCopy, agentID: agent.kind.id) : nil
        if costUSD == nil, hasTranscript { costUSD = Self.lastCost(in: transcriptCopy) }

        let expected = ResolvedExpectation.resolve(evalCase.expect, relativeTo: item.base)
        let final = turnSuggestions.last ?? []
        let score = EvalScorer.score(suggestions: final, expected: expected, k: options.k)
        let result = EvalCaseResult(
            id: evalCase.id, query: evalCase.query, tags: evalCase.tags, expectKind: expected.kind, expected: expected.paths,
            attempt: attempt, status: score.scorable ? status : "unscored", error: error, suggestions: final,
            turnSuggestions: turnSuggestions, refused: refused, score: score, turns: turn + 1,
            firstFileSeconds: firstFile.map { $0.timeIntervalSince(started) }, totalSeconds: total, costUSD: costUSD,
            toolCalls: tools, transcriptPath: hasTranscript ? transcriptCopy.path : nil,
            promptPath: workDir.appendingPathComponent("prompt.txt").path, usedTools: Self.usesTools(item, options: options))
        let completion = self.completion
        self.completion = nil
        // Let the runner's cancellation settle before the next case starts.
        DispatchQueue.main.async { completion?(result) }
    }

    /// Tool calls in the agent's transcript (each runner writes its raw JSON stream to last-run.jsonl).
    static func countToolCalls(in url: URL, agentID: String) -> Int? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var count = 0
        for line in text.split(whereSeparator: \.isNewline) {
            guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            let type = event["type"] as? String
            switch agentID {
            case "claude":
                guard type == "assistant" else { continue }
                let content = (event["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
                count += content.filter { $0["type"] as? String == "tool_use" }.count
            case "codex":
                if type == "item.completed", (event["item"] as? [String: Any])?["type"] as? String == "command_execution" { count += 1 }
            default:   // opencode, gemini, hermes: one tool_use event per call
                if type == "tool_use" { count += 1 }
            }
        }
        return count
    }

    /// Claude's `result` events carry `total_cost_usd` (the runner already reports it; this is a fallback).
    static func lastCost(in url: URL) -> Double? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var cost: Double?
        for line in text.split(whereSeparator: \.isNewline) where line.contains("total_cost_usd") {
            if let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
               let value = event["total_cost_usd"] as? Double { cost = value }
        }
        return cost
    }
}

/// The SIGINT/SIGTERM handler: does nothing (EvalCLI's dispatch sources react). See handleSignals.
private func evalSignalNoop(_ signal: Int32) {}
