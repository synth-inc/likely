// Dev builds only (./build.sh, LIKELY_DEV): release builds have no eval mode at all.
#if LIKELY_DEV
import AppKit
import CryptoKit
import LikelyEvalKit

/// `Likely --eval …`: runs eval cases headlessly through the app's own prompt and agent runners, and
/// writes results.json + report.html. No menu bar item, onboarding, AX watching or copying into the
/// Likely folder: FILE lines go to a dry-run sink that records what Likely would have shown.
/// See docs/EVALS.md.
enum EvalCLI {
    /// The made-up person the fixture files belong to (evals/fixtures/generate.py).
    static let fixturePersona = "Jordan Rivera"

    static let usage = """
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
      --tags <a,b>        only cases with any of these tags
      --case <id,id>      only these cases
      --prompt-file <f>   use this prompt template instead of the one in Settings
      --out <dir>         results folder (default: …/Likely/evals/runs/<time>-<agent>-<model>)
      --no-isolate        don't sandbox cases that set searchFolders (see EVALS.md)
      --dry-run           print the prompts that would be sent; run nothing
      --verbose           also print Likely's log lines

    Eval mode exists only in dev builds (./build.sh).

    Exit status: 0 when the run completed (whatever the pass rate), 1 if results couldn't be written,
    2 on a usage/setup error, 130/143 when stopped by SIGINT/SIGTERM (partial results are written).
    """

    static func isRequested(_ arguments: [String]) -> Bool { arguments.contains("--eval") }

    private static var current: EvalSession?

    /// Never returns.
    static func main(_ arguments: [String]) -> Never {
        var options: Options
        do {
            options = try Options.parse(Array(arguments.dropFirst()))
        } catch {
            fail("\(error)\n\n\(usage)")
        }
        if options.help {
            print(usage)
            exit(0)
        }
        Log.echoToStderr = options.verbose
        Log.write("eval", "eval mode: \(arguments.dropFirst().joined(separator: " "))")

        let suite: Suite
        do { suite = try Suite.load(options.suite) } catch { fail("\(error)") }
        for warning in suite.warnings { printErr("warning: \(warning)") }
        var cases = suite.cases.filter { !$0.evalCase.needsExpected }
        let skipped = suite.cases.count - cases.count
        if !options.tags.isEmpty { cases = cases.filter { !Set($0.evalCase.tags).isDisjoint(with: options.tags) } }
        if !options.caseIDs.isEmpty { cases = cases.filter { options.caseIDs.contains($0.evalCase.id) } }
        guard !cases.isEmpty else { fail("No cases to run in \(options.suite)\(options.tags.isEmpty ? "" : " with tags \(options.tags.sorted())").") }
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
        if let file = options.promptFile {
            guard let text = try? String(contentsOfFile: (file as NSString).expandingTildeInPath, encoding: .utf8) else { fail("Can't read \(file)") }
            template = text
        }

        let agentID = options.agent ?? Settings.agentID
        guard let kind = AgentKind.with(id: agentID), kind.isSupported else {
            fail("Unknown or unsupported agent \"\(agentID)\". Supported: \(AgentKind.all.filter(\.isSupported).map(\.id).joined(separator: ", "))")
        }
        let model = options.model ?? AgentModels.selected(for: agentID)

        let wantsIsolation = options.isolate && cases.contains { $0.evalCase.searchFolders != nil }
        if wantsIsolation, kind.id == "codex" {
            printErr("warning: Codex runs inside its own sandbox, which can't be nested, so these cases are NOT isolated: "
                     + "Codex can read any of your files (only the prompt asks it to stay in the test folder). "
                     + "The run is recorded as not isolated.")
        }
        if wantsIsolation, kind.id == "hermes", options.jobs > 1 {
            fail("Hermes serves every case through one gateway, which runs inside the sandbox of the case that started it. Isolated Hermes runs need --jobs 1 (or --no-isolate).")
        }

        if options.dryRun {
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
            exit(0)
        }

        guard let path = options.agentPath ?? locate(agentID) else {
            fail("\(kind.name) not found. Install it, or pass --agent-path.")
        }
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

    private static var signalSources: [DispatchSourceSignal] = []

    /// Ctrl-C, or Stop in Settings (SIGTERM): stop the agents and write what finished.
    private static func handleSignals(_ session: EvalSession) {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { session.interrupt(signal: sig) }
            source.resume()
            signalSources.append(source)
        }
    }

    private static func locate(_ agentID: String) -> String? {
        let fm = FileManager.default
        if agentID == "claude", let saved = UserDefaults.standard.string(forKey: "claudePath"), fm.isExecutableFile(atPath: saved) {
            return saved
        }
        return AgentDetector.locateAll()[agentID]
    }

    static func fail(_ message: String) -> Never {
        printErr(message)
        exit(2)
    }

