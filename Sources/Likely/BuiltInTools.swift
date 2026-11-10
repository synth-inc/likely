import Foundation
import LikelyTools

/// What each agent gets from Likely (Settings → Tools, "Built in"), from AgentBuiltins. Each one can be
/// turned off (BuiltinToolSettings), except Codex's.
enum BuiltInTools {
    struct Entry: Hashable {
        let name: String
        let purpose: String
    }

    static func entries(for agentID: String) -> [Entry] {
        if agentID == "codex" {
            return [Entry(name: "Shell commands", purpose: "Any command, inside Codex's read-only sandbox (no writes, no network)")]
        }
        return AgentBuiltins.names(for: agentID).map { Entry(name: $0, purpose: purpose(of: $0, agentID: agentID)) }
    }

    /// Codex has no per-tool list, so its row is informational only.
    static func isToggleable(agentID: String) -> Bool { !AgentBuiltins.names(for: agentID).isEmpty }

    static func purpose(of name: String, agentID: String) -> String {
        switch name {
        case "mdfind": return "Spotlight search by name and content"
        case "mdls": return "File metadata from Spotlight (dates, type, source)"
        case "ls": return "List folders, newest first"
        case "grep" where agentID == "opencode": return "Search text in files (the grep tool and command)"
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

/// Built-in tools turned off in Settings → Tools, per agent: `disabledBuiltinTools.<agentID>` = [String].
/// Only Likely writes it (agents can't write Likely's preferences: see AgentSandbox).
enum BuiltinToolSettings {
    static func key(for agentID: String) -> String { "disabledBuiltinTools.\(agentID)" }

    /// Only names this agent has (a stale or unknown one is ignored).
    static func disabled(for agentID: String, defaults: UserDefaults = .standard) -> Set<String> {
        let stored = Set(defaults.stringArray(forKey: key(for: agentID)) ?? [])
        return Set(AgentBuiltins.names(for: agentID)).intersection(stored)
    }

    static func setEnabled(_ enabled: Bool, name: String, agentID: String, defaults: UserDefaults = .standard) {
        var off = disabled(for: agentID, defaults: defaults)
        if enabled { off.remove(name) } else { off.insert(name) }
        if off.isEmpty {
            defaults.removeObject(forKey: key(for: agentID))
        } else {
            defaults.set(AgentBuiltins.names(for: agentID).filter(off.contains), forKey: key(for: agentID))
        }
    }

    static func reset(agentID: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(for: agentID))
    }
}
