import Darwin
import Foundation

/// Runs Nous Research's Hermes Agent: `hermes chat -q … --format stream-json` in its own `likely`
/// profile, inside a Seatbelt sandbox that denies file writes outside Hermes' own state.
///
/// Hermes has no read-only mode (its approvals only catch "dangerous" commands; `echo > file` runs),
/// so the sandbox is the safety boundary. Every `hermes chat` is a client of a per-profile gateway
/// daemon that actually runs the agent and its tools, so the daemon must start inside the sandbox too:
/// - the `likely` profile is `gateway.standalone`, so the user's own gateway never serves it;
/// - a stub `launchctl` on PATH makes Hermes start the daemon as a plain child (which inherits the
///   sandbox) instead of as a launchd job (which wouldn't), and the real launchctl/osascript/open are
///   denied so nothing can hand work to launchd;
/// - a daemon for the profile that isn't sandboxed (the user ran `hermes -p likely` by hand) is stopped.
///
/// The screenshot is viewed with the `vision_analyze` tool (`--image` isn't supported by the gateway
/// client). Feedback continues the same named session with `-c`; a turn in flight can't be stopped
/// from the CLI, so the gateway finishes it (read-only) and then answers the feedback.
final class HermesRunner: AgentRunner {
    var onStatus: ((String) -> Void)?
    var onFile: ((String) -> Void)?
    var onTurnFinished: ((AgentOutcome) -> Void)?
    var onExit: ((AgentOutcome) -> Void)?

    private(set) var isBusy = false
    private var process: Process?
    private var buffer = Data()
    /// Assistant text arrives as token deltas; complete lines are parsed as they finish.
    private var pendingText = ""
    private var textSinceTool = false
    private var sessionName: String?
    private var executable: String?
    private var model = ""
    private var workDir: URL?
    private var turnEnded = false
    private var transcript: FileHandle?
    /// Bumped by `cancel()`, so a launch prepared in the background is dropped if it's stale.
    private var generation = 0

