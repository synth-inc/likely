import Foundation

/// Maps tool command prefixes to each agent CLI's permission syntax.
///
/// - Claude Code: `--allowedTools Bash(<prefix>:*)`.
/// - Gemini CLI: `--allowed-tools=run_shell_command(<prefix>)`.
/// - OpenCode: bash permission patterns `"<prefix>": "allow"` and `"<prefix> *": "allow"`.
/// - Codex and Hermes have no per-command allowlist: Codex runs any command inside its read-only
///   sandbox, Hermes inside Likely's write-denying sandbox. Tools reach them through the prompt only.
public enum ToolPermissions {
    public static func claude(_ prefixes: [String]) -> [String] {
        prefixes.map { "Bash(\($0):*)" }
    }

    public static func gemini(_ prefixes: [String]) -> [String] {
        prefixes.map { "run_shell_command(\($0))" }
    }

    /// The bare command and the command with arguments (OpenCode globs match the whole command line).
    public static func openCode(_ prefixes: [String]) -> [(pattern: String, action: String)] {
        prefixes.flatMap { [($0, "allow"), ("\($0) *", "allow")] }
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
        "claude": "Claude Code: each command is added to --allowedTools as Bash(<command>:*).",
        "gemini": "Gemini CLI: each command is added to --allowed-tools as run_shell_command(<command>).",
        "opencode": "OpenCode: each command is allowed in its bash permissions (\"<command>\" and \"<command> *\"), inside Likely's write-blocking sandbox.",
        "codex": "Codex has no per-command allowlist: it can run any command, inside its read-only sandbox (no writes, no network). Tools reach it through the prompt.",
        "hermes": "Hermes has no per-command allowlist: it can run any command, inside Likely's write-blocking sandbox. Tools reach it through the prompt.",
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
