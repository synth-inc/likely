import Foundation
import LikelyStorage

/// `Likely --eval …`'s exit status. See docs/EVALS.md.
public enum EvalExit {
    /// The run completed, whatever the pass rate.
    public static let completed: Int32 = 0
    /// Something went wrong: no agent, no tests, another run in progress, results not written, …
    public static let failed: Int32 = 1
    /// A usage error: unknown or refused option, bad value.
    public static let usage: Int32 = 2
    /// A paid build without an active license (the same check as searches).
    public static let unlicensed: Int32 = 3
    /// Release builds: "Allow command-line test runs" (Settings → Tests) is off.
    public static let notAllowed: Int32 = 4
    /// Stopped by a signal (SIGINT 130, SIGTERM 143): partial results are written.
    public static func interrupted(by signal: Int32) -> Int32 { 128 + signal }
}

/// Options for `Likely --eval`, and which of them a build accepts.
///
/// Release builds accept a safe subset (`Policy.release`): only the user's own cases in Likely's data
/// folder (`--eval personal`), only agents Likely detected itself, at their detected paths, and the
/// prompt saved in Settings. Nothing on the command line can choose a program, a prompt file, a cases
/// file or a results folder, so another process can't use `Likely --eval` to make Likely (and the
/// permissions macOS gave it) run something of its choosing. Dev builds (`./build.sh`) accept everything.
public struct EvalOptions: Equatable {
    public enum Policy: Equatable { case dev, release }

    public var suite = ""
    public var agent: String?
    public var model: String?
    public var agentPath: String?
    public var k = 8
    public var timeout: TimeInterval = 120
    public var repeatCount = 1
    public var jobs = 1
    public var tags = Set<String>()
    public var caseIDs = Set<String>()
    public var promptFile: String?
    public var out: String?
    public var isolate = true
    public var withTools = false
    public var withoutTools = false
    public var dryRun = false
    public var verbose = false
    public var json = false
    public var help = false

    public init() {}

    /// Agent ids `--agent` accepts (the ones Likely has runners for).
    public static let agentIDs = ["claude", "codex", "gemini", "opencode", "hermes"]

    /// Suites a release build runs: the user's own cases only.
    public static let releaseSuites = ["personal"]

    /// Options only dev builds accept: each lets the caller choose a program, a file or a folder Likely
    /// would use, or changes how the public fixtures run.
    public static let devOnlyFlags: [String: String] = [
        "--agent-path": "choose the agent executable",
        "--prompt-file": "use a prompt template file",
        "--out": "choose the results folder",
        "--no-isolate": "change fixture isolation",
        "--isolate": "change fixture isolation",
        "--dry-run": "print prompts without running",
    ]

    public struct ParseError: Error, CustomStringConvertible, Equatable {
        public let description: String
        public init(_ description: String) { self.description = description }
    }

