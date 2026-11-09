import Foundation
import LikelyTools

/// A coding agent run headless for one picker. Implementations parse the agent's streamed output into
/// `STATUS:` progress, `FILE:` candidates and turn results, and accept follow-up feedback.
protocol AgentRunner: AnyObject {
    var onStatus: ((String) -> Void)? { get set }
    var onFile: ((String) -> Void)? { get set }
    /// After each turn (the first answer, and each answer to feedback).
    var onTurnFinished: ((AgentOutcome) -> Void)? { get set }
    /// The process ended without being cancelled (crash, auth failure, …).
    var onExit: ((AgentOutcome) -> Void)? { get set }

    var isBusy: Bool { get }
    /// Per-runner launch settings (evals set these; the app uses the defaults).
    var launchOptions: AgentLaunchOptions { get set }

    /// `image` is the screenshot, for agents that take images as input rather than reading files.
    func start(executable: String, model: String, prompt: String, image: URL?, workDir: URL)
    /// Sends feedback to the current conversation. Returns false if there's no conversation to continue.
    @discardableResult func send(_ text: String) -> Bool
    func cancel()
}

/// Settings that belong to one runner, never to the process: with `--eval --jobs n` several runners
/// launch at once, each for a different case.
struct AgentLaunchOptions {
    /// Seatbelt rules appended to the runner's profile (an isolated eval case). Codex ignores them:
    /// it runs under its own sandbox, which can't be nested.
    var extraSandboxRules = ""
    /// Append to last-run.jsonl instead of starting it over (evals keep every turn of a case,
    /// including relaunches).
    var appendTranscript = false
    /// Launched by `--eval`: Hermes then never reuses a gateway it didn't start with these rules.
    var isEval = false
    /// The user's tools this launch may use (allowlist and sandbox profile). nil: the ones the app
    /// uses (ToolStore's enabled, approved tools). Evals set it per case; [] means none.
    var tools: [CustomTool]?
}

/// The raw JSON stream each runner saves to <workDir>/last-run.jsonl.
enum AgentTranscript {
    static func open(_ url: URL, append: Bool) -> FileHandle? {
        let fm = FileManager.default
        if !append || !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        if append { _ = try? handle.seekToEnd() }
        return handle
    }
}

struct AgentOutcome {
    let success: Bool
    let summary: String
    let costUSD: Double?
}

/// Shared parsing of the STATUS: / FILE: protocol and friendly fallback statuses.
enum AgentProtocol {
    static func parse(text: String, onStatus: ((String) -> Void)?, onFile: ((String) -> Void)?) {
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "`*-"))
                .trimmingCharacters(in: .whitespaces)
            if let status = line.dropPrefix("STATUS:") {
                onStatus?(status)
            } else if let path = line.dropPrefix("FILE:") {
                onFile?((path as NSString).expandingTildeInPath)
            }
        }
    }

    /// Progress text for a shell command, for when the agent doesn't narrate.
    static func status(forCommand rawCommand: String) -> String {
        // Codex wraps commands as `/bin/zsh -lc '…'`.
        var command = rawCommand.trimmingCharacters(in: .whitespaces)
        if let range = command.range(of: "-lc ") {
            command = String(command[range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "'\" "))
        }
        switch command.split(separator: " ").first {
        case "mdfind": return "Searching Spotlight"
        case "mdls": return "Checking file details"
        case "ls", "find": return "Looking through recent files"
        case "grep", "rg": return "Filtering results"
        case "cat", "head", "file", "stat": return "Checking a file"
        default: return "Searching"
        }
    }
}

extension String {
    func dropPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        let rest = dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : rest
    }
}

/// Runs OpenAI's Codex CLI: `codex exec --json` in its read-only sandbox (commands run, writes are
/// blocked), with the screenshot attached via `-i`. Codex can't take messages mid-turn, so feedback
/// stops the current turn and continues the same conversation with `codex exec resume <thread>`.
///
/// Unlike the other runners it isn't wrapped in AgentSandbox: Codex runs every command under its own
/// Seatbelt policy (deny-by-default, no Apple Events, WindowServer or AX services), and macOS doesn't
/// allow a sandboxed process to apply another sandbox, so an outer one would break Codex's.
///
/// Codex has no per-command allowlist: in `exec` mode it runs whatever command the model asks for,
/// inside that read-only sandbox (no writes, no network). So the user's tools (ToolStore) need no
/// permission here; they reach Codex through the prompt only.
final class CodexRunner: AgentRunner {
    var onStatus: ((String) -> Void)?
    var onFile: ((String) -> Void)?
    var onTurnFinished: ((AgentOutcome) -> Void)?
    var onExit: ((AgentOutcome) -> Void)?
    var launchOptions = AgentLaunchOptions()

    private(set) var isBusy = false
    private var process: Process?
    private var buffer = Data()
    private var threadID: String?
    private var executable: String?
    private var model = ""
    private var workDir: URL?
    private var turnEnded = false
    private var transcript: FileHandle?

