import Foundation
import LikelyStorage

/// Screenshots saved with personal test cases (evals/screenshots): encrypted on disk as
/// `<case id>.png.enc` (DataCipher, the data key in the Keychain). They're only ever decrypted in
/// memory (the case editor's preview), or into a temporary 0600 file in an eval run's own case folder
/// for the agent to read, deleted when the case ends.
///
/// Screenshots outside that folder (the repo's fixtures, a path the user typed) are plain PNGs and
/// are read as they are.
public enum EvalScreenshots {
    public static let encryptedExtension = "enc"

    public static func isEncrypted(_ path: String) -> Bool { path.hasSuffix(".png.enc") }

    /// Encrypts `png` to `<folder>/<id>.png.enc` (replacing any file there). Returns its path.
    public static func save(_ png: Data, id: String, in folder: URL = EvalStorage.screenshotsURL,
                            cipher: DataCipher) throws -> String {
        let url = folder.appendingPathComponent("\(EvalCase.slug(id, fallback: "case")).png.enc")
        try OwnerOnly.write(try cipher.sealFile(png), to: url)
        return url.path
    }

    /// The PNG bytes behind a case's `screenshot` path: decrypted if it's `.png.enc`; a plain file
    /// otherwise; and for a `.png` reference whose file was encrypted by `encryptExisting`, the
    /// `.png.enc` next to it.
    public static func load(_ path: String, cipher: DataCipher) throws -> Data {
        let fm = FileManager.default
        if isEncrypted(path) { return try cipher.openFile(try Data(contentsOf: URL(fileURLWithPath: path))) }
        if !fm.fileExists(atPath: path), fm.fileExists(atPath: path + ".enc") {
            return try cipher.openFile(try Data(contentsOf: URL(fileURLWithPath: path + ".enc")))
        }
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    /// Whether `path` needs decrypting before an agent can read it (see `load`).
    public static func needsDecrypting(_ path: String) -> Bool {
        isEncrypted(path) || (!FileManager.default.fileExists(atPath: path) && FileManager.default.fileExists(atPath: path + ".enc"))
    }

    /// A readable PNG for an agent, in `workDir` (an eval case's own folder, which its sandbox may read):
    /// the plain file itself, or a temporary 0600 decrypted copy the caller deletes afterwards
    /// (`isTemporary`).
    public static func materialize(_ path: String, in workDir: URL, cipher: DataCipher) throws -> (url: URL, isTemporary: Bool) {
        guard needsDecrypting(path) else { return (URL(fileURLWithPath: path), false) }
        let url = workDir.appendingPathComponent("screenshot-\(UUID().uuidString.prefix(8)).png")
        try OwnerOnly.write(try load(path, cipher: cipher), to: url)
        return (url, true)
    }

    /// Encrypts every plain `.png` in `folder` to `.png.enc` and deletes the original, then points
    /// the cases and drafts that referred to it at the new file (only in files that read cleanly; a
    /// reference left behind still works through `load`). Returns how many screenshots were encrypted.
    @discardableResult
    public static func encryptExisting(in folder: URL = EvalStorage.screenshotsURL,
                                       caseFiles: [URL] = [EvalStorage.casesURL, EvalStorage.draftsURL],
                                       cipher: DataCipher) throws -> Int {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        var moved: [String: String] = [:]   // standardized old path → new path
        for name in names where name.lowercased().hasSuffix(".png") {
            let plain = folder.appendingPathComponent(name)
            let sealed = folder.appendingPathComponent(name + ".enc")
            let data = try Data(contentsOf: plain)
            try OwnerOnly.write(try cipher.sealFile(data), to: sealed)
            // Only delete the original once the encrypted copy reads back.
            guard (try? cipher.openFile(Data(contentsOf: sealed))) == data else {
                try? fm.removeItem(at: sealed)
                continue
            }
            try fm.removeItem(at: plain)
            moved[plain.standardizedFileURL.path] = sealed.path
        }
        guard !moved.isEmpty else { return 0 }
        for file in caseFiles {
            guard let (cases, errors) = try? EvalCaseFile.load(file), errors.isEmpty else { continue }
            for c in cases {
                guard let shot = c.context?.screenshot,
                      let new = moved[URL(fileURLWithPath: (shot as NSString).expandingTildeInPath).standardizedFileURL.path] else { continue }
                var updated = c
                updated.context?.screenshot = new
                try? EvalCaseFile.replace(id: c.id, with: updated, in: file)
            }
        }
        return moved.count
    }
}
