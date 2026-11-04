import Foundation
import os

/// Appends timestamped lines to ~/Library/Logs/Likely/likely.log, the unified log, and stderr.
enum Log {
    static let fileURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Likely", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
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

    static func write(_ category: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) [\(category)] \(message)\n"
        logger.info("[\(category, privacy: .public)] \(message, privacy: .public)")
        let data = Data(line.utf8)
        if echoToStderr { FileHandle.standardError.write(data) }
        queue.async {
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: fileURL)
            }
        }
    }
}