    /// Run without the user's ~/.codex/config.toml (their default model may not be available to
    /// ChatGPT sign-ins, and their MCP servers/hooks would slow things down). Auth is unaffected.
    /// Sandbox: a permission profile that extends Codex's built-in read-only one and also makes
    /// Likely's search history unreadable (same paths as AgentSandbox.historyRules). Equivalent to
    /// `sandbox_mode="read-only"` otherwise; the two can't be combined. Verified with
    /// `codex sandbox` (codex-cli 0.153): reads under the denied paths fail with EPERM.
    private static let baseArguments: [String] = {
        let denied = AgentSandbox.historyDeniedPaths
        let entries = (denied.folders + denied.files).map { "\(tomlString($0)) = \"none\"" }.joined(separator: ", ")
        return ["--json", "--skip-git-repo-check", "--ignore-user-config",
                "-c", "default_permissions=\"likely\"",
                "-c", "permissions.likely.extends=\":read-only\"",
                "-c", "permissions.likely.filesystem={ \(entries) }"]
    }()

    private static func tomlString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    func start(executable: String, model: String, prompt: String, image: URL?, workDir: URL) {
        cancel()
        threadID = nil
        self.executable = executable
        self.model = model
        self.workDir = workDir
        let transcriptURL = workDir.appendingPathComponent("last-run.jsonl")
        transcript = AgentTranscript.open(transcriptURL, append: launchOptions.appendTranscript)

        var arguments = ["exec"] + Self.baseArguments + ["-m", model, prompt]
        if let image { arguments += ["-i", image.path] }   // after the prompt: -i takes several values
        launch(arguments)
    }

    @discardableResult
    func send(_ text: String) -> Bool {
        guard let threadID, executable != nil else { return false }
        // No mid-turn input: stop the current turn (the conversation so far is kept) and resume.
        stopProcess()
        launch(["exec", "resume"] + Self.baseArguments + ["-m", model, threadID, text])
        return true
    }

    func cancel() {
        stopProcess()
        threadID = nil
        try? transcript?.close()
        transcript = nil
    }

    private func stopProcess() {
        guard let process else { return }
        self.process = nil
        isBusy = false
        (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (process.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
            Log.write("codex", "stopped pid=\(process.processIdentifier)")
        }
    }

    private func launch(_ arguments: [String]) {
        guard let executable, let workDir else { return }
        buffer = Data()
        turnEnded = false

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.currentDirectoryURL = workDir
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = AgentPath.value(agentExecutable: executable, inherited: env["PATH"])
        process.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { self?.consume(data, from: process) }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.hasPrefix("Reading additional input") { Log.write("codex-stderr", trimmed) }
        }
        process.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                guard let self, self.process === p else { return }
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                self.process = nil
                self.isBusy = false
                Log.write("codex", "exited with status \(p.terminationStatus)")
                if !self.turnEnded {
                    self.onExit?(AgentOutcome(success: false, summary: "codex exited with status \(p.terminationStatus)", costUSD: nil))
                }
            }
        }

        do {
            try process.run()
            self.process = process
            isBusy = true
            Log.write("codex", "started \(arguments.first == "exec" && arguments.dropFirst().first == "resume" ? "resume" : "exec") model=\(model) pid=\(process.processIdentifier)")
        } catch {
            Log.write("codex", "failed to launch \(executable): \(error)")
            onExit?(AgentOutcome(success: false, summary: "Couldn't launch codex", costUSD: nil))
        }
    }

    private func consume(_ data: Data, from source: Process) {
        guard source === process, !data.isEmpty else { return }
        transcript?.write(data)
        buffer.append(data)
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                handle(event: event)
            }
        }
    }

    /// Events: thread.started, turn.started, item.started / item.completed (agent_message,
    /// command_execution, error), turn.completed, turn.failed, error.
    private func handle(event: [String: Any]) {
        switch event["type"] as? String {
        case "thread.started":
            threadID = event["thread_id"] as? String ?? threadID
        case "item.started":
            let item = event["item"] as? [String: Any] ?? [:]
            if item["type"] as? String == "command_execution", let command = item["command"] as? String {
                onStatus?(AgentProtocol.status(forCommand: command))
            }
        case "item.completed":
            let item = event["item"] as? [String: Any] ?? [:]
            if item["type"] as? String == "agent_message", let text = item["text"] as? String {
                AgentProtocol.parse(text: text, onStatus: onStatus, onFile: onFile)
            }
        case "turn.completed":
            turnEnded = true
            isBusy = false
            onTurnFinished?(AgentOutcome(success: true, summary: "done", costUSD: nil))
        case "turn.failed":
            turnEnded = true
            isBusy = false
            let message = ((event["error"] as? [String: Any])?["message"] as? String) ?? "turn failed"
            Log.write("codex", "turn failed: \(message.prefix(300))")
            onTurnFinished?(AgentOutcome(success: false, summary: Self.readableError(message), costUSD: nil))
        default:
            break
        }
    }

    /// Codex nests the API error as JSON inside the message; pull out the human part.
    private static func readableError(_ message: String) -> String {
        if let data = message.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let inner = (json["error"] as? [String: Any])?["message"] as? String {
            return inner
        }
        return message
    }
}

extension CodexRunner {
    /// Models offered to this account, from Codex's own cache (~/.codex/models_cache.json).
    static var availableModels: [String] {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/models_cache.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return ["gpt-5.6-luna", "gpt-5.6-terra"] }
        let slugs = models.compactMap { $0["slug"] as? String }.filter { $0.hasPrefix("gpt-") && $0 != "gpt-reserve" }
        return slugs.isEmpty ? ["gpt-5.6-luna", "gpt-5.6-terra"] : slugs
    }
}
