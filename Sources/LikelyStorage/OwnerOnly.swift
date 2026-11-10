import Darwin
import Foundation

/// Owner-only files and folders: everything Likely keeps under ~/Library/Application Support/Likely
/// and ~/Library/Logs/Likely is 0600 (files) in 0700 folders.
///
/// Files are created with those permissions (open(2) with mode 0600), never written 0644 and fixed
/// afterwards, so there's no moment where another user could open them. `repair` fixes what older
/// versions (or editors, which usually write 0644) left behind.
public enum OwnerOnly {
    public static let fileMode: mode_t = 0o600
    public static let executableMode: mode_t = 0o700
    public static let directoryMode: mode_t = 0o700

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
        public init(_ what: String, _ path: String, errno code: Int32 = errno) {
            description = "\(what) \(path): \(String(cString: strerror(code)))"
        }
    }

    /// `mkdir -p` where every folder it creates is 0700. Existing folders are left as they are.
    public static func createDirectory(_ url: URL) throws {
        let path = url.standardizedFileURL.path
        var missing: [String] = []
        var current = path
        while !current.isEmpty, current != "/" {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: current, isDirectory: &isDir) {
                guard isDir.boolValue else { throw Failure("Not a folder:", current, errno: ENOTDIR) }
                break
            }
            missing.append(current)
            current = (current as NSString).deletingLastPathComponent
        }
        for dir in missing.reversed() {
            if mkdir(dir, directoryMode) != 0 && errno != EEXIST { throw Failure("Can't create", dir) }
            // mkdir applies the umask; 0700 & ~umask is 0700 for any usual umask, but make sure.
            chmod(dir, directoryMode)
        }
    }

    /// Writes `data` atomically: a temporary file created 0600 next to `url`, flushed to the disk
    /// (F_FULLFSYNC, so a power loss right after can't leave an empty file behind the rename), then
    /// renamed over it.
    public static func write(_ data: Data, to url: URL, mode: mode_t = fileMode) throws {
        try createDirectory(url.deletingLastPathComponent())
        let dir = url.deletingLastPathComponent().path
        let temp = dir + "/." + url.lastPathComponent + ".tmp-" + UUID().uuidString.prefix(8)
        let fd = open(temp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode)
        guard fd >= 0 else { throw Failure("Can't create", temp) }
        var ok = false
        defer {
            close(fd)
            if !ok { unlink(temp) }
        }
        fchmod(fd, mode)   // in case the umask took bits off
        try writeAll(fd, data, path: temp)
        if fcntl(fd, F_FULLFSYNC) != 0 { fsync(fd) }   // F_FULLFSYNC isn't supported by every file system
        guard rename(temp, url.path) == 0 else { throw Failure("Can't replace", url.path) }
        ok = true
    }

    public static func write(_ text: String, to url: URL) throws {
        try write(Data(text.utf8), to: url)
    }

    /// Opens `url` for writing, creating it 0600 if needed. `truncate`: start it over; otherwise
    /// writes go to the end. An existing file with wider permissions is narrowed.
    public static func openForWriting(_ url: URL, truncate: Bool) throws -> FileHandle {
        try createDirectory(url.deletingLastPathComponent())
        let flags = O_WRONLY | O_CREAT | O_CLOEXEC | (truncate ? O_TRUNC : O_APPEND)
        let fd = open(url.path, flags, fileMode)
        guard fd >= 0 else { throw Failure("Can't open", url.path) }
        fchmod(fd, fileMode)
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// Creates an empty 0600 file if there's nothing at `url` (never truncates). Returns false if it existed.
    @discardableResult
    public static func createExclusive(_ url: URL) throws -> Bool {
        try createDirectory(url.deletingLastPathComponent())
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, fileMode)
        if fd >= 0 {
            fchmod(fd, fileMode)
            close(fd)
            return true
        }
        if errno == EEXIST { return false }
        throw Failure("Can't create", url.path)
    }

    private static func writeAll(_ fd: Int32, _ data: Data, path: String) throws {
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw Failure("Can't write", path)
                }
                offset += n
            }
        }
    }

    /// Narrows everything under `root` (and `root` itself) to owner-only: folders 0700, files 0600,
    /// files with any execute bit 0700. Symbolic links aren't followed (and their targets aren't
    /// touched). Returns how many items changed.
    ///
    /// `root` itself may be the link SpotlightExclusion makes (Likely → Likely.noindex): that one is
    /// followed, but only to `<root>.noindex` next to it. A link anywhere else (planted, or the user's
    /// own) is left alone, so nothing outside Likely's folders is ever chmodded.
    @discardableResult
    public static func repair(_ root: URL) -> Int {
        var changed = 0
        func fix(_ path: String) -> Bool {
            var st = stat()
            guard lstat(path, &st) == 0 else { return false }
            let type = st.st_mode & S_IFMT
            let current = st.st_mode & 0o7777
            let wanted: mode_t
            switch type {
            case S_IFDIR: wanted = directoryMode
            case S_IFREG: wanted = (current & 0o111) != 0 ? executableMode : fileMode
            default: return false   // symlinks, sockets, …
            }
            if current != wanted, chmod(path, wanted) == 0 { changed += 1 }
            return type == S_IFDIR
        }
        guard let rootPath = repairRoot(root) else { return 0 }
        guard fix(rootPath) else { return changed }
        var stack = [rootPath]
        while let dir = stack.popLast() {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] {
                let path = dir + "/" + name
                if fix(path) { stack.append(path) }
            }
        }
        return changed
    }

    /// The folder `repair` works on: `root` itself, or for a link, its target if (and only if) that's
    /// `<root>.noindex` in the same folder. Nil for any other link.
    static func repairRoot(_ root: URL) -> String? {
        let path = root.standardizedFileURL.path
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        guard st.st_mode & S_IFMT == S_IFLNK else { return path }
        let expected = SpotlightExclusion.realFolder(for: root.standardizedFileURL).path
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        guard let parent = realpath((path as NSString).deletingLastPathComponent, nil) else { return nil }
        defer { free(parent) }
        let wanted = String(cString: parent) + "/" + (expected as NSString).lastPathComponent
        // The link's target must be that folder itself, not a link onward from it.
        var target = stat()
        guard String(cString: resolved) == wanted, lstat(wanted, &target) == 0, target.st_mode & S_IFMT == S_IFDIR else { return nil }
        return wanted
    }

    /// Permission bits of the item at `path` (lstat), or nil.
    public static func mode(_ path: String) -> mode_t? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return st.st_mode & 0o7777
    }
}
