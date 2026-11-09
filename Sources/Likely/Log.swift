import Foundation
import LikelyStorage
import os

/// So every file can write log lines (and build parts of them) without importing LikelyStorage.
typealias LogMessage = LikelyStorage.LogMessage
typealias LogSafeEnum = LikelyStorage.LogSafeEnum
typealias AgentFailureKind = LikelyStorage.AgentFailureKind

/// Appends timestamped lines to ~/Library/Logs/Likely/likely.log and stderr (dev builds: also the
/// unified log, message private; see `mirrorToUnifiedLog`).
///
/// Lines are `LogMessage`s: private values (queries, window titles, paths, agent text) are marked at the
/// call site. likely.log always gets them as short hashes. While "Log details for troubleshooting" is on
/// (dev builds: always), lines with private values also go in full to likely-details.log, which is
/// deleted when details turn off. See LogPrivacy.swift and docs/PRIVACY.md.
enum Log {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Likely", isDirectory: true)
    static let fileURL = directory.appendingPathComponent("likely.log")
    static let detailsURL = directory.appendingPathComponent(LogFile.detailsFileName)

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

    /// While set (launch, until DataProtection has moved the log folder to Likely.noindex), file lines
    /// wait here, so nothing creates ~/Library/Logs/Likely as a real folder first. Only used on `queue`.
    private static var held: [(Data, Data?)]?
    /// The folder's been checked for content from older versions (on `queue`).
    private static var prepared = false

    static func holdFileWrites() { queue.sync { held = held ?? [] } }
    static func startFileWrites() {
        queue.async {
            let lines = held ?? []
            held = nil
            lines.forEach(append)
        }
    }

    /// `category` is a literal; `message` marks its private values (see LogMessage).
    static func write(_ category: StaticString, _ message: LogMessage) {
        let detailed = details.showsDetails
        let stamp = "\(formatter.string(from: Date())) [\(category)] "
        let redacted = stamp + message.rendered(details: false) + "\n"
        let full = detailed && message.hasPrivateValues ? stamp + message.rendered(details: true) + "\n" : nil
        mirrorToUnifiedLog(category: "\(category)", text: message.rendered(details: detailed))
        if echoToStderr { FileHandle.standardError.write(Data((full ?? redacted).utf8)) }
        let lines = (Data(redacted.utf8), full.map { Data($0.utf8) })
        queue.async {
            if held != nil { held?.append(lines) } else { append(lines) }
        }
    }

    /// On `queue`.
    private static func append(_ lines: (Data, Data?)) {
        if !prepared {
            prepared = true
            try? OwnerOnly.createDirectory(directory)   // 0700; the files are 0600
            // Versions before redaction wrote queries, titles and paths in plaintext: start over.
            if LogFile.upgrade(log: fileURL) {
                appendLine(Data("\(formatter.string(from: Date())) [privacy] removed the log older versions wrote (it had searches, window titles and paths)\n".utf8), to: fileURL)
            }
        }
        appendLine(lines.0, to: fileURL)
        if let full = lines.1 { appendLine(full, to: detailsURL) }
    }

    private static func appendLine(_ data: Data, to url: URL) {
        // Created owner-only (0600); appends go to the end.
        if let handle = try? OwnerOnly.openForWriting(url, truncate: false) {
            handle.write(data)
            try? handle.close()
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

    /// The file "Open Log" shows: the full one while details are on.
    static var fileToOpen: URL {
        details.showsDetails && FileManager.default.fileExists(atPath: detailsURL.path) ? detailsURL : fileURL
    }

    /// Details turned off: what they wrote goes.
    static func removeDetails() {
        queue.async { LogFile.clear(at: detailsURL) }
    }

    /// Settings → General → Clear Log.
    static func clear() {
        queue.sync {
            LogFile.clear(at: fileURL)
            LogFile.clear(at: detailsURL)
        }
    }
}
