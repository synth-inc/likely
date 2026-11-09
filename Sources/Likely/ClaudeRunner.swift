import Foundation
import LikelyTools

/// Runs `claude -p` headless with read-only tools and parses its stream-json output into
/// status updates and candidate file paths. Claude never writes anything; the app does the copying.
///
/// Input is stream-json too, so the process stays alive while the picker is open and `send(_:)` can
/// add user feedback at any time: mid-turn messages are picked up after Claude's current step,
/// later ones start a new turn with the whole conversation (screenshot, earlier searches) in context.
final class ClaudeRunner: AgentRunner {
    typealias Outcome = AgentOutcome

    var onStatus: ((String) -> Void)?
    var onFile: ((String) -> Void)?
    /// After each turn (the first answer, and each answer to feedback).
    var onTurnFinished: ((Outcome) -> Void)?
    /// The process ended without being cancelled (crash, auth failure, …).
    var onExit: ((Outcome) -> Void)?
    var launchOptions = AgentLaunchOptions()

    /// Search commands that can't write: `sort` (-o) and `file` (-C) can, so they're left out, like
    /// `find` (-delete/-exec/-fprint) and `tee`.
    static let allowedTools = [
        "Read", "Glob", "Grep",
        "Bash(ls:*)", "Bash(mdfind:*)", "Bash(mdls:*)", "Bash(head:*)", "Bash(stat:*)", "Bash(grep:*)",
    ]

    /// The built-in tools plus `Bash(<prefix>:*)` for each command of the user's tools (see ToolStore).
    static func allowedTools(extra commands: [String]) -> [String] {
        ToolPermissions.merged(allowedTools, ToolPermissions.claude(commands))
    }

    private var process: Process?
    private var buffer = Data()
    private var input: FileHandle?
    private var transcript: FileHandle?

    var isAlive: Bool { process?.isRunning ?? false }
    /// True between sending a message and its result.
    private(set) var isBusy = false

    /// Claude Code reads the screenshot itself (its path is in the prompt), so `image` is unused.
    func start(executable: String, model: String, prompt: String, image: URL?, workDir: URL) {
        start(claudePath: executable, model: model, prompt: prompt, workDir: workDir)
    }

