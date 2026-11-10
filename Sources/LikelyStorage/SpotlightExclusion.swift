import Darwin
import Foundation

/// Keeps a folder out of Spotlight, so eval runs, reports and history never show up in
/// an agent's `mdfind` (an eval's expected answer leaking into the search it's testing, or names of
/// past searches turning up as "results").
///
/// A `.metadata_never_index` file no longer does this for an ordinary folder: checked on macOS 26
/// (Darwin 25.3), files under a folder holding it were still returned by `mdfind`, with and without
/// `mdimport`. What Spotlight does still skip is any folder whose name ends in `.noindex` (and
/// dot-folders). Moving an indexed folder to a `.noindex` name also drops its files from the index.
///
/// So the real folder becomes `<name>.noindex` and `<name>` is a symbolic link to it: every path
/// Likely, its docs and the user's coding agent use (…/Application Support/Likely/tools.json) keeps
/// working. The marker file is written too, for older macOS versions that honor it.
public enum SpotlightExclusion {
    public static let suffix = ".noindex"
    public static let marker = ".metadata_never_index"

    public enum Outcome: Equatable {
        /// Already a link to a `.noindex` folder.
        case alreadyExcluded
        /// The folder was moved and linked (or created that way).
        case excluded
        /// Both names were real folders (an earlier launch was split: something recreated the folder
        /// before the link was made): the folder's contents were merged into the `.noindex` one,
        /// and it was replaced by the link.
        case merged
        /// Left alone, with the reason (a link somewhere else, or not a folder).
        case skipped(String)
    }

    /// The real location of `folder` once excluded: `<folder>.noindex`.
    public static func realFolder(for folder: URL) -> URL {
        folder.deletingLastPathComponent().appendingPathComponent(folder.lastPathComponent + suffix, isDirectory: true)
    }

    @discardableResult
    public static func exclude(_ folder: URL) throws -> Outcome {
        try exclude(folder, attempts: 3)
    }

    private static func exclude(_ folder: URL, attempts: Int) throws -> Outcome {
        let fm = FileManager.default
        let path = folder.standardizedFileURL.path
        let target = realFolder(for: folder)
        let linkText = target.lastPathComponent   // relative, so the pair can be moved together

        var st = stat()
        if lstat(path, &st) == 0 {
            switch st.st_mode & S_IFMT {
            case S_IFLNK:
                let destination = (try? fm.destinationOfSymbolicLink(atPath: path)) ?? ""
                guard destination.hasSuffix(suffix) || destination.hasSuffix(suffix + "/") else {
                    return .skipped("\(path) is a link to \(destination)")
                }
                try OwnerOnly.createDirectory(target)
                writeMarker(in: target)
                return .alreadyExcluded
            case S_IFDIR:
                var targetStat = stat()
                if lstat(target.path, &targetStat) == 0 {
                    guard targetStat.st_mode & S_IFMT == S_IFDIR else { return .skipped("\(target.path) isn't a folder") }
                    // Split by an earlier launch: put everything in the .noindex folder, then link.
                    try merge(path, into: target.path)
                    guard symlink(linkText, path) == 0 else { throw OwnerOnly.Failure("Merged \(path) into \(target.path) but can't link", path) }
                    writeMarker(in: target)
                    return .merged
                }
                guard rename(path, target.path) == 0 else { throw OwnerOnly.Failure("Can't rename", path) }
                if symlink(linkText, path) != 0 {
                    let code = errno
                    // Something recreated the folder in between: put ours back rather than split the data.
                    if rename(target.path, path) != 0 {
                        throw OwnerOnly.Failure("Moved \(path) to \(target.path) but couldn't link or move it back:", path, errno: code)
                    }
                    throw OwnerOnly.Failure("Can't link", path, errno: code)
                }
            default:
                return .skipped("\(path) isn't a folder")
            }
        } else {
            try OwnerOnly.createDirectory(target)
            if symlink(linkText, path) != 0 {
                let code = errno
                // Something made `path` meanwhile: our link (another Likely), or a real folder (a write
                // that raced this one). Look again: a link is checked, a folder merged.
                guard code == EEXIST, attempts > 1 else { throw OwnerOnly.Failure("Can't link", path, errno: code) }
                return try exclude(folder, attempts: attempts - 1)
            }
        }
        writeMarker(in: target)
        return .excluded
    }

    /// Moves everything in `source` into the existing folder `destination`, then removes `source`.
    /// Nothing is overwritten: a folder in both is merged the same way, a `.log` file in both is
    /// appended to the other, and any other name in both is kept as `<name>.merged-<n>`.
    static func merge(_ source: String, into destination: String) throws {
        for name in try FileManager.default.contentsOfDirectory(atPath: source) {
            let from = source + "/" + name
            let to = destination + "/" + name
            var a = stat(), b = stat()
            guard lstat(from, &a) == 0 else { continue }
            if lstat(to, &b) != 0 {
                guard rename(from, to) == 0 else { throw OwnerOnly.Failure("Can't move", from) }
                continue
            }
            let fromType = a.st_mode & S_IFMT, toType = b.st_mode & S_IFMT
            if fromType == S_IFDIR, toType == S_IFDIR {
                try merge(from, into: to)
            } else if name == marker {
                unlink(from)
            } else if fromType == S_IFREG, toType == S_IFREG, name.hasSuffix(".log") {
                let handle = try OwnerOnly.openForWriting(URL(fileURLWithPath: to), truncate: false)
                handle.write(try Data(contentsOf: URL(fileURLWithPath: from)))
                try handle.close()
                unlink(from)
            } else {
                var n = 1
                var other = to + ".merged-\(n)"
                while lstat(other, &b) == 0 { n += 1; other = to + ".merged-\(n)" }
                guard rename(from, other) == 0 else { throw OwnerOnly.Failure("Can't move", from) }
            }
        }
        guard rmdir(source) == 0 else { throw OwnerOnly.Failure("Can't remove", source) }
    }

    private static func writeMarker(in folder: URL) {
        let url = folder.appendingPathComponent(marker)
        _ = try? OwnerOnly.createExclusive(url)
    }
}