    static let profileName = "likely"
    static var profileDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes/profiles/\(profileName)")
    }

    /// `--source tool` keeps these sessions out of the user's session lists; `--ignore-rules` skips
    /// SOUL.md/AGENTS.md/memory. terminal = shell (mdfind etc.), file = read_file/search_files,
    /// vision = vision_analyze for the screenshot. Writes from any of them are stopped by the sandbox.
    private static let baseArguments = ["chat", "--format", "stream-json", "--source", "tool", "--ignore-rules",
                                        "-t", "terminal,file,vision"]

    func start(executable: String, model: String, prompt: String, image: URL?, workDir: URL) {
        cancel()
        self.executable = executable
        self.model = model
        self.workDir = workDir
        sessionName = "likely-\(UUID().uuidString.prefix(8).lowercased())"
        let transcriptURL = workDir.appendingPathComponent("last-run.jsonl")
        FileManager.default.createFile(atPath: transcriptURL.path, contents: nil)
        transcript = try? FileHandle(forWritingTo: transcriptURL)

        var prompt = prompt
        if let image { prompt += "\n\nThe screenshot is at \(image.path)." }
        prompt += "\nTo look at an image, use vision_analyze (read_file only reads text)."
        prepareThenLaunch(prompt)
    }

    @discardableResult
    func send(_ text: String) -> Bool {
        guard sessionName != nil, executable != nil else { return false }
        // No mid-turn input: detach from the current turn and queue the feedback in the same session.
        stopProcess()
        prepareThenLaunch(text)
        return true
    }

    func cancel() {
        generation += 1
        stopProcess()
        sessionName = nil
        try? transcript?.close()
        transcript = nil
    }

    private func stopProcess() {
        isBusy = false
        guard let process else { return }
        self.process = nil
        (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (process.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            // SIGINT detaches the client at once; the gateway finishes the (read-only) turn by itself.
            process.interrupt()
            Log.write("hermes", "stopped pid=\(process.processIdentifier)")
        }
    }

    /// Profile/gateway checks run a few `hermes` commands on first use, so they happen off the main thread.
    private func prepareThenLaunch(_ query: String) {
        guard let executable, let workDir, let sessionName else { return }
        isBusy = true
        let generation = self.generation
        DispatchQueue.global(qos: .userInitiated).async {
            let problem = Self.prepare(executable: executable, workDir: workDir)
            DispatchQueue.main.async {
                guard generation == self.generation else { return }
                if let problem {
                    Log.write("hermes", "not started: \(problem)")
                    self.isBusy = false
                    self.onExit?(AgentOutcome(success: false, summary: problem, costUSD: nil))
                    return
                }
                self.launch(["-q", query, "-c", sessionName, "--create-if-missing"] + (self.model.isEmpty ? [] : ["-m", self.model]))
            }
        }
    }

    private func launch(_ arguments: [String]) {
        guard let executable, let workDir else { return }
        buffer = Data()
        pendingText = ""
        textSinceTool = false
        turnEnded = false

        let process = Process()
        let (launcher, launchArguments) = AgentSandbox.wrap(executable: executable, arguments: Self.baseArguments + arguments,
                                                             profile: Self.sandboxProfile)
        process.executableURL = launcher
        process.arguments = launchArguments
        process.currentDirectoryURL = workDir
        process.environment = Self.environment(executable: executable, workDir: workDir)

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
            if !trimmed.isEmpty { Log.write("hermes-stderr", trimmed) }
        }
        process.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                guard let self, self.process === p else { return }
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                self.process = nil
                self.isBusy = false
                Log.write("hermes", "exited with status \(p.terminationStatus)")
                if !self.turnEnded {
                    self.onExit?(AgentOutcome(success: false, summary: "hermes exited with status \(p.terminationStatus)", costUSD: nil))
                }
            }
        }

        do {
            try process.run()
            self.process = process
            isBusy = true
            Log.write("hermes", "started session=\(sessionName ?? "?") model=\(model) pid=\(process.processIdentifier)")
        } catch {
            isBusy = false
            Log.write("hermes", "failed to launch \(executable): \(error)")
            onExit?(AgentOutcome(success: false, summary: "Couldn't launch hermes", costUSD: nil))
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

    /// Events (undocumented, from real output): system/init, text (token deltas), tool_use
    /// {name, input}, tool_result, and a final result {session_id, exit_code, text, error?, tokens}.
    private func handle(event: [String: Any]) {
        switch event["type"] as? String {
        case "text":
            pendingText += event["text"] as? String ?? ""
            // The stream sometimes drops the newline between two protocol lines ("….mp4FILE: /…").
            pendingText = pendingText.replacingOccurrences(of: #"(?<=\S)(FILE:|STATUS:)"#, with: "\n$1", options: .regularExpression)
            textSinceTool = true
            if let lastNewline = pendingText.lastIndex(where: \.isNewline) {
                AgentProtocol.parse(text: String(pendingText[...lastNewline]), onStatus: onStatus, onFile: reportFile)
                pendingText = String(pendingText[pendingText.index(after: lastNewline)...])
            }
        case "tool_use":
            flushText()
            textSinceTool = false
            if let status = Self.status(forTool: event["name"] as? String ?? "", input: event["input"] as? [String: Any] ?? [:]) {
                onStatus?(status)
            }
        case "result":
            flushText()
            // `text` repeats the last message; parse it only if it wasn't streamed.
            if !textSinceTool { AgentProtocol.parse(text: event["text"] as? String ?? "", onStatus: onStatus, onFile: reportFile) }
            turnEnded = true
            isBusy = false
            let exitCode = event["exit_code"] as? Int ?? 1
            if exitCode == 0 {
                onTurnFinished?(AgentOutcome(success: true, summary: "done", costUSD: nil))
            } else {
                let message = (event["error"] as? String) ?? (event["text"] as? String) ?? "hermes failed"
                Log.write("hermes", "turn failed (\(exitCode)): \(message.prefix(300))")
                onTurnFinished?(AgentOutcome(success: false, summary: Self.readableError(message), costUSD: nil))
            }
        default:
            break
        }
    }

    /// The stream sometimes runs a FILE line into the next sentence ("….jpegBest match is …"):
    /// fall back to the longest prefix of the path that is an existing file.
    private func reportFile(_ path: String) {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: path) { onFile?(path); return }
        var prefix = path
        while prefix.count > 1 {
            prefix.removeLast()
            if fm.fileExists(atPath: prefix, isDirectory: &isDirectory) {
                if !isDirectory.boolValue { onFile?(prefix) }
                return
            }
        }
        onFile?(path)
    }

    private func flushText() {
        guard !pendingText.isEmpty else { return }
        AgentProtocol.parse(text: pendingText, onStatus: onStatus, onFile: reportFile)
        pendingText = ""
    }

    private static func readableError(_ message: String) -> String {
        if message.contains("ProviderNotConfigured") || message.contains("No LLM provider") {
            return "Hermes has no model provider set up for Likely. In Terminal, run: hermes -p \(profileName) model"
        }
        let line = message.split(whereSeparator: \.isNewline).first.map(String.init) ?? message
        return String(line.prefix(200))
    }

    /// Fallback progress text derived from the tool Hermes is calling, for when it doesn't narrate.
    static func status(forTool name: String, input: [String: Any]) -> String? {
        switch name {
        case "terminal":
            return AgentProtocol.status(forCommand: input["command"] as? String ?? "")
        case "read_file":
            return (input["path"] as? String).map { "Reading \(($0 as NSString).lastPathComponent)" }
        case "search_files":
            return "Searching files"
        case "vision_analyze":
            return "Looking at the context"
        default:
            return nil
        }
    }
}

