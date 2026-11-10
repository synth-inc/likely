import Foundation

/// What each agent may always use, read from the runners' own constants (Settings → Tools, "Built in").
enum BuiltInTools {
    struct Entry: Hashable {
        let name: String
        let purpose: String
    }

    static func entries(for agentID: String) -> [Entry] {
        let (fileTools, commands): ([String], [String])
        switch agentID {
        case "gemini":
            (fileTools, commands) = (GeminiRunner.coreTools.filter { $0 != "run_shell_command" }, GeminiRunner.allowedCommands)
        case "opencode":
            (fileTools, commands) = (OpenCodeRunner.fileTools.filter { $0 != "external_directory" },
                                     OpenCodeRunner.bashAllowed.map { $0.hasSuffix(" *") ? String($0.dropLast(2)) : $0 })
        case "hermes":
            (fileTools, commands) = (HermesRunner.toolsets, [])
        case "codex":
            return [Entry(name: "Shell commands", purpose: "Any command, inside Codex's read-only sandbox (no writes, no network)")]
        default:
            let tools = ClaudeRunner.allowedTools
            (fileTools, commands) = (tools.filter { !$0.hasPrefix("Bash(") },
                                     tools.compactMap { $0.dropPrefix("Bash(")?.replacingOccurrences(of: ":*)", with: "") })
        }
        var seen = Set<String>()
        return (commands + fileTools).filter { seen.insert($0).inserted }.map { Entry(name: $0, purpose: purpose(of: $0, agentID: agentID)) }
    }

    static func purpose(of name: String, agentID: String) -> String {
        switch name {
        case "mdfind": return "Spotlight search by name and content"
        case "mdls": return "File metadata from Spotlight (dates, type, source)"
        case "ls": return "List folders, newest first"
        case "grep": return "Search text in files or output"
        case "head": return "First lines of a file or output"
        case "tail": return "Last lines of a file or output"
        case "stat": return "File size and dates"
        case "wc": return "Count lines and words"
        case "echo": return "Print text"
        case "find": return "Find files by name (no -exec or -delete)"
        case "Read", "read", "read_file": return "Read a file (or look at an image)"
        case "Glob", "glob": return "Find files by name pattern"
        case "Grep": return "Search file contents"
        case "list", "list_directory": return "List a folder"
        case "terminal": return agentID == "hermes" ? "Shell commands, inside Likely's write-blocking sandbox" : "Shell commands"
        case "file": return "Read and search files"
        case "vision": return "Look at images"
        default: return ""
        }
    }
}