    /// A model name as agents take it ("sonnet", "opencode/deepseek-v4.1-flash-free",
    /// "anthropic/claude-haiku-5.5", "gpt-5.6-luna"): never an option ("-…"), no spaces or quotes.
    public static func isValidModel(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:/@+\-]{0,99}$"#, options: .regularExpression) != nil
    }

    /// Case ids and tags: plain text, never an option.
    static func isValidFilterValue(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("-") && value.count <= 200
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    public static func parse(_ args: [String], policy: Policy) throws -> EvalOptions {
        var o = EvalOptions()
        var i = 0
        var sawWith = false
        func value(_ flag: String) throws -> String {
            i += 1
            guard i < args.count else { throw ParseError("\(flag) needs a value") }
            let v = args[i]
            // In release builds no value may look like an option: Foundation reads `-key value` pairs
            // anywhere on the command line as preference overrides (NSArgumentDomain).
            if policy == .release, v.hasPrefix("-") { throw ParseError("\(flag) needs a value, got \(v)") }
            return v
        }
        func int(_ flag: String, _ range: ClosedRange<Int>) throws -> Int {
            let v = try value(flag)
            guard let n = Int(v), n > 0 else { throw ParseError("\(flag) needs a positive number, got \(v)") }
            if policy == .release, !range.contains(n) {
                throw ParseError("\(flag) must be between \(range.lowerBound) and \(range.upperBound), got \(n)")
            }
            return n
        }
        func list(_ flag: String, _ s: String) throws -> Set<String> {
            let items = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            for item in items where !isValidFilterValue(item) { throw ParseError("\(flag): invalid value \(item)") }
            return Set(items)
        }
        while i < args.count {
            let arg = args[i]
            if policy == .release, let what = devOnlyFlags[arg] {
                throw ParseError("\(arg) isn't available in this build: release builds can't \(what). "
                                 + "Tests run with the agent Likely detected and the prompt in Settings.")
            }
            switch arg {
            case "--eval":
                o.suite = try value(arg)
                if policy == .release, !releaseSuites.contains(o.suite) {
                    throw ParseError("--eval \(o.suite): release builds run only your own tests (--eval personal), "
                                     + "saved in Likely → Settings → Tests. Public fixtures and cases files are for dev builds.")
                }
            case "--agent":
                let id = try value(arg)
                guard agentIDs.contains(id) else { throw ParseError("Unknown agent \"\(id)\". Supported: \(agentIDs.joined(separator: ", "))") }
                o.agent = id
            case "--model":
                let m = try value(arg)
                if policy == .release, !isValidModel(m) { throw ParseError("--model: invalid model name \(m)") }
                o.model = m
            case "--agent-path": o.agentPath = try value(arg)
            case "--k": o.k = try int(arg, 1...8)
            case "--timeout": o.timeout = TimeInterval(try int(arg, 10...600))
            case "--repeat": o.repeatCount = try int(arg, 1...5)
            case "--jobs": o.jobs = try int(arg, 1...4)
            case "--tag", "--tags": o.tags.formUnion(try list(arg, try value(arg)))
            case "--case", "--cases": o.caseIDs.formUnion(try list(arg, try value(arg)))
            case "--prompt-file": o.promptFile = try value(arg)
            case "--out": o.out = try value(arg)
            case "--no-isolate": o.isolate = false
            case "--isolate": o.isolate = true
            case "--with-tools": o.withTools = true; sawWith = true
            case "--without-tools": o.withoutTools = true
            case "--dry-run": o.dryRun = true
            case "--verbose": o.verbose = true
            case "--json": o.json = true
            case "--help", "-h": o.help = true
            default:
                // Xcode/launchd may add -NSDocumentRevisionsDebugMode etc. to a dev build's arguments.
                // Release builds refuse them: they'd set Likely's preferences for this run.
                if policy == .dev, arg.hasPrefix("-NS") || arg.hasPrefix("-Apple") {
                    i += 1
                } else {
                    throw ParseError(arg.hasPrefix("-") ? "Unknown option \(arg)" : "Unexpected argument \(arg)")
                }
            }
            i += 1
        }
        if sawWith && o.withoutTools { throw ParseError("--with-tools and --without-tools can't be used together") }
        if o.suite.isEmpty && !o.help { throw ParseError("--eval needs a suite") }
        return o
    }

    /// Whether `--json` was asked for, read before parsing (so a usage error can be reported as JSON).
    public static func wantsJSON(_ args: [String]) -> Bool { args.contains("--json") }
}

/// The environment a release build's `--eval` runs in: what launchd gives the app when it's opened
/// from the Finder, rebuilt from the user database, never taken from the caller. Everything else
/// (DYLD_*, NODE_OPTIONS, PYTHONPATH, ZDOTDIR, BASH_ENV, CFFIXED_USER_HOME, a PATH with the caller's
/// folders first, …) could make Likely or the agents it starts load or run a program of the caller's
/// choosing, or read another "home" folder's settings and tools. Locale variables are kept when
/// they look like locale names.
public enum EvalEnvironment {
    public static let path = "/usr/bin:/bin:/usr/sbin:/sbin"

