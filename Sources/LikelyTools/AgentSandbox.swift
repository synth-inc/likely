import Darwin
import Foundation
import LikelyEvalKit
import LikelyStorage

/// Seatbelt (`sandbox-exec`) rules shared by the agent runners.
///
/// Agents are children of Likely, so macOS attributes them to Likely and they inherit its privacy
/// grants. That's intended for Files & Folders (searching Desktop/Documents/Downloads is the whole
/// point, and those grants are what onboarding asks for), but not for Accessibility, Screen Recording
/// or Automation. Disclaiming responsibility (`responsibility_spawnattrs_setdisclaim`) would drop all
/// of Likely's grants at once, folders included, and make macOS prompt for "node"/"opencode" instead,
/// so the agents stay attributed to Likely and these rules cut off the other three instead:
/// - Automation: no Apple Events, and no osascript/open/shortcuts/automator/screencapture/launchctl.
/// - Launching or opening anything outside the sandbox: no LaunchServices (`open`, NSWorkspace and
///   LSOpen all go through it, so no starting an app or a .command file that would run unconfined).
/// - Clipboard: no pasteboard server, so nothing can read or replace what the user copied.
/// - Accessibility: no `com.apple.axserver` (the AX client port; without it every AX call fails).
/// - Screen Recording and synthetic input: no WindowServer, replayd or ScreenCaptureKit services.
/// - No asking TCC directly either.
/// - Likely's own data: no reading or writing ~/Library/Application Support/Likely (search history,
///   test cases and screenshots, eval runs, debug captures, tools.json) or ~/Library/Logs/Likely,
///   except the run's own work folder (`protectionRules`); no renaming the folders above them; no
///   reading other agents' session transcripts (`AgentSessions`). Codex isn't wrapped here;
///   CodexRunner applies the same paths through its permission profile (`codexFilesystem`).
/// Verified with a probe: under these rules AX reads of Finder fail (-25204), `screencapture` can't
/// create an image, and AXIsProcessTrusted/CGPreflightScreenCaptureAccess report false.
public enum AgentSandbox {
    public static let blockedExecutables = [
        "/usr/bin/osascript", "/usr/bin/open", "/bin/launchctl", "/usr/bin/shortcuts", "/usr/bin/automator",
        "/usr/sbin/screencapture", "/usr/bin/screencapture", "/usr/bin/osacompile", "/usr/bin/tccutil",
        "/usr/bin/pbcopy", "/usr/bin/pbpaste",
    ]

    public static let privacyRules = """
    (deny appleevent-send)
    (deny mach-lookup
        (global-name "com.apple.windowserver.active") (global-name "com.apple.windowserver")
        (global-name-prefix "com.apple.replayd") (global-name-prefix "com.apple.screencapture")
        (global-name-prefix "com.apple.ScreenCaptureKit")
        (global-name "com.apple.tccd") (global-name "com.apple.tccd.system")
        (local-name "com.apple.axserver") (global-name "com.apple.axserver")
        (global-name "com.apple.coreservices.launchservicesd") (global-name-prefix "com.apple.lsd.")
        (global-name "com.apple.coreservices.quarantine-resolver") (global-name "com.apple.dock.server")
        (global-name-prefix "com.apple.pasteboard."))
    (deny process-exec \(blockedExecutables.map { "(literal \(quoted($0)))" }.joined(separator: " ")))
    """