    func start(claudePath: String, model: String, prompt: String, workDir: URL) {
        cancel()
        buffer = Data()
        let userCommands = launchOptions.toolCommands

        let process = Process()
        process.currentDirectoryURL = workDir
        let arguments = [
            "-p",
            "--input-format", "stream-json",
            "--model", model,
            "--output-format", "stream-json", "--verbose",
            // Skip the user's settings (hooks etc.) and MCP servers: faster startup, no side effects.
            "--setting-sources", "local",
            "--strict-mcp-config",
            // No transcript in ~/.claude/projects (the queries and the screenshot, in plaintext, where
            // later agents could read them). Follow-ups go to this same process, so nothing needs resuming.
            "--no-session-persistence",
            "--tools", "Read,Glob,Grep,Bash",
            "--permission-mode", "dontAsk",
            "--add-dir", FileManager.default.homeDirectoryForCurrentUser.path,
        ] + SearchFolder.outsideHome.flatMap { ["--add-dir", $0] } + [
            "--allowedTools",
        ] + Self.allowedTools(extra: userCommands)
        // No Accessibility, Screen Recording or Apple Events through Likely's grants (see AgentSandbox).
        // With user tools enabled, also no writes outside Claude's own state: the validator can't prove
        // a tool read-only, the sandbox can.
        let profile = userCommands.isEmpty ? AgentSandbox.privacyOnlyProfile : AgentSandbox.claudeProfile()
        let (launcher, launchArguments) = AgentSandbox.wrap(executable: claudePath, arguments: arguments,
                                                             profile: profile, extraRules: launchOptions.extraSandboxRules,
                                                             readable: [workDir.path], agent: .claude)
        process.executableURL = launcher
        process.arguments = launchArguments

        var env = ProcessInfo.processInfo.environment
        // Use the claude.ai login rather than whatever API key a parent shell exported.
        env.removeValue(forKey: "ANTHROPIC_API_KEY")
        if !userCommands.isEmpty { env["DISABLE_AUTOUPDATER"] = "1" }   // its install folder isn't writable then
        env["PATH"] = AgentPath.value(agentExecutable: claudePath, inherited: env["PATH"])
        process.environment = env

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let transcriptURL = AgentTranscript.url(workDir: workDir, options: launchOptions)
        transcript = AgentTranscript.open(transcriptURL, append: launchOptions.appendTranscript)

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { self?.consume(data, from: process) }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            Log.write("claude-stderr", "\(trimmed.count) chars: \(sensitive: trimmed)")
        }
        process.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                guard let self, self.process === p else { return }
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                self.process = nil
                self.input = nil
                self.isBusy = false
                Log.write("claude", "exited with status \(p.terminationStatus)")
                self.onExit?(Outcome(success: p.terminationStatus == 0, summary: "claude exited with status \(p.terminationStatus)", costUSD: nil))
            }
        }

        do {
            try process.run()
            self.process = process
            input = stdin.fileHandleForWriting
            Log.write("claude", "started \(path: claudePath) model=\(meta: model) pid=\(process.processIdentifier)")
            send(prompt)
        } catch {
            Log.write("claude", "failed to launch \(path: claudePath): \(error: error)")
            onExit?(Outcome(success: false, summary: "Couldn't launch claude", costUSD: nil))
        }
    }

    /// Sends a user message to the running session. Returns false if there's no live process.
    @discardableResult
    func send(_ text: String) -> Bool {
        guard isAlive, let input else { return false }
        let message: [String: Any] = ["type": "user", "message": ["role": "user", "content": [["type": "text", "text": text]]]]
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return false }
        data.append(UInt8(ascii: "\n"))
        do {
            try input.write(contentsOf: data)
        } catch {
            Log.write("claude", "send failed: \(error: error)")
            return false
        }
        isBusy = true
        return true
    }

    func cancel() {
        guard let process else { return }
        self.process = nil
        isBusy = false
        try? input?.close()
        input = nil
        (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (process.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
            Log.write("claude", "cancelled pid=\(process.processIdentifier)")
        }
        try? transcript?.close()
        transcript = nil
    }

    private func consume(_ data: Data, from source: Process) {
        guard source === process, !data.isEmpty else { return }
        transcript?.write(data)
        buffer.append(data)
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                handle(event: object)
            }
        }
    }

    private func handle(event: [String: Any]) {
        switch event["type"] as? String {
        case "assistant":
            let content = (event["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for block in content {
                switch block["type"] as? String {
                case "text":
                    parse(text: block["text"] as? String ?? "")
                case "tool_use":
                    if let status = Self.status(forTool: block["name"] as? String ?? "", input: block["input"] as? [String: Any] ?? [:]) {
                        onStatus?(status)
                    }
                default:
                    break
                }
            }
        case "result":
            let isError = event["is_error"] as? Bool ?? false
            let result = event["result"] as? String ?? ""
            Log.write("claude", "result is_error=\(isError) kind=\(isError ? AgentFailureKind.classify(result) : nil) subtype=\(ClaudeResultSubtype(event["subtype"] as? String)) turns=\(event["num_turns"] as? Int) cost=\(event["total_cost_usd"] as? Double) result=\(sensitive: result.prefix(300))")
            isBusy = false
            onTurnFinished?(Outcome(success: !isError, summary: isError ? result : "done", costUSD: event["total_cost_usd"] as? Double))
        default:
            break
        }
    }

    private func parse(text: String) {
        AgentProtocol.parse(text: text, onStatus: onStatus, onFile: onFile)
    }

    /// Fallback progress text derived from the tool Claude is calling, for when it doesn't narrate.
    static func status(forTool name: String, input: [String: Any]) -> String? {
        switch name {
        case "Bash":
            if let description = input["description"] as? String, !description.isEmpty { return description }
            return AgentProtocol.status(forCommand: input["command"] as? String ?? "")
        case "Read":
            guard let path = input["file_path"] as? String else { return nil }
            return path.hasSuffix(".png") && path.contains("Likely/run") ? "Looking at the context" : "Reading \((path as NSString).lastPathComponent)"
        case "Grep":
            return (input["pattern"] as? String).map { "Searching file contents for \($0.prefix(40))" }
        case "Glob":
            return (input["pattern"] as? String).map { "Looking for \($0.prefix(40))" }
        default:
            return nil
        }
    }
}

/// Claude Code's `result` subtypes, a fixed vocabulary; anything else logs as "other".
enum ClaudeResultSubtype: String, LogSafeEnum {
    case success, error_max_turns, error_during_execution, error_max_budget_usd, other, none

    init(_ raw: String?) {
        self = raw.map { ClaudeResultSubtype(rawValue: $0) ?? .other } ?? .none
    }
}
