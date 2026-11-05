import CoreGraphics
import Foundation
import SQLite3

/// Optional image search by content with rclip (https://github.com/yurijmikhalevich/rclip), a local
/// CLIP index the user installs with Homebrew. Likely never installs it; when it and its index are
/// there, the prompt tells the agent how to use it, and Likely keeps the index fresh in the background.
enum ImageSearch {
    private static let home = FileManager.default.homeDirectoryForCurrentUser.path

    /// rclip's executable: Homebrew, pipx/uv (~/.local/bin), then PATH.
    static var rclipPath: String? {
        let env = ProcessInfo.processInfo.environment
        let fromPath = (env["PATH"] ?? "").split(separator: ":").map { "\($0)/rclip" }
        let candidates = ["/opt/homebrew/bin/rclip", "/usr/local/bin/rclip", "\(home)/.local/bin/rclip"] + fromPath
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:))
    }

    /// rclip's data folder (index and model): $RCLIP_DATADIR, else ~/Library/Application Support/rclip.
    static var dataDirectory: String {
        ProcessInfo.processInfo.environment["RCLIP_DATADIR"] ?? "\(home)/Library/Application Support/rclip"
    }

    static var databasePath: String { dataDirectory + "/db.sqlite3" }
    static var hasIndex: Bool { FileManager.default.fileExists(atPath: databasePath) }
    static var isAvailable: Bool { rclipPath != nil && hasIndex }

    /// Evals only: off for isolated runs (the index would list the user's own images).
    static var evalDisabled = false

    /// The Settings toggle; on by default once rclip and its index exist.
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "imageSearch") as? Bool ?? isAvailable }
        set { UserDefaults.standard.set(newValue, forKey: "imageSearch") }
    }

    /// Whether the prompt mentions rclip.
    static var isActive: Bool { !evalDisabled && isEnabled && isAvailable }

    struct IndexInfo {
        var images: Int?
        var bytes: Int64
        var updated: Date?
    }

    /// Size, image count and last change of the index. Reads the database read-only; call off the main thread.
    static func indexInfo() -> IndexInfo? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: databasePath) else { return nil }
        var info = IndexInfo(images: nil, bytes: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                             updated: attributes[.modificationDate] as? Date)
        var db: OpaquePointer?
        if sqlite3_open_v2(databasePath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
            sqlite3_busy_timeout(db, 2000)
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT count(*) FROM images WHERE deleted IS NULL", -1, &statement, nil) == SQLITE_OK,
               sqlite3_step(statement) == SQLITE_ROW {
                info.images = Int(sqlite3_column_int64(statement, 0))
            }
            sqlite3_finalize(statement)
        }
        sqlite3_close(db)
        return info
    }

    /// Prompt section for the `{{imageSearch}}` placeholder (empty when rclip isn't in use).
    static var promptSection: String {
        guard isActive else { return "" }
        return """
           - Images, by what they show (whenever an image could be the answer): rclip has a local CLIP index of the images under ~. Rewrite the request into 1–3 concrete visual descriptions; CLIP matches what's in the picture, not words like "my" or "the one from". E.g. "the receipt from dinner" → "a photo of a paper restaurant receipt"; "our logo" → "a simple flat logo on a plain background"; "screenshot of the error" → "a screenshot of an app window showing an error message"; "my profile picture" → "a close-up headshot portrait photo of a person looking at the camera"; "the floor plan" → "an architectural floor plan drawing". Run each: `cd ~ && rclip -n -t 30 "<description>"` (score and path, best first).
        """
    }

    // MARK: Freshness

    /// rclip's own default exclusions (passing --exclude-dir replaces them), plus app data, caches and
    /// build output. rclip matches folder *names* at any depth. `Contents` keeps it out of app bundles
    /// and `Applications`/`build` out of build folders (a dmg layout's Applications symlink pulled in
    /// tens of thousands of app icons in testing). Hidden folders are skipped unless --include-hidden.
    static let excludedDirectories = ["@eaDir", "node_modules", ".git", "System Volume Information",
                                      "Library", "Caches", "DerivedData", "Applications", "Contents", "build"]
}

/// Re-indexes in the background so new images show up: `rclip` without `-n` (a throwaway query) from ~,
/// at background priority, at most every 6 hours, only while the user is idle and the toggle is on.
final class ImageIndexer {
    static let shared = ImageIndexer()

    private let interval: TimeInterval = 6 * 3600
    private let idleSeconds: TimeInterval = 300
    private var timer: Timer?
    private var process: Process?
    private static let lastRunKey = "imageSearchLastIndex"

    static var lastRun: Date? { UserDefaults.standard.object(forKey: lastRunKey) as? Date }
    var isRunning: Bool { process?.isRunning ?? false }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in self?.runIfDue() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in self?.runIfDue() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        process?.terminate()
    }

    private func runIfDue() {
        guard !isRunning, ImageSearch.isEnabled, ImageSearch.isAvailable, let rclip = ImageSearch.rclipPath else { return }
        if let last = Self.lastRun, Date().timeIntervalSince(last) < interval { return }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        guard idle >= idleSeconds else { return }
        run(rclip: rclip)
    }

    private func run(rclip: String) {
        let process = Process()
        // nice + taskpolicy -b: lowest CPU priority, throttled disk I/O.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nice")
        process.arguments = ["-n", "19", "/usr/sbin/taskpolicy", "-b", rclip, "-t", "1"]
            + ImageSearch.excludedDirectories.flatMap { ["--exclude-dir", $0] } + ["photo"]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.qualityOfService = .background
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        // Keep only the tail of stderr (progress bars are long).
        var tail = Data()
        let lock = NSLock()
        errors.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            lock.lock(); tail.append(chunk); if tail.count > 4000 { tail = tail.suffix(2000) }; lock.unlock()
        }
        let started = Date()
        process.terminationHandler = { [weak self] finished in
            errors.fileHandleForReading.readabilityHandler = nil
            lock.lock()
            let message = String(decoding: tail, as: UTF8.self).split(whereSeparator: { $0 == "\n" || $0 == "\r" })
                .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }).map(String.init) ?? ""
            lock.unlock()
            let seconds = Date().timeIntervalSince(started)
            Log.write("rclip", String(format: "re-index finished in %.0fs, status %d%@", seconds, finished.terminationStatus,
                                      finished.terminationStatus == 0 ? "" : " (\(message.suffix(200)))"))
            DispatchQueue.main.async { self?.process = nil }
        }
        do {
            try process.run()
            self.process = process
            UserDefaults.standard.set(started, forKey: Self.lastRunKey)
            Log.write("rclip", "re-index started (pid \(process.processIdentifier))")
        } catch {
            Log.write("rclip", "re-index failed to start: \(error)")
        }
    }
}