    static func printErr(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    // MARK: Options

    struct Options {
        var suite = ""
        var agent: String?
        var model: String?
        var agentPath: String?
        var k = 8
        var timeout: TimeInterval = 120
        var repeatCount = 1
        var jobs = 1
        var tags = Set<String>()
        var caseIDs = Set<String>()
        var promptFile: String?
        var out: String?
        var isolate = true
        var dryRun = false
        var verbose = false
        var help = false

        struct ParseError: Error, CustomStringConvertible { let description: String }

        static func parse(_ args: [String]) throws -> Options {
            var o = Options()
            var i = 0
            func value(_ flag: String) throws -> String {
                i += 1
                guard i < args.count else { throw ParseError(description: "\(flag) needs a value") }
                return args[i]
            }
            func int(_ flag: String) throws -> Int {
                let v = try value(flag)
                guard let n = Int(v), n > 0 else { throw ParseError(description: "\(flag) needs a positive number, got \(v)") }
                return n
            }
            func list(_ s: String) -> Set<String> {
                Set(s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
            }
            while i < args.count {
                let arg = args[i]
                switch arg {
                case "--eval": o.suite = try value(arg)
                case "--agent": o.agent = try value(arg)
                case "--model": o.model = try value(arg)
                case "--agent-path": o.agentPath = try value(arg)
                case "--k": o.k = try int(arg)
                case "--timeout": o.timeout = TimeInterval(try int(arg))
                case "--repeat": o.repeatCount = try int(arg)
                case "--jobs": o.jobs = try int(arg)
                case "--tags": o.tags = list(try value(arg))
                case "--case", "--cases": o.caseIDs = list(try value(arg))
                case "--prompt-file": o.promptFile = try value(arg)
                case "--out": o.out = try value(arg)
                case "--no-isolate": o.isolate = false
                case "--isolate": o.isolate = true
                case "--dry-run": o.dryRun = true
                case "--verbose": o.verbose = true
                case "--help", "-h": o.help = true
                default:
                    // Xcode/launchd may add -NSDocumentRevisionsDebugMode etc.; ignore those.
                    if arg.hasPrefix("-NS") || arg.hasPrefix("-Apple") { i += 1 } else {
                        throw ParseError(description: "Unknown option \(arg)")
                    }
                }
                i += 1
            }
            if o.suite.isEmpty && !o.help { throw ParseError(description: "--eval needs a suite") }
            return o
        }
    }
}

// MARK: - Suites

struct SuiteCase {
    let evalCase: EvalCase
    /// The folder of the cases file: relative paths in the case resolve against it.
    let base: URL
}

struct Suite {
    let name: String
    let files: [URL]
    let cases: [SuiteCase]
    let warnings: [String]

    struct LoadError: Error, CustomStringConvertible { let description: String }

    static func load(_ spec: String) throws -> Suite {
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
        for file in files {
            guard FileManager.default.fileExists(atPath: file.path) else {
                if spec == "all" { warnings.append("\(file.path) doesn't exist"); continue }
                throw LoadError(description: "No cases file at \(file.path)")
            }
            let (loaded, errors) = try EvalCaseFile.load(file)
            warnings += errors.map { "\(file.lastPathComponent) \($0)" }
            for c in loaded {
                if seen.contains(c.id) { warnings.append("duplicate case id \(c.id) in \(file.lastPathComponent); both run") }
                seen.insert(c.id)
                cases.append(SuiteCase(evalCase: c, base: file.deletingLastPathComponent()))
            }
        }
        let name = ["fixtures", "personal", "mine", "all"].contains(spec) ? (spec == "mine" ? "personal" : spec) : files[0].path
        return Suite(name: name, files: files, cases: cases, warnings: warnings)
    }

    /// evals/fixtures/cases.jsonl: $LIKELY_FIXTURES, the app bundle (dev builds), or the repo the binary
    /// was built in (walking up from the executable), or the current directory.
    static func fixturesFile() throws -> URL {
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
    let options: EvalCLI.Options
    let runDir: URL
    private let startedAt = Date()
    /// (index in `cases`, case, attempt)
    private var queue: [(Int, SuiteCase, Int)] = []
    private var running: [EvalCaseRun] = []
    /// With the case's index, so the report keeps suite order (ids needn't be unique).
    private var results: [(index: Int, result: EvalCaseResult)] = []
    private var total = 0
    private var interruptedBy: Int32?

    init(suite: Suite, cases: [SuiteCase], agent: EvalCaseRun.Agent, template: String, options: EvalCLI.Options) {
        self.suite = suite
        self.cases = cases
        self.agent = agent
        self.template = template
        self.options = options
        if let out = options.out {
            runDir = URL(fileURLWithPath: (out as NSString).expandingTildeInPath, isDirectory: true)
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
            try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        } catch {
            EvalCLI.fail("Can't create \(runDir.path): \(error)")
        }
        print("Running \(total) case\(total == 1 ? "" : "s") from \(suite.name) with \(agent.kind.name) · \(agent.model)")
        print("Results: \(runDir.path)")
        fflush(stdout)
        fill()
    }

    private func fill() {
        while interruptedBy == nil, running.count < options.jobs, !queue.isEmpty {
            let (index, item, attempt) = queue.removeFirst()
            let folder = EvalStorage.caseFolderName(index: index, id: item.evalCase.id, attempt: attempt, repeated: options.repeatCount > 1)
            let workDir = runDir.appendingPathComponent("cases/\(folder)", isDirectory: true)
            try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
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
        if interruptedBy != nil { exit(128 + signal) }
        interruptedBy = signal
        EvalCLI.printErr("\nStopping: cancelling \(running.count) running case\(running.count == 1 ? "" : "s"), skipping \(queue.count); writing partial results…")
        queue.removeAll()
        if running.isEmpty { return finish() }
        for run in running { run.cancel() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            HermesRunner.stopEvalGateway()
            exit(128 + signal)
        }
    }

    private func finished(_ raw: EvalCaseResult, index: Int, relativeTo workDir: URL) {
        var result = raw
        let rel = workDir.path.replacingOccurrences(of: runDir.path + "/", with: "")
        if result.transcriptPath != nil { result.transcriptPath = rel + "/transcript.jsonl" }
        if result.promptPath != nil { result.promptPath = rel + "/prompt.txt" }
        results.append((index, result))
        let mark = !result.score.scorable ? "?" : result.pass ? "PASS" : "FAIL"
        var line = "[\(results.count)/\(total)] \(mark) \(result.id)"
        if options.repeatCount > 1 { line += " #\(result.attempt)" }
        line += "  rank \(result.score.firstHitRank.map(String.init) ?? "–")  \(String(format: "%.1fs", result.totalSeconds))"
        if let cost = result.costUSD { line += String(format: "  $%.4f", cost) }
        if result.status != "ok" { line += "  [\(result.status)\(result.error.map { ": \($0.prefix(80))" } ?? "")]" }
        print(line)
        fflush(stdout)
        fill()
    }

    private func finish() {
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
                          interrupted: interruptedBy == nil ? nil : true)
        let previous = EvalRun.previous(of: run, in: runDir.deletingLastPathComponent(), excluding: runDir)
        var status: Int32 = interruptedBy.map { 128 + $0 } ?? 0
        do {
            try run.write(to: runDir.appendingPathComponent("results.json"))
            try template.write(to: runDir.appendingPathComponent("prompt-template.txt"), atomically: true, encoding: .utf8)
            let report = runDir.appendingPathComponent("report.html")
            try EvalReport.html(run, previous: previous?.0, previousPath: previous?.1.path).write(to: report, atomically: true, encoding: .utf8)
            try? FileManager.default.createDirectory(at: EvalStorage.root, withIntermediateDirectories: true)
            try? report.path.write(to: EvalStorage.lastRunURL, atomically: true, encoding: .utf8)
            print("")
            print(EvalReport.textSummary(run, previous: previous?.0))
            print("Report: \(report.path)")
        } catch {
            EvalCLI.printErr("Couldn't write results: \(error)")
            status = 1
        }
        fflush(stdout)
        exit(status)
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
        /// Everything except Claude Code gets the screenshot attached (as in Coordinator).
        var takesImages: Bool { kind.id != "claude" }
        /// Codex runs under its own sandbox, which can't be nested: no isolation rules for it.
        var canIsolate: Bool { kind.id != "codex" }
    }

    let item: SuiteCase
    let agent: Agent
    let template: String
    let options: EvalCLI.Options
    let attempt: Int
    let workDir: URL

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
    private var screenshot: URL? {
        evalCase.context?.screenshot.map { URL(fileURLWithPath: EvalPath.resolve($0, relativeTo: item.base)) }
    }
    private var searchFolders: [String]? { evalCase.searchFolders?.map { EvalPath.resolve($0, relativeTo: item.base) } }
    /// The case asks for isolation: the prompt points at its folders only.
    private var wantsIsolation: Bool { options.isolate && searchFolders != nil }
    /// … and the sandbox enforces it (not for Codex).
    private var isolated: Bool { wantsIsolation && agent.canIsolate }

    init(item: SuiteCase, agent: Agent, template: String, options: EvalCLI.Options, attempt: Int, workDir: URL) {
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
                                                               buttonTitle: context?.button, screenshot: screenshot,
                                                               userName: userName),
                                         imageAttached: agent.takesImages, template: template)
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
        if isolated, let folders = searchFolders {
            // All of ~ and /Volumes denied; the case's folders, its work folder and the agents' own
            // config/state allowed back (see EvalIsolation).
            o.extraSandboxRules = EvalIsolation.rules(home: FileManager.default.homeDirectoryForCurrentUser.path,
                                                      allowed: folders + [workDir.path], agentExecutable: agent.path,
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
        let prompt = firstPrompt()
        try? prompt.write(to: workDir.appendingPathComponent("prompt.txt"), atomically: true, encoding: .utf8)
        if wantsIsolation, !agent.canIsolate {
            Log.write("eval", "\(evalCase.id): Codex runs under its own sandbox, so this case is not isolated (prompt only)")
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
        runner.start(executable: agent.path, model: agent.model, prompt: prompt,
                     image: agent.takesImages ? screenshot : nil, workDir: workDir)
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
            runner.start(executable: agent.path, model: agent.model, prompt: lastPrompt + "\n\n" + message,
                         image: agent.takesImages ? screenshot : nil, workDir: workDir)
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
            promptPath: workDir.appendingPathComponent("prompt.txt").path)
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
#endif
