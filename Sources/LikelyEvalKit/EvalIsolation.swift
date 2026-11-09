import Darwin
import Foundation

/// Seatbelt rules for an isolated eval run (a case with `searchFolders`, e.g. the fixture suite).
///
/// Deny by default: the whole home folder and /Volumes are unreadable, then only what the run
/// needs is allowed back: the case's search folders, its work folder, the agent CLIs' own config
/// and state (logins, settings, installed runtimes) and the agent's install folder. So a fixture
/// run can't read ~/Likely, ~/Library/Application Support/Likely (personal cases and screenshots),
/// ~/Library/Logs/Likely, documents, or external drives. Spotlight is blocked too: its index would
/// list personal files by name.
public enum EvalIsolation {
    /// Agent CLI config and state under the home folder, plus the toolchains they're commonly
    /// installed with (nvm, bun, volta, …) and the shell startup files that put those on PATH.
    public static let agentStatePaths = [
        ".claude", ".gemini", ".codex", ".hermes", ".opencode",
        ".config", ".local", ".cache", ".npm", ".npm-global", ".nvm", ".bun", ".volta", ".asdf", ".pyenv",
        ".cargo", ".deno", ".node", ".fnm", ".mise", ".rye", ".uv",
        ".zshrc", ".zshenv", ".zprofile", ".bashrc", ".bash_profile", ".profile",
        // Claude Code keeps its sign-in in the login keychain and a cache here.
        "Library/Keychains", "Library/Caches/claude-cli-nodejs",
    ]
    /// Files next to these prefixes (Claude Code's ~/.claude.json and its backups).
    public static let agentStateFilePrefixes = [".claude.json"]

    /// - Parameters:
    ///   - home: the home folder (all of it is denied).
    ///   - allowed: folders the case may read (search folders, work folder).
    ///   - agentExecutable: the agent's path; its install folder is allowed if it's under `home`.
    ///   - extraDenied: other folders to deny (e.g. search folders the user added outside `home`).
    public static func rules(home: String, allowed: [String], agentExecutable: String?, extraDenied: [String] = []) -> String {
        let home = realPath(home)
        // /System/Volumes/Data is the same data volume as /Users, reachable by another path.
        let denied = [home, "/Volumes", "/System/Volumes/Data" + home] + extraDenied.map(realPath)
        var allow = allowed.map(realPath)
        allow += agentStatePaths.map { home + "/" + $0 }
        if let agentExecutable {
            for path in Set([agentExecutable, realPath(agentExecutable)]) where path.hasPrefix(home + "/") {
                let first = path.dropFirst(home.count + 1).split(separator: "/").first.map(String.init) ?? ""
                // A dot folder (~/.nvm, ~/.bun, …) is a toolchain: allow all of it. Otherwise just the folder.
                allow.append(first.hasPrefix(".") ? home + "/" + first : (path as NSString).deletingLastPathComponent)
            }
        }
        let filePrefixes = agentStateFilePrefixes.map { "^" + NSRegularExpression.escapedPattern(for: home + "/" + $0) }
        // Looking up a path stats each folder above it; allow that (names and dates, not contents).
        var ancestors = Set<String>()
        for path in allow where path.hasPrefix(home + "/") {
            var dir = (path as NSString).deletingLastPathComponent
            while dir.count >= home.count {
                ancestors.insert(dir)
                if dir == home { break }
                dir = (dir as NSString).deletingLastPathComponent
            }
        }
        ancestors.insert(home)
        func subpaths(_ list: [String]) -> String { list.map { "(subpath \(quoted($0)))" }.joined(separator: " ") }
        return """
        (deny file-read* \(subpaths(denied)))
        (allow file-read-metadata \(ancestors.sorted().map { "(literal \(quoted($0)))" }.joined(separator: " ")))
        (allow file-read* \(subpaths(allow)) \(filePrefixes.map { "(regex \(quoted($0)))" }.joined(separator: " ")))
        (deny mach-lookup (global-name "com.apple.metadata.mds") (global-name "com.apple.metadata.mds.legacy"))
        """
    }

    static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Seatbelt matches real paths (/private/var, not /var).
    public static func realPath(_ path: String) -> String {
        guard let resolved = Darwin.realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
