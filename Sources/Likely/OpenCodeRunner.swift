import Foundation
import LikelyTools

/// Runs OpenCode: `opencode run --format json`, with the screenshot attached via `-f`. OpenCode has
/// no sandbox of its own and its bash allowlist only sees command names (`ls > file` passes as `ls`),
/// so it runs under `sandbox-exec` (see AgentSandbox: no writes outside its own data directories, no
/// exec from writable places, HTTPS only, no local sockets, LaunchServices, pasteboard, Accessibility, Screen Recording or Automation), plus a permission config that hides edit tools and allowlists search commands.
/// Like Codex it can't take messages mid-turn: feedback stops the current turn and continues the same
/// session with `opencode run -s <session>`.
final class OpenCodeRunner: AgentRunner {
    var onStatus: ((String) -> Void)?
    var onFile: ((String) -> Void)?
    var onTurnFinished: ((AgentOutcome) -> Void)?
    var onExit: ((AgentOutcome) -> Void)?
    var launchOptions = AgentLaunchOptions()

    private(set) var isBusy = false
    private var process: Process?
    private var buffer = Data()
    private var sessionID: String?
    private var executable: String?
    private var model = ""
    private var workDir: URL?
    private var turnEnded = false
    private var transcript: FileHandle?

    /// Zen's free models need no sign-in; this one is fast, follows the protocol and sees images.
    static let defaultModel = "opencode/deepseek-v4.1-flash-free"

    /// Last matching rule wins, so order matters (hence a literal rather than a dictionary). `*` denies
    /// everything not listed (edit/write/patch, webfetch, task, question, …), which also removes those
    /// tools from the model's view. Shell writes are stopped by the sandbox; the bash list keeps the agent
    /// on search commands, and find's -exec/-ok could otherwise run anything.
    /// The user's tools (see ToolStore) are allowed after the built-in commands and before the `find`
    /// denials, so those still win.
    static let fileTools = ["read", "glob", "grep", "list", "external_directory"]
    static let bashAllowed = ["ls", "ls *", "mdfind *", "mdls *", "find *", "grep *", "head *", "tail *", "stat *", "wc *", "echo *"]

    static let bashDenied = ["find *-exec*", "find *-ok*", "find *-delete*", "find *-fprint*", "find *-fls*"]

    /// OpenCode reads (and on first run creates) <config>/opencode/opencode.jsonc. Likely writes it before
    /// every launch and the sandbox keeps it read-only (it's under Likely's protected folder), so nothing
    /// the agent runs can plant a config for the next run.
    private static func resetConfig(_ configHome: String) {
        let dir = URL(fileURLWithPath: configHome).appendingPathComponent("opencode")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let files = ["opencode.jsonc": #"{"$schema": "https://opencode.ai/config.json"}"#,
                     ".gitignore": "node_modules\npackage.json\npackage-lock.json\nbun.lock\n.gitignore\n"]
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where files[name] == nil {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
        for (name, text) in files { try? Data(text.utf8).write(to: dir.appendingPathComponent(name)) }
    }

    static func permission(extra commands: [String]) -> String {
        ToolPermissions.openCodePermission(fileTools: fileTools, bashAllowed: bashAllowed, bashDenied: bashDenied, extra: commands)
    }

    func start(executable: String, model: String, prompt: String, image: URL?, workDir: URL) {
        cancel()
        sessionID = nil
        self.executable = executable
        self.model = model
        self.workDir = workDir
        let transcriptURL = workDir.appendingPathComponent("last-run.jsonl")
        transcript = AgentTranscript.open(transcriptURL, append: launchOptions.appendTranscript)

        var arguments = ["run", "--format", "json", "-m", model]
        if let image { arguments += ["-f", image.path] }
        launch(arguments + ["--", prompt])   // `--`: -f takes several values, and text may start with "-"
    }

    @discardableResult
    func send(_ text: String) -> Bool {
        guard let sessionID, executable != nil else { return false }
        // No mid-turn input: stop the current turn (the session so far is kept) and continue it.
        stopProcess()
        launch(["run", "--format", "json", "-m", model, "-s", sessionID, "--", text])
        return true
    }

    func cancel() {
        stopProcess()
        sessionID = nil
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
            Log.write("opencode", "stopped pid=\(process.processIdentifier)")
        }
    }