// MARK: - Sandbox and profile

extension HermesRunner {
    /// Reads are allowed; writes only to the profile's own state, the per-user temp and cache folders,
    /// and the lock/lease files Hermes takes in its shared install. Writes to the install itself are
    /// denied, so nothing can plant code the user's own (unsandboxed) Hermes would run. Nothing can be
    /// executed from those writable places, network is HTTPS plus localhost (its gateway) only, Unix
    /// sockets only the gateway's own, and Apple Events, LaunchServices, the pasteboard,
    /// Accessibility and Screen Recording are cut off (see AgentSandbox).
    ///
    /// The stub `launchctl` (see `prepare`) only steers Hermes into starting its gateway as a child;
    /// it isn't the safety boundary. The real /bin/launchctl, open and osascript are denied by path,
    /// a copy of them can't be run from anywhere writable, and Apple Events are denied outright.
    static var sandboxProfile: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        // /private/var/folders/…/T → its parent holds T (temp) and C (caches).
        let userFolder = (AgentSandbox.realPath(FileManager.default.temporaryDirectory.path) as NSString).deletingLastPathComponent
        let root = NSRegularExpression.escapedPattern(for: AgentSandbox.realPath(home.appendingPathComponent(".hermes").path))
        // The gateway's control socket: <profile>/gateway.sock, or hermes-gw-<hash>/control.sock in a
        // temp folder when that path is too long for a Unix socket.
        let gatewaySocketDirs = [userFolder + "/T", "/private/tmp"].map {
            "^" + NSRegularExpression.escapedPattern(for: $0) + "/hermes-gw-[0-9a-f]+/"
        }
        return AgentSandbox.confinedProfile(
            writable: [AgentSandbox.realPath(profileDir.path), userFolder],
            writableRegexes: ["^" + root + #"/installs/[^/]+/(.*\.lock|.*/\.leases(/.*)?)$"#],
            unixSockets: [AgentSandbox.realPath(profileDir.path)],
            unixSocketRegexes: gatewaySocketDirs,
            allowLocalhost: true)
    }

