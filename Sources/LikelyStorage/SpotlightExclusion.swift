import Darwin
import Foundation

/// Keeps a folder out of Spotlight, so eval runs, reports, history and screenshots never show up in
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
        /// Left alone, with the reason (a link somewhere else, or both names taken).
        case skipped(String)
    }

    /// The real location of `folder` once excluded: `<folder>.noindex`.
    public static func realFolder(for folder: URL) -> URL {
        folder.deletingLastPathComponent().appendingPathComponent(folder.lastPathComponent + suffix, isDirectory: true)
    }

    @discardableResult
    public static func exclude(_ folder: URL) throws -> Outcome {
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
                if fm.fileExists(atPath: target.path) { return .skipped("both \(path) and \(target.path) exist") }
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
            if symlink(linkText, path) != 0 && errno != EEXIST { throw OwnerOnly.Failure("Can't link", path) }
        }
        writeMarker(in: target)
        return .excluded
    }

    private static func writeMarker(in folder: URL) {
        let url = folder.appendingPathComponent(marker)
        _ = try? OwnerOnly.createExclusive(url)
    }
}
