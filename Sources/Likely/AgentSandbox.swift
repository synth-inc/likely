import Darwin
import Foundation
import LikelyEvalKit

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
/// - Search history: no reading (or writing) Likely's History folder, nor the file's pre-release
///   location (`historyRules`). Codex isn't wrapped here; CodexRunner denies the same paths in its
///   own sandbox.
/// Verified with a probe: under these rules AX reads of Finder fail (-25204), `screencapture` can't
/// create an image, and AXIsProcessTrusted/CGPreflightScreenCaptureAccess report false.
enum AgentSandbox {
    static let blockedExecutables = [
        "/usr/bin/osascript", "/usr/bin/open", "/bin/launchctl", "/usr/bin/shortcuts", "/usr/bin/automator",
        "/usr/sbin/screencapture", "/usr/bin/screencapture", "/usr/bin/osacompile", "/usr/bin/tccutil",
        "/usr/bin/pbcopy", "/usr/bin/pbpaste",
    ]

    static let privacyRules = """
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
    \(historyRules)
    """

    /// Real paths of what the agents must never read: the whole History folder (history.jsonl and
    /// anything written next to it while saving) and the pre-release history.jsonl one level up.
    static var historyDeniedPaths: (folders: [String], files: [String]) {
        // The parent folder exists once Likely has run; the History folder may not yet.
        let support = realPath(SearchHistoryFile.defaultDirectory.deletingLastPathComponent().path)
        let folder = SearchHistoryFile.defaultDirectory.lastPathComponent
        let legacy = SearchHistoryFile.legacyURL.lastPathComponent
        return ([support + "/" + folder], [support + "/" + legacy])
    }

    static var historyRules: String {
        let denied = historyDeniedPaths
        let filters = denied.folders.map { "(subpath \(quoted($0)))" } + denied.files.map { "(literal \(quoted($0)))" }
        return "(deny file-read* file-write* \(filters.joined(separator: " ")))"
    }

    /// For agents with their own write controls (Claude Code, Gemini CLI): everything allowed except
    /// the privacy-sensitive services above.
    static let privacyOnlyProfile = "(version 1)\n(allow default)\n" + privacyRules

    /// For agents Likely has to confine itself (OpenCode, Hermes):
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
    static func confinedProfile(writable: [String], writableRegexes: [String] = [], execAllowed: [String] = [],
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

    static func quoted(_ path: String) -> String {
        "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Seatbelt matches real paths (/private/var, not /var); Foundation's symlink resolution strips /private.
    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Evals only (`--eval` with isolation): rules appended to every profile, e.g. to keep a fixture
    /// run out of the user's own files. Empty in the app.
    static var extraRules = ""

    /// Wraps a launch in `sandbox-exec` with `profile`: returns the executable and arguments to use.
    static func wrap(executable: String, arguments: [String], profile: String) -> (URL, [String]) {
        (URL(fileURLWithPath: "/usr/bin/sandbox-exec"), ["-p", profile + (extraRules.isEmpty ? "" : "\n" + extraRules), executable] + arguments)
    }

    /// Rules for an isolated eval run: no reading the user's document folders (except `allowed`),
    /// and no Spotlight (its index would list personal files by name).
    static func isolationRules(denied: [String], allowed: [String]) -> String {
        let deny = denied.map { "(subpath \(quoted($0)))" }.joined(separator: " ")
        let allow = allowed.map { "(subpath \(quoted($0)))" }.joined(separator: " ")
        return """
        (deny file-read* \(deny))
        \(allowed.isEmpty ? "" : "(allow file-read* \(allow))")
        (deny mach-lookup (global-name "com.apple.metadata.mds") (global-name "com.apple.metadata.mds.legacy"))
        """
    }
}
