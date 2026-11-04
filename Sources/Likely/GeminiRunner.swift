import Foundation

/// Runs Google's Gemini CLI: `gemini -p … -o stream-json`, authenticated through Vertex AI with the
/// user's gcloud application-default credentials (project/location passed as env vars, nothing written
/// to ~/.gemini). The screenshot is attached by prefixing the prompt with `@/path/to/image.png`.
///
/// Read-only: headless Gemini runs in the default approval mode, where anything that would need
/// confirmation is denied (write_file/replace aren't even registered, save_memory and web_fetch are
/// refused). Shell commands only run if every segment of a pipeline starts with an allowlisted
/// command; redirections, `;` chains and `$(…)` are refused. `find` (-delete/-exec), `sort` (-o) and
/// `file` (-C) can write, so they're left out; mdfind and Gemini's list_directory cover them.
///
/// Gemini can't take messages mid-turn, so feedback stops the current turn and continues the same
/// conversation with `--resume <session_id>` (sessions are stored per working directory).
final class GeminiRunner: AgentRunner {
    var onStatus: ((String) -> Void)?
    var onFile: ((String) -> Void)?
    var onTurnFinished: ((AgentOutcome) -> Void)?
    var onExit: ((AgentOutcome) -> Void)?

    static let allowedCommands = ["mdfind", "mdls", "ls", "grep", "head", "stat"]

    /// Only read_file, list_directory and the shell are registered: glob/search_file_content and the
    /// codebase_investigator subagent crawl the whole home workspace and can stall for minutes;
    /// memory, web, skills and hooks aren't wanted. Write tools aren't available headless anyway.
    private static let settings = Data("""
        {"tools": {"core": ["read_file", "list_directory", "run_shell_command"], "enableHooks": false, "sandbox": false},
         "hooksConfig": {"enabled": false}, "skills": {"enabled": false},
         "agents": {"overrides": {"codebase_investigator": {"enabled": false}, "cli_help": {"enabled": false},
                                  "generalist": {"enabled": false}}}}
        """.utf8)

    private(set) var isBusy = false
    private var process: Process?
    private var buffer = Data()
    /// Assistant text arrives in deltas; complete lines are parsed as they arrive.
    private var pendingText = ""
    private var sessionID: String?
    private var executable: String?
    private var model = ""
    private var workDir: URL?
    private var turnEnded = false
    private var transcript: FileHandle?

    func start(executable: String, model: String, prompt: String, image: URL?, workDir: URL) {
        cancel()
        sessionID = nil
        self.executable = executable
        self.model = model
        self.workDir = workDir
        let transcriptURL = workDir.appendingPathComponent("last-run.jsonl")
        FileManager.default.createFile(atPath: transcriptURL.path, contents: nil)
        transcript = try? FileHandle(forWritingTo: transcriptURL)

        // `@path` attaches the file as model input; it must be inside the workspace (see baseArguments).
        let fullPrompt = image.map { "@\($0.path)\n\n\(prompt)" } ?? prompt
        launch(baseArguments(imageDirectory: image?.deletingLastPathComponent()) + ["-p", fullPrompt])
    }

    @discardableResult
    func send(_ text: String) -> Bool {
        guard let sessionID, executable != nil else { return false }
        // No mid-turn input: stop the current turn (the conversation so far is kept) and resume.
        stopProcess()
        launch(baseArguments(imageDirectory: nil) + ["--resume", sessionID, "-p", text])
        return true
    }

    func cancel() {
        stopProcess()
        sessionID = nil
        try? transcript?.close()
        transcript = nil
    }

