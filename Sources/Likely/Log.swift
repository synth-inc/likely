import Foundation
import LikelyStorage
import os

/// So every file can write log lines (and build parts of them) without importing LikelyStorage.
typealias LogMessage = LikelyStorage.LogMessage

/// Appends timestamped lines to ~/Library/Logs/Likely/likely.log and stderr (dev builds: also the
/// unified log, message private; see `mirrorToUnifiedLog`).
///
/// Lines are `LogMessage`s: private values (queries, window titles, paths, agent text) are marked at the
/// call site and written as short hashes unless "Log details for troubleshooting" is on, or in dev
/// builds. See LogPrivacy.swift and docs/PRIVACY.md.
enum Log {
    static let fileURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Likely", isDirectory: true)
        try? OwnerOnly.createDirectory(dir)   // 0700; the file is 0600 (see `write`)
        let url = dir.appendingPathComponent("likely.log")
        #if !LIKELY_DEV
        // Versions before redaction wrote queries, titles and paths in plaintext: start over, once.
        if LogFile.discardLegacyContent(at: url) { discardedLegacyContent = true }
        #endif
        return url
    }()

    /// This launch emptied the log older versions wrote (logged once the file is set up).
    private static var discardedLegacyContent = false

    /// "Log details for troubleshooting" (Settings → General). Dev builds always log details.
    static let details: LogDetailsSwitch = {
        #if LIKELY_DEV
        return LogDetailsSwitch(alwaysOn: true)
        #else
        return LogDetailsSwitch()
        #endif
    }()

    private static let queue = DispatchQueue(label: "inc.synth.likely.log")
    #if LIKELY_DEV
    private static let logger = Logger(subsystem: "inc.synth.likely", category: "app")
    #endif
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// The eval runner turns this off so its own output stays readable (`--verbose` turns it back on).
    static var echoToStderr = true

    /// `category` is a literal; `message` marks its private values (see LogMessage).
    static func write(_ category: StaticString, _ message: LogMessage) {
        let text = message.rendered(details: details.showsDetails)
        let cat = "\(category)"
        let line = "\(formatter.string(from: Date())) [\(cat)] \(text)\n"
        mirrorToUnifiedLog(category: cat, text: text)
        let data = Data(line.utf8)
        if echoToStderr { FileHandle.standardError.write(data) }
        let url = fileURL
        queue.async {
            // Created owner-only (0600); appends go to the end.
            if let handle = try? OwnerOnly.openForWriting(url, truncate: false) {
                handle.write(data)
                try? handle.close()
            }
        }
        if discardedLegacyContent {
            discardedLegacyContent = false
            write("privacy", "removed the log older versions wrote (it had searches, window titles and paths)")
        }
    }

    /// The unified log is readable by anything running as the user (`log show`), agents included, so
    /// it's outside the protection of ~/Library/Logs/Likely. Release builds don't write to it at all;
    /// dev builds (Console.app while developing) mark the message private, so `log show` prints
    /// `<private>` unless private data logging is turned on for the subsystem.
    private static func mirrorToUnifiedLog(category: String, text: String) {
        #if LIKELY_DEV
        logger.info("[\(category, privacy: .public)] \(text, privacy: .private)")
        #endif
    }

    /// Settings → General → Clear Log.
    static func clear() {
        let url = fileURL
        queue.sync { LogFile.clear(at: url) }
    }
}
