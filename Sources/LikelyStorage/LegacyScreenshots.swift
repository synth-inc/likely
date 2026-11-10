import Darwin
import Foundation

/// Likely no longer takes screenshots. Older versions left them in its data folder; this deletes
/// them once at launch (and again at later launches, which finds nothing):
/// - `evals/screenshots/*`: screenshots saved with test cases, encrypted (`.png.enc`) or not;
/// - `run/context*.png`: the screenshot sent with a search (left by a crash);
/// - `debug/*.png`: the Debug View's copies (dev builds);
/// - `evals/runs/**/screenshot-<8 hex>.png`: decrypted copies an eval run left when it was killed.
///
/// Only regular files with those names, in those folders, are deleted. The data folder is resolved
/// like OwnerOnly.repair does (…/Likely, or the `Likely.noindex` it links to); no other link is
/// followed, so nothing outside Likely's folder is touched. Test cases that still name a screenshot
/// keep the field; it's ignored.
public enum LegacyScreenshots {
    /// Returns how many files were deleted.
    @discardableResult
    public static func removeAll(support: URL = LikelyDataPaths.support()) -> Int {
        guard let root = OwnerOnly.repairRoot(support) else { return 0 }
        var removed = 0
        removed += removeFiles(in: root + "/run") { $0.hasPrefix("context") && $0.lowercased().hasSuffix(".png") }
        removed += removeFiles(in: root + "/debug") { $0.lowercased().hasSuffix(".png") }
        let evals = root + "/evals"
        guard isFolder(evals) else { return removed }
        let shots = evals + "/screenshots"
        removed += removeFiles(in: shots) { _ in true }
        // The folder itself goes once it's empty (nothing else was ever kept there).
        if isFolder(shots), (try? FileManager.default.contentsOfDirectory(atPath: shots))?.isEmpty == true { rmdir(shots) }
        removed += removeTemporaryCopies(under: evals + "/runs")
        return removed
    }

    /// The decrypted copies eval runs made, `screenshot-<8 hex>.png`.
    static func isTemporaryCopy(_ name: String) -> Bool {
        name.range(of: #"^screenshot-[0-9A-Fa-f]{8}\.png$"#, options: .regularExpression) != nil
    }

    /// Regular files directly in `folder` (a real folder, not a link) whose names match.
    private static func removeFiles(in folder: String, where matches: (String) -> Bool) -> Int {
        guard isFolder(folder) else { return 0 }
        var removed = 0
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] where matches(name) {
            if isRegularFile(folder + "/" + name), unlink(folder + "/" + name) == 0 { removed += 1 }
        }
        return removed
    }

    /// Walks real folders only (links aren't followed).
    private static func removeTemporaryCopies(under runs: String) -> Int {
        guard isFolder(runs) else { return 0 }
        var removed = 0
        var stack = [runs]
        while let dir = stack.popLast() {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] {
                let path = dir + "/" + name
                if isFolder(path) {
                    stack.append(path)
                } else if isTemporaryCopy(name), isRegularFile(path), unlink(path) == 0 {
                    removed += 1
                }
            }
        }
        return removed
    }

    private static func type(_ path: String) -> mode_t? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return st.st_mode & S_IFMT
    }

    private static func isFolder(_ path: String) -> Bool { type(path) == S_IFDIR }
    private static func isRegularFile(_ path: String) -> Bool { type(path) == S_IFREG }
}
