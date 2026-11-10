import Foundation

/// Maps tool command prefixes to each agent CLI's permission syntax.
///
/// - Claude Code: `--allowedTools Bash(<prefix>:*)`.
/// - Gemini CLI: `--allowed-tools=run_shell_command(<prefix>)`.
/// - OpenCode: bash permission patterns `"<prefix>": "allow"` and `"<prefix> *": "allow"`.
/// - Codex and Hermes have no per-command allowlist: Codex runs any command inside its read-only
///   sandbox, Hermes inside Likely's write-denying sandbox. Tools reach them through the prompt only.
public enum ToolPermissions {
    /// Defense in depth: only prefixes that pass the validator ever reach an agent's permission syntax,
    /// even if a caller forgot to filter.
    public static func valid(_ prefixes: [String]) -> [String] {
        prefixes.map { $0.trimmingCharacters(in: .whitespaces) }.filter { ToolValidator.problem(with: $0) == nil }
    }

    public static func claude(_ prefixes: [String]) -> [String] {
        valid(prefixes).map { "Bash(\($0):*)" }
    }

    public static func gemini(_ prefixes: [String]) -> [String] {
        valid(prefixes).map { "run_shell_command(\($0))" }
    }

    /// The whole `--allowed-tools=…` argument for Gemini CLI. It's split on commas, which is why no
    /// prefix may contain one.
    public static func geminiAllowedToolsArgument(builtIn: [String], extra: [String]) -> String {
        let entries = merged(builtIn.map { "run_shell_command(\($0))" }, gemini(extra))
        return "--allowed-tools=" + entries.joined(separator: ",")
    }

    /// The bare command and the command with arguments (OpenCode globs match the whole command line).
    public static func openCode(_ prefixes: [String]) -> [(pattern: String, action: String)] {
        valid(prefixes).flatMap { [($0, "allow"), ("\($0) *", "allow")] }
    }

    /// OpenCode's whole OPENCODE_PERMISSION value. The last matching rule wins: deny everything, allow
    /// the file tools and built-in commands, then the user's commands, then the built-in denials (so
    /// those still win over a user prefix).
    public static func openCodePermission(fileTools: [String], bashAllowed: [String], bashDenied: [String],
                                          extra: [String]) -> String {
        let allow = [(pattern: "*", action: "deny")] + bashAllowed.map { (pattern: $0, action: "allow") }
        let builtIn = Set(allow.map(\.pattern))
        let user = openCode(extra).filter { !builtIn.contains($0.pattern) }
        let deny = bashDenied.map { (pattern: $0, action: "deny") }
        // No command allowed at all (every built-in one turned off, no user tools): hide bash entirely.
        let bash: JSONValue = bashAllowed.isEmpty && user.isEmpty
            ? .string("deny") : .raw(orderedJSONObject((allow + user + deny).map { ($0.pattern, .string($0.action)) }))
        return orderedJSONObject((["*"] + fileTools).map { ($0, .string($0 == "*" ? "deny" : "allow")) } + [("bash", bash)])
    }

    /// `items` followed by those `extra` items it doesn't already have, in order.
    public static func merged(_ items: [String], _ extra: [String]) -> [String] {
        var seen = Set(items)
        return items + extra.filter { seen.insert($0).inserted }
    }

    /// A JSON object whose keys keep their order (OpenCode applies the last matching rule, so
    /// order matters and a dictionary won't do). Values are strings or already-encoded JSON.
    public static func orderedJSONObject(_ pairs: [(key: String, value: JSONValue)]) -> String {
        "{" + pairs.map { "\(jsonString($0.key)):\($0.value.encoded)" }.joined(separator: ",") + "}"
    }

    public enum JSONValue {
        case string(String)
        case raw(String)

        var encoded: String {
            switch self {
            case .string(let text): return ToolPermissions.jsonString(text)
            case .raw(let json): return json
            }
        }
    }

    static func jsonString(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes])) ?? Data("[\"\"]".utf8)
        return String(decoding: data, as: UTF8.self).dropFirst().dropLast().description
    }

    /// How each agent applies tool commands, for Settings and the docs.
    public static let agentNotes: [String: String] = [
        "claude": "Claude Code: each command is added to --allowedTools as Bash(<command>:*). With tools on, Claude runs in a sandbox that blocks writes outside its own state.",
        "gemini": "Gemini CLI: each command is added to --allowed-tools as run_shell_command(<command>). With tools on, Gemini runs in a sandbox that blocks writes outside ~/.gemini.",
        "opencode": "OpenCode: each command is allowed in its bash permissions (\"<command>\" and \"<command> *\"), inside Likely's write-blocking sandbox.",
        "codex": "Codex can't limit commands; it relies on its read-only sandbox (no writes, no network). Tools reach it through the prompt.",
        "hermes": "Hermes can't limit commands; it relies on Likely's write-blocking sandbox. Tools reach it through the prompt.",
    ]
}

/// The PATH every agent runner gives its agent, so the Tools tab can check commands the same way.
public enum AgentPath {
    public static func directories(agentExecutable: String?, inherited: String?,
                                   home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> [String] {
        var dirs: [String] = []
        if let agentExecutable { dirs.append((agentExecutable as NSString).deletingLastPathComponent) }   // npm installs need `node` beside them
        dirs += ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        dirs += (inherited ?? "").split(separator: ":").map(String.init)
        return dirs.filter { !$0.isEmpty }
    }

    public static func value(agentExecutable: String?, inherited: String?) -> String {
        directories(agentExecutable: agentExecutable, inherited: inherited).joined(separator: ":")
    }

    /// Shell builtins that tools commonly start with (`cd ~ && …`): found without a file on PATH.
    public static let builtins: Set<String> = ["cd", "pushd", "popd"]

    public enum Resolution: Hashable {
        case builtin
        case found(String)
        case notFound
    }

    /// Where the first word of `command` resolves, like the shell would.
    public static func resolve(_ command: String, in directories: [String],
                               isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> Resolution {
        let word = command.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        guard !word.isEmpty else { return .notFound }
        if builtins.contains(word) { return .builtin }
        if word.contains("/") {
            let path = (word as NSString).expandingTildeInPath
            return isExecutable(path) ? .found(path) : .notFound
        }
        for dir in directories {
            let path = dir + "/" + word
            if isExecutable(path) { return .found(path) }
        }
        return .notFound
    }
}
