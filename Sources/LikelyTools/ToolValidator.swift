import Foundation

/// Rules for tool commands. The agents run allowlisted commands unattended, and each agent matches an
/// allowlist entry as a prefix of the command line, so an entry must be a plain command (plus fixed
/// arguments) that can't chain, redirect or substitute anything, or smuggle extra entries into an
/// agent's permission syntax (Gemini splits `--allowed-tools` on commas; OpenCode treats `?` and `*`
/// as wildcards).
///
/// These rules catch mistakes; they can't prove a command is read-only. The guarantee is the sandbox:
/// with any tool enabled, every agent runs where it can't write outside its own state (see AgentSandbox).
///
/// The Settings tab, tools.json loading and the "Set up with your coding agent" prompt all read these
/// constants, so the rules a coding agent is told are the rules Likely enforces.
public enum ToolValidator {
    /// The only characters a command prefix may contain: an allowlist, so nothing an agent's permission
    /// parser or the shell treats specially (`, ; | & > < $ ` ( ) * ? [ ] { } \ " '`, newlines, tabs) gets through.
    public static let allowedPunctuation = " ._/~=:+@%-"

    public static func isAllowed(_ character: Character) -> Bool {
        guard character.isASCII else { return false }
        return character.isLetter || character.isNumber || allowedPunctuation.contains(character)
    }

    /// Human-readable description of the allowed characters, for messages and the setup prompt.
    public static var allowedCharactersDescription: String {
        "letters A-Z and a-z, digits, spaces and " + allowedPunctuation.filter { $0 != " " }.map(String.init).joined(separator: " ")
    }

    /// Commands that can delete, move or overwrite files, escalate, reach the network, run arbitrary
    /// code (directly, through a plugin/preprocessor flag, or by wrapping another command) or control
    /// other apps. Rejected as the first word of a command (after any path).
    public static let blockedFirstWords: [String] = [
        "rm", "rmdir", "mv", "cp", "dd", "ln", "tee", "truncate", "shred", "mkdir", "touch", "install", "ditto", "xattr",
        "sudo", "su", "chmod", "chown", "chflags",
        "curl", "wget", "ssh", "scp", "sftp", "ftp", "rsync", "nc", "ncat", "telnet",
        "sh", "bash", "zsh", "fish", "dash", "ksh", "csh", "tcsh",
        "python", "python3", "perl", "ruby", "node", "swift", "osascript", "env", "xargs", "eval", "exec", "nohup", "command",
        "arch", "nice", "time", "timeout", "script", "screen", "tmux", "at", "crontab",
        "find", "awk", "gawk", "sed", "rg", "sort", "file", "git", "make", "npm", "npx", "pip", "brew",
        "tar", "zip", "unzip", "sqlite3", "exiftool", "plutil", "defaults", "security",
        "open", "kill", "killall", "pkill", "launchctl", "pbcopy", "say",
    ]

    /// First words that are always rejected by prefix too (python3.12, perl5.30, …).
    static let blockedFirstWordPrefixes = ["python", "perl", "ruby", "pip"]

    /// The first word of a command, without any directory (`/bin/ls -l` → `ls`).
    public static func firstWord(of command: String) -> String {
        let word = command.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        return (word as NSString).lastPathComponent
    }

    /// Why `command` can't be allowlisted, or nil if it's fine.
    public static func problem(with command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "A command is empty" }
        if let bad = trimmed.first(where: { !isAllowed($0) }) {
            let shown = bad == "\n" ? "a newline" : bad == "\r" ? "a carriage return" : bad == "\t" ? "a tab" : "\"\(bad)\""
            return "\"\(trimmed.prefix(40))\" contains \(shown); only \(allowedCharactersDescription) are allowed"
        }
        let word = firstWord(of: trimmed).lowercased()   // macOS file names are case-insensitive: RM is rm
        if blockedFirstWords.contains(word) || blockedFirstWordPrefixes.contains(where: { word.hasPrefix($0) }) {
            return "\"\(word)\" isn't allowed: it can change files, reach the network or run other programs"
        }
        return nil
    }

    /// Every reason `tool` can't be used. Empty means it's valid.
    public static func problems(for tool: CustomTool) -> [String] {
        var problems: [String] = []
        if tool.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { problems.append("The tool has no name") }
        if tool.commands.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            problems.append("The tool has no commands")
        } else {
            problems += tool.commands.compactMap(problem(with:))
        }
        let unknown = PrivateDataAccess.unknownNeeds(tool.needs)
        if !unknown.isEmpty {
            problems.append("Unknown \"needs\": \(unknown.joined(separator: ", ")) (use \(PrivateDataArea.allCases.map(\.rawValue).joined(separator: ", ")))")
        }
        return problems
    }
}