    /// The gateway daemon keeps the environment of the client that started it.
    private static func environment(executable: String, workDir: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in env.keys where key.hasPrefix("HERMES_") { env.removeValue(forKey: key) }
        env["HERMES_HOME"] = profileDir.path
        let dir = (executable as NSString).deletingLastPathComponent
        env["PATH"] = [stubDir(workDir).path, dir, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin", env["PATH"] ?? ""]
            .joined(separator: ":")
        return env
    }

    private static func stubDir(_ workDir: URL) -> URL { workDir.appendingPathComponent("hermes-bin") }

    /// Sets up the profile and stub, and makes sure no unsandboxed gateway would serve it.
    /// Returns a message for the user if Hermes can't run safely. Runs off the main thread.
    private static func prepare(executable: String, workDir: URL) -> String? {
        let fm = FileManager.default
        // `launchctl print` answers "not found" (113) so Hermes looks no further; anything else fails,
        // which makes it start the gateway as a plain child process.
        let stub = stubDir(workDir).appendingPathComponent("launchctl")
        if !fm.isExecutableFile(atPath: stub.path) {
            try? fm.createDirectory(at: stubDir(workDir), withIntermediateDirectories: true)
            try? "#!/bin/sh\n[ \"$1\" = print ] && exit 113\nexit 1\n".write(to: stub, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        }

        let config = profileDir.appendingPathComponent("config.yaml")
        if !fm.fileExists(atPath: config.path) {
            // Clone the user's config and API keys (.env); OAuth logins aren't copied.
            run(executable, ["profile", "create", profileName, "--clone", "--no-alias"])
        }
        if !((try? String(contentsOf: config, encoding: .utf8))?.contains("standalone: true") ?? false) {
            run(executable, ["-p", profileName, "config", "set", "gateway.standalone", "true"])
        }
        guard fm.fileExists(atPath: config.path) else { return "Couldn't create the Hermes profile \"\(profileName)\"" }

        // A gateway for the profile that isn't sandboxed would run tools with full write access.
        if let pid = gatewayPID(profileDir), kill(pid, 0) == 0, !isSandboxed(pid) {
            Log.write("hermes", "stopping unsandboxed gateway pid=\(pid)")
            run(executable, ["-p", profileName, "gateway", "stop"])
            if kill(pid, 0) == 0 { return "An unsandboxed Hermes gateway is serving the \(profileName) profile; run: hermes -p \(profileName) gateway stop" }
        }
        let rootState = fm.homeDirectoryForCurrentUser.appendingPathComponent(".hermes/gateway_state.json")
        if let data = try? Data(contentsOf: rootState),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           (json["served_profiles"] as? [String])?.contains(profileName) == true {
            return "Your Hermes gateway is serving the \(profileName) profile; restart it with: hermes gateway restart"
        }
        return nil
    }

    /// At quit: stop the sandboxed gateway Likely started for the `likely` profile (an unsandboxed one
    /// belongs to the user and is left alone). SIGTERM, so it shuts down like `hermes gateway stop`.
    static func stopGateway() {
        guard let pid = gatewayPID(profileDir), pid > 1, kill(pid, 0) == 0, isSandboxed(pid) else { return }
        kill(pid, SIGTERM)
        Log.write("hermes", "stopped gateway pid=\(pid)")
    }

    private static func gatewayPID(_ home: URL) -> pid_t? {
        guard let data = try? Data(contentsOf: home.appendingPathComponent("gateway.pid")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = json["pid"] as? Int else { return nil }
        return pid_t(pid)
    }

    private static func isSandboxed(_ pid: pid_t) -> Bool {
        typealias SandboxCheck = @convention(c) (pid_t, UnsafePointer<CChar>?, Int32) -> Int32
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "sandbox_check") else { return false }
        return unsafeBitCast(symbol, to: SandboxCheck.self)(pid, nil, 0) > 0
    }

    @discardableResult
    private static func run(_ executable: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        for key in env.keys where key.hasPrefix("HERMES_") { env.removeValue(forKey: key) }
        env["PATH"] = [(executable as NSString).deletingLastPathComponent, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":")
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        Log.write("hermes", "\(arguments.prefix(4).joined(separator: " ")) → \(process.terminationStatus)")
        return process.terminationStatus
    }
}

extension HermesRunner {
    /// Model IDs as Nous Portal and OpenRouter both name them (fast, tool-using and vision-capable).
    /// Other providers set up with `hermes -p likely model` may name models differently.
    static let defaultModel = "anthropic/claude-haiku-5.5"
    static var availableModels: [String] {
        [defaultModel, "google/gemini-3.8-flash", "anthropic/claude-sonnet-5.5", "openai/gpt-6-luna", "x-ai/grok-4.7",
         "deepseek/deepseek-v4.1-flash", "qwen/qwen3.8-flash"]
    }
}
