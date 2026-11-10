import XCTest
@testable import LikelyStorage

/// Cross-process locks between the app and `Likely --eval` (FileLock). Another process holds the lock
/// with perl's flock, which uses the same flock(2) locks.
final class FileLockTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("filelock-\(UUID().uuidString)")
        try OwnerOnly.createDirectory(dir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Starts a process that holds an exclusive flock on `url` for `seconds`, and waits until it has it.
    private func holdInAnotherProcess(_ url: URL, seconds: Double) throws -> Process {
        let ready = dir.appendingPathComponent("ready-\(UUID().uuidString)")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = ["-e", "use Fcntl ':flock'; open(my $f, '>>', $ARGV[0]) or die; flock($f, LOCK_EX) or die; "
                       + "open(my $r, '>', $ARGV[1]); close($r); select(undef, undef, undef, $ARGV[2]);",
                       url.path, ready.path, String(seconds)]
        try p.run()
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: ready.path), Date() < deadline { usleep(10_000) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path), "perl didn't take the lock")
        return p
    }

    func testTryHoldIsExclusiveAndReleases() throws {
        let url = dir.appendingPathComponent(".run.lock")
        let first = try XCTUnwrap(try FileLock.tryHold(url))
        XCTAssertNil(try FileLock.tryHold(url), "a second run must not start")
        first.release()
        let again = try FileLock.tryHold(url)
        XCTAssertNotNil(again)
        // Owner-only.
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testTryHoldSeesAnotherProcess() throws {
        let url = dir.appendingPathComponent(".run.lock")
        let other = try holdInAnotherProcess(url, seconds: 0.5)
        XCTAssertNil(try FileLock.tryHold(url), "another process's run is in progress")
        other.waitUntilExit()
        XCTAssertNotNil(try FileLock.tryHold(url), "free once that process exited")
    }

    func testWithLockWaitsForAnotherProcess() throws {
        let url = FileLock.url(for: dir)
        let other = try holdInAnotherProcess(url, seconds: 0.6)
        let start = Date()
        FileLock.withLock(url) {}
        XCTAssertGreaterThan(Date().timeIntervalSince(start), 0.3, "should have waited for the other process")
        other.waitUntilExit()
    }

    func testWithLockIsReentrant() {
        let url = FileLock.url(for: dir)
        var reached = false
        FileLock.withLock(url) {
            FileLock.withLock(url) { reached = true }
        }
        XCTAssertTrue(reached)
    }

    func testWithLockSerializesThreads() {
        let url = FileLock.url(for: dir)
        let file = dir.appendingPathComponent("counter")
        try? Data("0".utf8).write(to: file)
        DispatchQueue.concurrentPerform(iterations: 50) { _ in
            FileLock.withLock(url) {
                let n = Int(String(decoding: (try? Data(contentsOf: file)) ?? Data(), as: UTF8.self)) ?? -1000
                try? OwnerOnly.write(Data("\(n + 1)".utf8), to: file)
            }
        }
        XCTAssertEqual(String(decoding: (try? Data(contentsOf: file)) ?? Data(), as: UTF8.self), "50")
    }
}

final class FileLockSafetyTests: XCTestCase {
    func testLockFilesAreNeverFollowedThroughSymlinksOrNonFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("filelock-safety-\(UUID().uuidString)")
        try OwnerOnly.createDirectory(dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("victim")
        try Data("keep".utf8).write(to: target)
        let link = dir.appendingPathComponent(".run.lock")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try FileLock.tryHold(link))
        var ran = false
        FileLock.withLock(link) { ran = true }   // goes ahead unlocked, but never opens the target
        XCTAssertTrue(ran)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep")
        let folderLock = dir.appendingPathComponent("folder.lock")
        try FileManager.default.createDirectory(at: folderLock, withIntermediateDirectories: false)
        XCTAssertThrowsError(try FileLock.tryHold(folderLock))
    }

    func testReadersDontCreateLockFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("filelock-reader-\(UUID().uuidString)")
        try OwnerOnly.createDirectory(dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let lock = FileLock.url(for: dir)
        FileLock.withLockIfPresent(lock) {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: lock.path))
        FileLock.withLock(lock) {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: lock.path))
    }
}