    static let localeKeys = ["LANG", "LC_ALL", "LC_CTYPE", "LC_MESSAGES"]

    /// Network settings people set for GUI apps with `launchctl setenv` (proxies, a corporate CA): the
    /// app gets them from launchd, so the run takes them from launchd too (never from the caller).
    public static let launchdKeys = ["HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "no_proxy",
                                     "all_proxy", "SSL_CERT_FILE", "SSL_CERT_DIR", "NODE_EXTRA_CA_CERTS", "REQUESTS_CA_BUNDLE"]

    /// `launchd`: values of `launchdKeys` as `launchctl getenv` reports them (others are ignored).
    public static func sanitized(_ env: [String: String], home: String, user: String, shell: String, tmpdir: String?,
                                 launchd: [String: String] = [:], passThrough: Set<String> = []) -> [String: String] {
        var clean: [String: String] = ["HOME": home, "USER": user, "LOGNAME": user, "SHELL": shell, "PATH": path]
        if let tmpdir, !tmpdir.isEmpty { clean["TMPDIR"] = tmpdir }
        for key in localeKeys {
            if let v = env[key], v.range(of: #"^[A-Za-z0-9_.@\-]{1,64}$"#, options: .regularExpression) != nil { clean[key] = v }
        }
        if let v = env["__CF_USER_TEXT_ENCODING"],
           v.range(of: #"^0x[0-9A-Fa-f]{1,8}:0x[0-9A-Fa-f]{1,8}:0x[0-9A-Fa-f]{1,8}$"#, options: .regularExpression) != nil {
            clean["__CF_USER_TEXT_ENCODING"] = v
        }
        for key in launchdKeys {
            if let v = launchd[key], !v.isEmpty, v.count < 4096, !v.contains(where: { $0.isNewline || $0 == "\u{0}" }) { clean[key] = v }
        }
        // Settings → Tests → Run Tests' one-time token (RunToken): kept across the restart when it has
        // a token's shape; it only counts if the app's sealed record matches it.
        if let v = env[RunToken.environmentKey], RunToken.isWellFormed(v) { clean[RunToken.environmentKey] = v }
        for key in passThrough { if let v = env[key] { clean[key] = v } }
        return clean
    }

    /// Variables macOS itself adds to a process it starts (CoreFoundation's text encoding), so they can't
    /// tell whether the caller's environment was used.
    static let systemAdded: Set<String> = ["__CF_USER_TEXT_ENCODING"]

    /// The variables of `current` that differ from `clean` (names only): restart when non-empty.
    public static func differences(_ current: [String: String], from clean: [String: String]) -> [String] {
        Set(current.keys).union(clean.keys).subtracting(systemAdded).filter { current[$0] != clean[$0] }.sorted()
    }
}

/// What `Likely --eval … --json` prints on stdout: the run's numbers, the tools it used, and the
/// comparison with the previous run, for a coding agent to read. results.json in the run folder has
/// everything else. The fields are documented in docs/EVALS.md.
public struct EvalCLIResult: Codable, Equatable {
    public struct Summary: Codable, Equatable {
        public var cases: Int
        public var scored: Int
        public var passed: Int
        public var failed: Int
        public var passRate: Double
        public var hitAt1: Double
        public var hitAt3: Double
        public var hitAtK: Double
        public var meanRecall: Double
        public var medianFirstFileSeconds: Double?
        public var medianTotalSeconds: Double?
        public var totalCostUSD: Double?
        public var timeouts: Int
        public var errors: Int
    }

    public struct Tools: Codable, Equatable {
        /// The tools the agent got (enabled, approved, and their private data allowed).
        public var active: [EvalToolSet.Tool]
        /// Hash of the whole set ("" for none).
        public var hash: String
        /// Tools changed outside Likely that wait for Approve in Settings → Tools: not used by this run.
        public var pendingApproval: [String]
        /// Cases that ran without them (`--without-tools`, or `"useTools": false`).
        public var casesWithoutTools: Int
    }

