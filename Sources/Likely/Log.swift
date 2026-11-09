import Foundation
import LikelyStorage
import os

/// Appends timestamped lines to ~/Library/Logs/Likely/likely.log, the unified log, and stderr.
enum Log {
    static let fileURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Likely", isDirectory: true)
        try? OwnerOnly.createDirectory(dir)   // 0700; the file is 0600 (see `write`)
        return dir.appendingPathComponent("likely.log")
    }()

    private static let queue = DispatchQueue(label: "inc.synth.likely.log")
    private static let logger = Logger(subsystem: "inc.synth.likely", category: "app")
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// The eval runner turns this off so its own output stays readable (`--verbose` turns it back on).
    static var echoToStderr = true

    /// While set (launch, until DataProtection has moved the log folder to Likely.noindex), file lines
    /// wait here, so nothing creates ~/Library/Logs/Likely as a real folder first. Only used on `queue`.
    private static var held: [Data]?
    static func holdFileWrites() { queue.sync { held = held ?? [] } }
    static func startFileWrites() {
        queue.async {
            let lines = held ?? []
            held = nil
            lines.forEach(appendToFile)
        }
    }

    static func write(_ category: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) [\(category)] \(message)\n"
        logger.info("[\(category, privacy: .public)] \(message, privacy: .public)")
        let data = Data(line.utf8)
        if echoToStderr { FileHandle.standardError.write(data) }
        queue.async {
            if held != nil { held?.append(data) } else { appendToFile(data) }
        }
    }

    private static func appendToFile(_ data: Data) {
        // Created owner-only (0600); appends go to the end.
        if let handle = try? OwnerOnly.openForWriting(fileURL, truncate: false) {
            handle.write(data)
            try? handle.close()
        }
    }
}
