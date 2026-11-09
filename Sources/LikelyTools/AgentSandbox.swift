import Darwin
import Foundation

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
    /// Every profile ends with `protectionRules`, so no agent can change Likely's own data or settings.
    public static func wrap(executable: String, arguments: [String], profile: String) -> (URL, [String]) {
        (URL(fileURLWithPath: "/usr/bin/sandbox-exec"), ["-p", profile + "\n" + protectionRules(), executable] + arguments)
    }

    // MARK: Likely's own files

    public static let bundleID = "inc.synth.likely"

    /// No writes to ~/Library/Application Support/Likely (tools.json, the agents' working folder, which
    /// holds config some agents read on the next run) or Likely's preferences, neither as a file nor
    /// through cfprefsd (`defaults write`). Last in the profile, so no earlier allow can override it.
    public static func protectionRules(home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                                       bundleID: String = bundleID) -> String {
        let realHome = realPath(home)
        let support = realHome + "/Library/Application Support/Likely"
        let prefs = "^" + NSRegularExpression.escapedPattern(for: realHome + "/Library/Preferences/")
            + "(ByHost/)?" + NSRegularExpression.escapedPattern(for: bundleID) + #"(\..*)?\.plist"#
        return """
        (deny file-write* (subpath \(quoted(support))) (regex \(quoted(prefs))))
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