    public struct Case: Codable, Equatable {
        public var id: String
        public var attempt: Int
        public var pass: Bool
        /// ok, timeout, error, cancelled, unscored, skipped (not run: a screenshot-only test from an older version)
        public var status: String
        /// 1-based rank of the first expected file among the suggestions; nil if none was suggested.
        public var rank: Int?
        public var totalSeconds: Double
        public var firstFileSeconds: Double?
        public var costUSD: Double?
        public var usedTools: Bool?
        public var error: String?
    }

    public struct Comparison: Codable, Equatable {
        public var previousRunFolder: String
        public var previousStartedAt: String
        public var previousAgent: String
        public var previousModel: String
        public var previousPassed: Int
        public var previousScored: Int
        public var previousPassRate: Double
        public var passedDelta: Int
        public var passRateDelta: Double
        /// Settings that differ (agent, model, k, tag or case filter): not like for like when non-empty.
        public var settingsDiffer: [String]
        /// The tools differ from the previous run's (`toolChanges`: +id added, -id removed, ~id edited).
        public var toolsChanged: Bool
        public var toolChanges: [String]
        public var nowPassing: [String]
        public var nowFailing: [String]
    }

    public var schema = "likely-eval/1"
    /// completed, interrupted or error
    public var status: String
    public var exitCode: Int32
    public var error: String?
    public var suite: String?
    public var agent: String?
    public var model: String?
    public var k: Int?
    public var promptHash: String?
    public var runFolder: String?
    public var resultsPath: String?
    public var reportPath: String?
    public var summary: Summary?
    public var tools: Tools?
    public var cases: [Case]?
    /// Nil when there's no earlier run of this suite.
    public var comparison: Comparison?

    public static func failure(_ message: String, exitCode: Int32) -> EvalCLIResult {
        EvalCLIResult(status: "error", exitCode: exitCode, error: message)
    }

    public static func make(run: EvalRun, runFolder: URL, previous: (EvalRun, URL)?, pendingTools: [String],
                            exitCode: Int32) -> EvalCLIResult {
        let s = run.summary
        var result = EvalCLIResult(status: run.interrupted == true ? "interrupted" : "completed", exitCode: exitCode)
        result.suite = run.suite
        result.agent = run.agent
        result.model = run.model
        result.k = run.k
        result.promptHash = run.promptHash
        result.runFolder = runFolder.path
        result.resultsPath = runFolder.appendingPathComponent("results.json").path
        result.reportPath = runFolder.appendingPathComponent("report.html").path
        result.summary = Summary(cases: s.cases, scored: s.scored, passed: s.passed, failed: s.scored - s.passed,
                                 passRate: s.passRate, hitAt1: s.hitAt1, hitAt3: s.hitAt3, hitAtK: s.hitAtK,
                                 meanRecall: s.meanRecall, medianFirstFileSeconds: s.medianFirstFileSeconds,
                                 medianTotalSeconds: s.medianTotalSeconds, totalCostUSD: s.totalCostUSD,
                                 timeouts: s.timeouts, errors: s.errors)
        let tools = run.tools ?? .empty
        result.tools = Tools(active: tools.tools, hash: tools.hash, pendingApproval: pendingTools.sorted(),
                             casesWithoutTools: run.cases.filter { $0.usedTools == false }.count)
        result.cases = run.cases.map {
            Case(id: $0.id, attempt: $0.attempt, pass: $0.pass, status: $0.status, rank: $0.score.firstHitRank,
                 totalSeconds: $0.totalSeconds, firstFileSeconds: $0.firstFileSeconds, costUSD: $0.costUSD,
                 usedTools: $0.usedTools, error: $0.error)
        }
        if let (before, folder) = previous {
            let p = before.summary
            let changes = EvalReport.caseChanges(run, before)
            let toolChanges = run.toolChanges(since: before)
            result.comparison = Comparison(
                previousRunFolder: folder.path, previousStartedAt: before.startedAt, previousAgent: before.agent,
                previousModel: before.model, previousPassed: p.passed, previousScored: p.scored, previousPassRate: p.passRate,
                passedDelta: s.passed - p.passed, passRateDelta: s.passRate - p.passRate,
                settingsDiffer: run.mismatches(with: before), toolsChanged: !toolChanges.isEmpty, toolChanges: toolChanges,
                nowPassing: changes.fixed, nowFailing: changes.broke)
        }
        return result
    }