    /// Every spelling of Likely's data folders seatbelt might see: the path itself, where it really is
    /// (…/Likely is a link to …/Likely.noindex, see SpotlightExclusion) and the `.noindex` name, so
    /// the rules hold before and after that move.
    public static func dataDeniedPaths(home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> [String] {
        let realHome = realPath(home)
        var paths: [String] = []
        for folder in LikelyDataPaths.all(home: realHome) {
            for path in [folder.path, realPath(folder.path), folder.path + SpotlightExclusion.suffix] where !paths.contains(path) {
                paths.append(path)
            }
        }
        return paths
    }

    /// The folders above Likely's data, whose own entries (not their contents) no agent may rename or
    /// delete: renaming ~/Library/Application Support (or ~/Library, or ~) would move Likely's data to
    /// a path none of the deny rules name, and the agent could then read it there. Every spelling (the
    /// home folder as given and resolved), plus Likely's folders and their `.noindex` targets.
    public static func dataAncestorPaths(home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> [String] {
        var paths: [String] = []
        for base in [home, realPath(home)] {
            for relative in ["", "/Library", "/Library/Application Support", "/Library/Logs"] where !paths.contains(base + relative) {
                paths.append(base + relative)
            }
        }
        for path in dataDeniedPaths(home: home) where !paths.contains(path) { paths.append(path) }
        return paths
    }

    /// Codex's equivalent of the data rules: a `permissions.<profile>.filesystem` table (TOML) where
    /// Likely's folders and every agent's session transcripts (`AgentSessions`, Codex's own included:
    /// Codex reads its sessions itself, outside the sandbox) are "none" and the run's work folder is
    /// "read" (the more specific path wins; verified with `codex sandbox`, codex-cli 0.153).
    /// Private data areas the user hasn't opened (`blockedAreas`, see PrivateDataArea) are "none" too.
    /// Codex's read-only profile allows no writes at all, so renaming a folder above Likely's data
    /// (`dataAncestorPaths`) is already impossible there.
    public static func codexFilesystem(home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                                       readable: [String],
                                       blockedAreas: [PrivateDataArea] = PrivateDataAccess.blocked(),
                                       denied extra: [String] = []) -> String {
        var denied: [String] = []
        for path in dataDeniedPaths(home: home) + AgentSessions.deniedPaths(home: home, except: nil)
            + PrivateDataAccess.codexPaths(blocked: blockedAreas, home: home) + extra
        where !denied.contains(path) { denied.append(path) }
        let entries = denied.map { "\(tomlString($0)) = \"none\"" }
            + readable.map { "\(tomlString(realPath($0))) = \"read\"" }
        return "{ " + entries.joined(separator: ", ") + " }"
    }

    static func tomlString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// For agents with their own write controls (Claude Code, Gemini CLI) while no user tools are
    /// enabled: everything allowed except the privacy-sensitive services above.
    public static let privacyOnlyProfile = "(version 1)\n(allow default)\n" + privacyRules

    /// For agents Likely has to confine itself (OpenCode, Hermes, and Claude Code / Gemini CLI once the
    /// user has enabled tools, whose commands Likely can't prove read-only):
    /// - writes only to `writable` (plus the usual /dev nodes);
    /// - nothing can be executed from a writable location (no planting a binary or copying a system
    ///   tool to /tmp and running it), except `execAllowed` folders, which are also made read-only;
    /// - outbound network only to HTTPS (port 443). Seatbelt can't filter by host name, so limiting
    ///   traffic to the model API's domain isn't possible here; port 443 is the tightest rule that
    ///   still works with every hosted provider.
    /// - Unix sockets only for DNS (mDNSResponder) and under `unixSockets` (so no Docker socket, no
    ///   ssh-agent, no other local daemons).
    /// - localhost only with `allowLocalhost` (Hermes: its client talks to its own gateway over a
    ///   loopback WebSocket on a random port, so the port can't be pinned).
    public static func confinedProfile(writable: [String], writableRegexes: [String] = [], execAllowed: [String] = [],
                                unixSockets: [String] = [], unixSocketRegexes: [String] = [],
                                allowLocalhost: Bool = false) -> String {
        let writableRules = writable.map { "(subpath \(quoted($0)))" } + writableRegexes.map { "(regex \(quoted($0)))" }
        let socketRules = unixSockets.map { "(subpath \(quoted($0)))" } + unixSocketRegexes.map { "(regex \(quoted($0)))" }
        let noExec = writable + ["/private/tmp", "/private/var/tmp", "/private/var/folders"]
        var profile = """
        (version 1)
        (allow default)
        (deny file-write*)
        (allow file-write* (literal "/dev/null") (literal "/dev/tty") (literal "/dev/dtracehelper") (literal "/dev/ptmx")
            (regex #"^/dev/(fd/|ttys)") \(writableRules.joined(separator: " ")))
        (deny process-exec \(noExec.map { "(subpath \(quoted($0)))" }.joined(separator: " ")))
        (deny network-outbound)
        (allow network-outbound (remote tcp "*:443") \(allowLocalhost ? "(remote ip \"localhost:*\") " : "")\
        (literal "/private/var/run/mDNSResponder") \(socketRules.joined(separator: " ")))
        \(allowLocalhost ? "" : "(deny network-outbound (remote ip \"localhost:*\"))")

        """
        if !execAllowed.isEmpty {
            let paths = execAllowed.map { "(subpath \(quoted($0)))" }.joined(separator: " ")
            profile += "(deny file-write* \(paths))\n(allow process-exec \(paths))\n"
        }
        return profile + privacyRules
    }

    public static func quoted(_ path: String) -> String {
        "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Seatbelt matches real paths (/private/var, not /var); Foundation's symlink resolution strips /private.
    public static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Wraps a launch in `sandbox-exec` with `profile`: returns the executable and arguments to use.
    /// `extraRules` (evals only, see EvalIsolation) come after the profile, so they win over it.
    /// Every profile ends with `protectionRules`, so no agent can read Likely's data (other than
    /// `readable`, the run's work folder) or change Likely's data or settings, and none can read the
    /// private data areas the user hasn't opened (`blockedAreas`, see PrivateDataArea).
    /// `agent`: whose session transcripts stay readable (the agent's own; see AgentSessions).
    public static func wrap(executable: String, arguments: [String], profile: String, extraRules: String = "",
                            readable: [String] = [], blockedAreas: [PrivateDataArea] = PrivateDataAccess.blocked(),
                            agent: AgentSessions? = nil) -> (URL, [String]) {
        (URL(fileURLWithPath: "/usr/bin/sandbox-exec"),
         ["-p", compose(profile: profile, extraRules: extraRules, readable: readable, blockedAreas: blockedAreas, agent: agent),
          executable] + arguments)
    }

    /// The full profile `wrap` passes to sandbox-exec.
    public static func compose(profile: String, extraRules: String = "", readable: [String] = [],
                               blockedAreas: [PrivateDataArea], agent: AgentSessions? = nil,
                               home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        let privateData = PrivateDataAccess.sandboxRules(blocked: blockedAreas, home: home)
        return profile + (extraRules.isEmpty ? "" : "\n" + extraRules)
            + (privateData.isEmpty ? "" : "\n" + privateData)
            + "\n" + protectionRules(home: home, readable: readable, agent: agent)
    }

    // MARK: Likely's own files

    public static let bundleID = "inc.synth.likely"

    /// Likely's data, last in the profile so no earlier allow can override it:
    /// - No reading or writing ~/Library/Application Support/Likely (search history, test cases and
    ///   their screenshots, eval runs and reports, debug captures, tools.json, the manifest) or
    ///   ~/Library/Logs/Likely.
    /// - Except reading `readable`: the run's work folder (…/Likely/run for searches, the case's own
    ///   folder for evals), which holds what the agent is meant to see: the screenshot sent with this
    ///   search (`context-<id>.png`), OpenCode's config dir, Gemini's settings file, Hermes's
    ///   launchctl stub. Not its transcripts (`*.jsonl`).
    /// - No writes there at all, nor to Likely's preferences, neither as a file nor through cfprefsd
    ///   (`defaults write`).
    /// - No renaming or deleting the folders above it (`dataAncestorPaths`: ~, ~/Library, …/Application
    ///   Support, ~/Library/Logs) or Likely's folders and links themselves. `literal` rules: they
    ///   match those entries only, so files can still be created inside ~ and the others.
    /// - No reading other agents' session transcripts (`AgentSessions`: past queries, and the
    ///   screenshots attached to them). `agent`'s own stay readable: it needs them to run.
    ///
    /// tools.json needs no exception: the agents get the user's tools in their prompt, and only the
    /// user's own coding agent (not run by Likely) edits the file.
    public static func protectionRules(home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                                       bundleID: String = bundleID, readable: [String] = [],
                                       agent: AgentSessions? = nil) -> String {
        let realHome = realPath(home)
        let data = dataDeniedPaths(home: home).map { "(subpath \(quoted($0)))" }.joined(separator: " ")
        let ancestors = dataAncestorPaths(home: home).map { "(literal \(quoted($0)))" }.joined(separator: " ")
        let sessions = AgentSessions.deniedPaths(home: home, except: agent).map { "(subpath \(quoted($0)))" }.joined(separator: " ")
        let prefs = "^" + NSRegularExpression.escapedPattern(for: realHome + "/Library/Preferences/")
            + "(ByHost/)?" + NSRegularExpression.escapedPattern(for: bundleID) + #"(\..*)?\.plist"#
        var rules = "(deny file-read* file-write* \(data))\n"
        // …/Likely is a link to …/Likely.noindex: following it to the work folder needs the link's
        // metadata (not a listing of the folder).
        let roots = LikelyDataPaths.all(home: realHome).map { "(literal \(quoted($0.path)))" }.joined(separator: " ")
        let allowed = readable.map(realPath)
        if !allowed.isEmpty {
            rules += "(allow file-read-metadata \(roots))\n"
            rules += "(allow file-read* \(allowed.map { "(subpath \(quoted($0)))" }.joined(separator: " ")))\n"
            let transcripts = allowed.map { "(regex \(quoted("^" + NSRegularExpression.escapedPattern(for: $0) + #"/.*\.jsonl$"#)))" }
            rules += "(deny file-read* \(transcripts.joined(separator: " ")))\n"
        }
        return rules + """
        (deny file-read* \(sessions))
        (deny file-write* \(data) \(ancestors) (regex \(quoted(prefs))))
        (deny user-preference-write (preference-domain \(quoted(bundleID))))
        """
    }

    // MARK: Claude Code and Gemini CLI with user tools

    /// The per-user temp/cache folder (/private/var/folders/…/T → its parent, holding T and C).
    public static var userTempFolder: String {
        (realPath(FileManager.default.temporaryDirectory.path) as NSString).deletingLastPathComponent
    }

    /// Claude Code once the user has enabled tools: writes only to its own state (~/.claude,
    /// ~/.claude.json and its backups/locks, its caches) and temp folders; HTTPS only.
    public static func claudeProfile(home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                                     tempFolder: String = userTempFolder) -> String {
        let realHome = realPath(home)
        return confinedProfile(
            writable: [realHome + "/.claude", realHome + "/Library/Caches/claude-cli-nodejs", realHome + "/.cache/claude",
                       realHome + "/.local/state/claude", tempFolder, "/private/tmp"],
            writableRegexes: ["^" + NSRegularExpression.escapedPattern(for: realHome + "/.claude.json")])
    }

    /// Gemini CLI once the user has enabled tools: writes only to ~/.gemini (sessions, ids) and temp
    /// folders; HTTPS only.
    public static func geminiProfile(home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                                     tempFolder: String = userTempFolder) -> String {
        let realHome = realPath(home)
        return confinedProfile(writable: [realHome + "/.gemini", tempFolder, "/private/tmp"])
    }
}

/// Where each agent CLI keeps its session transcripts: every query Likely sent it and, for most, the
/// screenshot attached to it (base64), in plaintext. Likely turns persistence off where the CLI can
/// (Claude Code's `--no-session-persistence`) and otherwise deletes the run's session when the picker
/// closes (the runners). These rules keep agents out of each other's stores meanwhile (and out of
/// the user's own sessions with those CLIs). An agent's own store stays readable to it under
/// sandbox-exec: the CLI reads it in-process (resume, its own state), and it can't be told apart
/// from the agent's tools. Codex reads its sessions outside its sandbox, so all of them, its own
/// included, are denied to its commands.
public enum AgentSessions: String, CaseIterable {
    case claude, codex, gemini, opencode, hermes

    /// Paths under `home` (not resolved: callers spell them both ways if needed).
    public func paths(home: String) -> [String] {
        switch self {
        // Transcripts per working folder, and the prompt history.
        case .claude: return [home + "/.claude/projects", home + "/.claude/history.jsonl"]
        // Rollout files, the prompt history and index, logs, and the SQLite stores (thread titles and
        // state, logs), whose names carry a version number: found by listing ~/.codex.
        case .codex:
            let root = home + "/.codex"
            let databases = ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [])
                .filter { $0.contains(".sqlite") }.sorted().map { root + "/" + $0 }
            return ["sessions", "archived_sessions", "history.jsonl", "session_index.jsonl", "log", "sqlite"].map { root + "/" + $0 }
                + databases
        // Chats and logs.json per project, and shell history per project.
        case .gemini: return [home + "/.gemini/tmp", home + "/.gemini/history"]
        // Sessions, messages and their attachments live in opencode.db and storage/ (older versions);
        // the folder also holds OpenCode's credentials.
        case .opencode: return [home + "/.local/share/opencode"]
        // Likely's own Hermes profile: its session database and logs.
        case .hermes: return [home + "/.hermes/profiles/likely"]
        }
    }

    /// Every agent's session paths but `except`'s, under both spellings of `home`.
    public static func deniedPaths(home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                                   except agent: AgentSessions?) -> [String] {
        var paths: [String] = []
        let homes = home == AgentSandbox.realPath(home) ? [home] : [home, AgentSandbox.realPath(home)]
        for kind in allCases where kind != agent {
            for base in homes {
                for path in kind.paths(home: base) where !paths.contains(path) { paths.append(path) }
            }
        }
        return paths
    }
}