    private func launch(_ arguments: [String]) {
        guard let executable, let workDir else { return }
        buffer = Data()
        turnEnded = false

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var env = ProcessInfo.processInfo.environment
        // Our own (empty) config dir instead of ~/.config/opencode: no MCP servers or plugins from the
        // user's config. Credentials live in the data dir (~/.local/share/opencode) and still apply.
        let configHome = workDir.appendingPathComponent("opencode-config").path
        env["XDG_CONFIG_HOME"] = configHome
        Self.resetConfig(configHome)
        env["OPENCODE_PERMISSION"] = Self.permission(extra: ToolStore.shared.activeCommands)
        for flag in ["OPENCODE_PURE", "OPENCODE_DISABLE_PROJECT_CONFIG", "OPENCODE_DISABLE_CLAUDE_CODE",
                     "OPENCODE_DISABLE_EXTERNAL_SKILLS", "OPENCODE_DISABLE_AUTOUPDATE", "OPENCODE_DISABLE_LSP_DOWNLOAD"] {
            env[flag] = "1"
        }
        env["PATH"] = AgentPath.value(agentExecutable: executable, inherited: env["PATH"])

        let dataDir = env["XDG_DATA_HOME"].map { $0 + "/opencode" } ?? home + "/.local/share/opencode"
        let writable = [
            dataDir,
            env["XDG_STATE_HOME"].map { $0 + "/opencode" } ?? home + "/.local/state/opencode",
            env["XDG_CACHE_HOME"].map { $0 + "/opencode" } ?? home + "/.cache/opencode",
            "/private/var/folders",   // $TMPDIR
        ]

        let process = Process()
        // OpenCode keeps tools it downloads (ripgrep) in <data>/bin: runnable, but not writable inside the sandbox.
        let profile = AgentSandbox.confinedProfile(writable: writable, execAllowed: [dataDir + "/bin"])
        let (launcher, launchArguments) = AgentSandbox.wrap(executable: executable, arguments: arguments, profile: profile, extraRules: launchOptions.extraSandboxRules)
        process.executableURL = launcher
        process.arguments = launchArguments
        process.currentDirectoryURL = workDir
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
            Log.write("opencode-stderr", text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        process.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                guard let self, self.process === p else { return }
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                self.process = nil
                self.isBusy = false
                Log.write("opencode", "exited with status \(p.terminationStatus)")
                guard !self.turnEnded else { return }
                // There's no turn-completed event: a clean exit after the last step is the end of the turn.
                if p.terminationStatus == 0 {
                    self.turnEnded = true
                    self.onTurnFinished?(AgentOutcome(success: true, summary: "done", costUSD: nil))
                } else {
                    self.onExit?(AgentOutcome(success: false, summary: "opencode exited with status \(p.terminationStatus)", costUSD: nil))
                }
            }
        }

        do {
            try process.run()
            self.process = process
            isBusy = true
            Log.write("opencode", "started \(arguments.contains("-s") ? "resume" : "run") model=\(model) pid=\(process.processIdentifier)")
        } catch {
            Log.write("opencode", "failed to launch \(executable): \(error)")
            onExit?(AgentOutcome(success: false, summary: "Couldn't launch opencode", costUSD: nil))
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

    /// Events (all carry `sessionID`; data is in `part`): step_start, text, tool_use (emitted once the
    /// call has completed or errored), step_finish (reason "tool-calls" or "stop"), error.
    private func handle(event: [String: Any]) {
        if let id = event["sessionID"] as? String { sessionID = id }
        let part = event["part"] as? [String: Any] ?? [:]
        switch event["type"] as? String {
        case "text":
            AgentProtocol.parse(text: part["text"] as? String ?? "", onStatus: onStatus, onFile: onFile)
        case "tool_use":
            let input = (part["state"] as? [String: Any])?["input"] as? [String: Any] ?? [:]
            if let status = Self.status(forTool: part["tool"] as? String ?? "", input: input) {
                onStatus?(status)
            }
        case "error":
            turnEnded = true
            isBusy = false
            let error = event["error"] as? [String: Any] ?? [:]
            let message = ((error["data"] as? [String: Any])?["message"] as? String) ?? error["name"] as? String ?? "opencode failed"
            Log.write("opencode", "error: \(message.prefix(300))")
            onTurnFinished?(AgentOutcome(success: false, summary: message, costUSD: nil))
        default:
            break
        }
    }

    /// Fallback progress text derived from the tool OpenCode called, for when it doesn't narrate.
    static func status(forTool name: String, input: [String: Any]) -> String? {
        switch name {
        case "bash":
            if let description = input["description"] as? String, !description.isEmpty { return description }
            return AgentProtocol.status(forCommand: input["command"] as? String ?? "")
        case "read":
            return (input["filePath"] as? String).map { "Reading \(($0 as NSString).lastPathComponent)" }
        case "grep":
            return (input["pattern"] as? String).map { "Searching file contents for \($0.prefix(40))" }
        case "glob":
            return (input["pattern"] as? String).map { "Looking for \($0.prefix(40))" }
        case "list":
            return "Looking through recent files"
        default:
            return nil
        }
    }
}

extension OpenCodeRunner {
    /// OpenCode Zen's free models that take images, from OpenCode's models.dev cache
    /// (~/.cache/opencode/models.json). Other providers work too if the user has signed in to them.
    static var availableModels: [String] {
        let fallback = [defaultModel, "opencode/glm-5.3-flash-free", "opencode/mimo-v2.6-flash-free", "opencode/nemotron-3.5-super-vl-free"]
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/opencode/models.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = (json["opencode"] as? [String: Any])?["models"] as? [String: [String: Any]] else { return fallback }
        let free = models.filter { id, model in
            let cost = (model["cost"] as? [String: Any])?["input"] as? Double
            let input = (model["modalities"] as? [String: Any])?["input"] as? [String] ?? []
            // Deprecated/preview models have a status; "alpha" stealth models come and go within days.
            return cost == 0 && model["status"] == nil && input.contains("image") && model["tool_call"] as? Bool == true
                && !id.contains("alpha")
        }.keys.map { "opencode/\($0)" }.sorted()
        guard !free.isEmpty else { return fallback }
        return free.contains(defaultModel) ? [defaultModel] + free.filter { $0 != defaultModel } : free
    }
}
