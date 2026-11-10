import Darwin
import Foundation

/// Advisory cross-process locks (flock(2)) for files that more than one Likely process may write: the
/// menu bar app and a `Likely --eval` run started from Settings or by the user's coding agent.
///
/// The lock is a separate, owner-only file next to the data (`<folder>/.likely.lock`), because the data
/// files are replaced by rename (OwnerOnly.write), which would leave a lock on the old inode.
///
/// `withLock` is reentrant within a process: flock locks belong to an open file description, so a second
/// open of the same lock file in the same process would wait for the first forever. Nested calls (any
/// thread holding it) reuse the descriptor that's already locked.
public enum FileLock {
    /// The lock file for data in `folder`.
    public static func url(for folder: URL) -> URL { folder.appendingPathComponent(".likely.lock") }

    private final class Entry {
        let lock = NSRecursiveLock()
        var fd: Int32 = -1
        var depth = 0
    }

    /// Opens (creating 0600 if needed) a lock file: never through a symlink (O_NOFOLLOW), and only a
    /// regular file. -1 if it can't (errno set).
    static func openLockFile(_ path: String, create: Bool = true) -> Int32 {
        let fd = open(path, O_RDWR | O_CLOEXEC | O_NOFOLLOW | (create ? O_CREAT : 0), OwnerOnly.fileMode)
        guard fd >= 0 else { return -1 }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            close(fd)
            errno = EFTYPE
            return -1
        }
        return fd
    }

    /// File systems without flock (some network volumes) answer ENOTSUP: then the lock is skipped,
    /// by `withLock` and `tryHold` alike, and the work goes ahead unlocked, as it did before locks.
    static func unsupported(_ code: Int32) -> Bool { code == ENOTSUP || code == EOPNOTSUPP }

    private static let registryLock = NSLock()
    private static var entries: [String: Entry] = [:]

    private static func entry(_ path: String) -> Entry {
        registryLock.lock()
        defer { registryLock.unlock() }
        if let e = entries[path] { return e }
        let e = Entry()
        entries[path] = e
        return e
    }

    /// Runs `body` holding an exclusive lock on `lockURL` (created 0600 if needed, in a 0700 folder).
    /// Waits for other processes. If the lock file can't be opened (read-only volume, …) `body` runs
    /// without it: the lock only orders writers, it never decides whether data may be written.
    public static func withLock<T>(_ lockURL: URL, _ body: () throws -> T) rethrows -> T {
        let path = lockURL.standardizedFileURL.path
        let e = entry(path)
        e.lock.lock()
        defer { e.lock.unlock() }
        if e.depth == 0 {
            try? OwnerOnly.createDirectory(lockURL.deletingLastPathComponent())
            let fd = openLockFile(path)
            if fd >= 0 {
                var result: Int32
                repeat { result = flock(fd, LOCK_EX) } while result != 0 && errno == EINTR
                // Locked, or (ENOTSUP) a file system without locks: either way go ahead.
                e.fd = fd
            }
        }
        e.depth += 1
        defer {
            e.depth -= 1
            if e.depth == 0, e.fd >= 0 {
                flock(e.fd, LOCK_UN)
                close(e.fd)
                e.fd = -1
            }
        }
        return try body()
    }

    /// `withLock`, but only if the lock file already exists (a writer made it): for readers of files that
    /// may not be Likely's (the repo's fixtures, an app bundle), next to which no lock file is created.
    public static func withLockIfPresent<T>(_ lockURL: URL, _ body: () throws -> T) rethrows -> T {
        var st = stat()
        guard lstat(lockURL.path, &st) == 0 else { return try body() }
        return try withLock(lockURL, body)
    }

    /// A lock held until `release()` or the process exits: for "only one of these at a time" (an eval
    /// run). Never inherited by child processes (O_CLOEXEC), so an agent or a daemon an agent starts
    /// can't keep it after Likely is gone.
    public final class Held {
        private var fd: Int32
        /// False on a file system without flock (see `unsupported`): nothing is actually held.
        public let isLocked: Bool
        fileprivate init(fd: Int32, isLocked: Bool = true) {
            self.fd = fd
            self.isLocked = isLocked
        }
        public func release() {
            guard fd >= 0 else { return }
            flock(fd, LOCK_UN)
            close(fd)
            fd = -1
        }
        deinit { release() }
    }

    /// Takes the lock without waiting. Nil if another process (or another `tryHold` in this one) has it.
    /// Throws if the lock file can't be created.
    public static func tryHold(_ lockURL: URL) throws -> Held? {
        try OwnerOnly.createDirectory(lockURL.deletingLastPathComponent())
        let fd = openLockFile(lockURL.path)
        guard fd >= 0 else { throw OwnerOnly.Failure("Can't open", lockURL.path) }
        fchmod(fd, OwnerOnly.fileMode)
        while true {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return Held(fd: fd) }
            if errno == EINTR { continue }
            let code = errno
            if unsupported(code) { return Held(fd: fd, isLocked: false) }
            close(fd)
            if code == EWOULDBLOCK { return nil }
            throw OwnerOnly.Failure("Can't lock", lockURL.path, errno: code)
        }
    }
}