    public func encoded() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(self)) ?? Data("{}".utf8), as: UTF8.self)
    }
}

/// Where `--eval` looks for agents in release builds: fixed install folders only, never a login shell
/// (whose rc files anything can edit) and never a saved path that detection doesn't also find.
public enum AgentLocations {
    /// The folders, in order: ~/.local/bin, ~/.claude/local, Homebrew, /usr/local/bin, npm's and bun's
    /// global bins, then each nvm Node version's bin (newest first).
    public static func folders(home: String, fileManager fm: FileManager = .default) -> [String] {
        var dirs = ["\(home)/.local/bin", "\(home)/.claude/local", "/opt/homebrew/bin", "/usr/local/bin",
                    "\(home)/.npm-global/bin", "\(home)/.bun/bin"]
        let nvm = "\(home)/.nvm/versions/node"
        let versions = ((try? fm.contentsOfDirectory(atPath: nvm)) ?? []).filter { $0.hasPrefix("v") && !$0.contains("/") }
        dirs += versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }.map { "\(nvm)/\($0)/bin" }
        return dirs
    }

    /// Every executable named `name` in `folders`, in order.
    public static func candidates(_ name: String, in folders: [String], fileManager fm: FileManager = .default) -> [String] {
        folders.map { "\($0)/\(name)" }.filter { fm.isExecutableFile(atPath: $0) }
    }

    /// The saved path (Settings) when it's one of the candidates, else the first candidate.
    public static func choose(saved: String?, candidates: [String]) -> String? {
        if let saved, candidates.contains(saved) { return saved }
        return candidates.first
    }
}

/// Collects a child process's stdout and stderr and reports once the process has exited AND both pipes
/// have reached end of file, so nothing written just before exit is lost (a process can exit while a
/// child it started still holds the pipe; the termination handler alone fires too early).
public final class ProcessOutputCollector {
    public private(set) var stdout = Data()
    private let group = DispatchGroup()
    private let lock = NSLock()

    /// `onStderrLine`: each complete stderr line, as it arrives (on `queue`). `completion`: once, on `queue`,
    /// with everything stdout wrote and the exit status.
    public init(process: Process, queue: DispatchQueue = .main, onStderrLine: @escaping (String) -> Void,
                completion: @escaping (_ stdout: Data, _ status: Int32) -> Void) {
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        group.enter()
        group.enter()
        group.enter()
        var errBuffer = Data()
        outPipe.fileHandleForReading.readabilityHandler = { [weak self, group] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                group.leave()
                return
            }
            self?.lock.lock()
            self?.stdout.append(data)
            self?.lock.unlock()
        }
        errPipe.fileHandleForReading.readabilityHandler = { [group] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                if !errBuffer.isEmpty {
                    let rest = String(decoding: errBuffer, as: UTF8.self)
                    queue.async { onStderrLine(rest) }
                    errBuffer = Data()
                }
                group.leave()
                return
            }
            errBuffer.append(data)
            while let newline = errBuffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = String(decoding: errBuffer[errBuffer.startIndex..<newline], as: UTF8.self)
                errBuffer.removeSubrange(errBuffer.startIndex...newline)
                queue.async { onStderrLine(line) }
            }
        }
        var status: Int32 = 0
        process.terminationHandler = { [group] p in
            status = p.terminationStatus
            group.leave()
        }
        group.notify(queue: queue) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let out = self.stdout
            self.lock.unlock()
            completion(out, status)
        }
    }
}