    /// `-e none` skips the user's extensions. The workspace (where read_file/glob may look) is the
    /// working directory plus home, the search folders outside it, and the screenshot's folder.
    private func baseArguments(imageDirectory: URL?) -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let directories = [home] + SearchFolder.outsideHome + (imageDirectory.map { [$0.path] } ?? [])
        return [
            "-m", model,
            "-o", "stream-json",
            "-e", "none",
            "--approval-mode", "default",
            "--include-directories", directories.joined(separator: ","),
            // `=` form: the flag takes an array and would otherwise swallow the following arguments.
            "--allowed-tools=" + Self.allowedCommands.map { "run_shell_command(\($0))" }.joined(separator: ","),
        ]
    }

    private func stopProcess() {
        guard let process else { return }
        self.process = nil
        isBusy = false
        (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (process.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
            Log.write("gemini", "stopped pid=\(process.processIdentifier)")
        }
    }

    private func launch(_ arguments: [String]) {
        guard let executable, let workDir else { return }
        buffer = Data()
        pendingText = ""
        turnEnded = false

        let process = Process()
        // No Accessibility, Screen Recording or Apple Events through Likely's grants (see AgentSandbox).
        let (launcher, launchArguments) = AgentSandbox.wrap(executable: executable, arguments: arguments,
                                                             profile: AgentSandbox.privacyOnlyProfile)
        process.executableURL = launcher
        process.arguments = launchArguments
        process.currentDirectoryURL = workDir
        process.standardInput = FileHandle.nullDevice   // -p appends stdin; don't let it wait on ours
        var env = ProcessInfo.processInfo.environment
        let dir = (executable as NSString).deletingLastPathComponent   // npm installs need `node` beside them
        env["PATH"] = [dir, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin", env["PATH"] ?? ""]
            .joined(separator: ":")
        // Vertex AI with gcloud application-default credentials, rather than any API key in the environment.
        env.removeValue(forKey: "GEMINI_API_KEY")
        env.removeValue(forKey: "GOOGLE_API_KEY")
        env["GOOGLE_GENAI_USE_VERTEXAI"] = "true"
        // Gemini's own sandbox would try sandbox-exec inside ours, which macOS doesn't allow.
        env["GEMINI_SANDBOX"] = "false"
        if let project = Self.vertexProject { env["GOOGLE_CLOUD_PROJECT"] = project }
        env["GOOGLE_CLOUD_LOCATION"] = Self.vertexLocation
        // Our own settings layer (overrides ~/.gemini/settings.json without touching it).
        let settingsURL = workDir.appendingPathComponent("gemini-settings.json")
        try? Self.settings.write(to: settingsURL)
        env["GEMINI_CLI_SYSTEM_SETTINGS_PATH"] = settingsURL.path
        process.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
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
            if !trimmed.hasPrefix("Hook registry initialized") { Log.write("gemini-stderr", String(trimmed.prefix(500))) }
        }
        process.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                guard let self, self.process === p else { return }
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                self.process = nil
                self.isBusy = false
                Log.write("gemini", "exited with status \(p.terminationStatus)")
                if !self.turnEnded {
                    self.onExit?(AgentOutcome(success: false, summary: "gemini exited with status \(p.terminationStatus)", costUSD: nil))
                }
            }
        }

        do {
            try process.run()
            self.process = process
            isBusy = true
            Log.write("gemini", "started \(arguments.contains("--resume") ? "resume" : "new") model=\(model) project=\(Self.vertexProject ?? "-") location=\(Self.vertexLocation) pid=\(process.processIdentifier)")
        } catch {
            Log.write("gemini", "failed to launch \(executable): \(error)")
            onExit?(AgentOutcome(success: false, summary: "Couldn't launch gemini", costUSD: nil))
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

    /// Events: init (session_id), message (role user/assistant; assistant text as deltas),
    /// tool_use (tool_name, parameters), tool_result, result (status success/error).
    private func handle(event: [String: Any]) {
        switch event["type"] as? String {
        case "init":
            sessionID = event["session_id"] as? String ?? sessionID
        case "message":
            guard event["role"] as? String == "assistant", let content = event["content"] as? String else { return }
            pendingText += content
            if let lastNewline = pendingText.lastIndex(where: \.isNewline) {
                let complete = String(pendingText[...lastNewline])
                pendingText = String(pendingText[pendingText.index(after: lastNewline)...])
                AgentProtocol.parse(text: complete, onStatus: onStatus, onFile: onFile)
            }
        case "tool_use":
            flushText()
            if let status = Self.status(forTool: event["tool_name"] as? String ?? "", parameters: event["parameters"] as? [String: Any] ?? [:]) {
                onStatus?(status)
            }
        case "result":
            flushText()
            turnEnded = true
            isBusy = false
            if event["status"] as? String == "success" {
                onTurnFinished?(AgentOutcome(success: true, summary: "done", costUSD: nil))
            } else {
                let message = ((event["error"] as? [String: Any])?["message"] as? String) ?? "turn failed"
                Log.write("gemini", "turn failed: \(message.prefix(500))")
                onTurnFinished?(AgentOutcome(success: false, summary: Self.readableError(message), costUSD: nil))
            }
        default:
            break
        }
    }

    private func flushText() {
        guard !pendingText.isEmpty else { return }
        AgentProtocol.parse(text: pendingText, onStatus: onStatus, onFile: onFile)
        pendingText = ""
    }

    /// Fallback progress text derived from the tool Gemini is calling, for when it doesn't narrate.
    static func status(forTool name: String, parameters: [String: Any]) -> String? {
        switch name {
        case "run_shell_command":
            return AgentProtocol.status(forCommand: parameters["command"] as? String ?? "")
        case "read_file":
            guard let path = parameters["file_path"] as? String else { return nil }
            return "Reading \((path as NSString).lastPathComponent)"
        case "list_directory":
            return "Looking through recent files"
        default:
            return nil
        }
    }

    /// Errors look like `[API Error: {"error":{"message":"{\n \"error\": {… \"message\": \"…\"`;
    /// unwrap the nested JSON down to the innermost message.
    static func readableError(_ message: String) -> String {
        var text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if let inner = text.dropPrefix("[API Error:") {
            text = inner.hasSuffix("]") ? String(inner.dropLast()) : inner
        }
        while let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let inner = (json["error"] as? [String: Any])?["message"] as? String {
            text = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(text.prefix(300))
    }
}

extension GeminiRunner {
    /// Gemini 3 previews are only served from the `global` Vertex location; 2.5 models work there too.
    static let defaultModel = "gemini-3-flash-preview"
    static var availableModels: [String] {
        ["gemini-3-flash-preview", "gemini-3.1-pro-preview", "gemini-2.5-flash", "gemini-2.5-flash-lite", "gemini-2.5-pro"]
    }

    /// Vertex project: Settings, else GOOGLE_CLOUD_PROJECT from the environment.
    static var vertexProject: String? {
        let saved = UserDefaults.standard.string(forKey: "geminiVertexProject")?.trimmingCharacters(in: .whitespaces) ?? ""
        if !saved.isEmpty { return saved }
        let env = ProcessInfo.processInfo.environment["GOOGLE_CLOUD_PROJECT"] ?? ""
        return env.isEmpty ? nil : env
    }

    /// Vertex location: Settings, else GOOGLE_CLOUD_LOCATION, else `global`.
    static var vertexLocation: String {
        let saved = UserDefaults.standard.string(forKey: "geminiVertexLocation")?.trimmingCharacters(in: .whitespaces) ?? ""
        if !saved.isEmpty { return saved }
        let env = ProcessInfo.processInfo.environment["GOOGLE_CLOUD_LOCATION"] ?? ""
        return env.isEmpty ? "global" : env
    }
}
