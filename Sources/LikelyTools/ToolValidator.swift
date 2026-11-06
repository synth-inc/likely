import Foundation

/// Rules for tool commands. The agents run allowlisted commands unattended, and each agent matches an
/// allowlist entry as a prefix of the command line, so an entry must be a plain command (plus fixed
/// arguments) that can't chain, redirect or substitute anything.
///
/// The Settings tab, tools.json loading and the "Set up with your coding agent" prompt all read these
/// constants, so the rules a coding agent is told are the rules Likely enforces.
public enum ToolValidator {
    /// Characters that would let a prefix chain commands, redirect output, substitute commands or
    /// variables, or break an agent's permission syntax (`Bash(…:*)`, `run_shell_command(…)`, globs).
    public static let forbiddenCharacters: [Character] = [";", "|", "&", ">", "<", "$", "`", "(", ")", "*", "\\", "\"", "'", "\n", "\r", "\t"]

    /// Human-readable list of `forbiddenCharacters` for messages and the setup prompt.
    public static var forbiddenCharactersDescription: String {
        let names: [Character: String] = ["\n": "newlines", "\r": "carriage returns", "\t": "tabs"]
        let printable = forbiddenCharacters.filter { names[$0] == nil }.map(String.init).joined(separator: " ")
        let control = forbiddenCharacters.compactMap { names[$0] }
        return control.isEmpty ? printable : printable + ", and no " + control.joined(separator: ", ")
    }

    /// Commands that can delete, move or overwrite files, escalate, reach the network, run arbitrary
    /// code or control other apps. Rejected as the first word of a command (after any path).
    public static let blockedFirstWords: [String] = [
        "rm", "rmdir", "mv", "cp", "dd", "ln", "tee", "truncate", "shred",
        "sudo", "su", "chmod", "chown", "chflags",
        "curl", "wget", "ssh", "scp", "rsync",
        "sh", "bash", "zsh", "fish", "dash", "ksh", "csh", "tcsh",
        "python", "python3", "perl", "ruby", "node", "osascript", "env", "xargs", "eval", "exec", "nohup", "command",
        "open", "kill", "killall", "pkill", "launchctl",
    ]

    /// First words that are always rejected by prefix too (python3.12, perl5.30, …).
    static let blockedFirstWordPrefixes = ["python", "perl", "ruby"]

    /// The first word of a command, without any directory (`/bin/ls -l` → `ls`).
    public static func firstWord(of command: String) -> String {
        let word = command.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        return (word as NSString).lastPathComponent
    }

    /// Why `command` can't be allowlisted, or nil if it's fine.
    public static func problem(with command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "A command is empty" }
        if let bad = trimmed.first(where: forbiddenCharacters.contains) {
            let shown = bad == "\n" ? "a newline" : bad == "\r" ? "a carriage return" : bad == "\t" ? "a tab" : "\"\(bad)\""
            return "\"\(trimmed.prefix(40))\" contains \(shown); shell operators and quotes aren't allowed"
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
        return problems
    }
}
