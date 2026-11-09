import Foundation
import XCTest
@testable import LikelyEvalKit
import LikelyStorage

final class EvalScreenshotsTests: XCTestCase {
    private var dir: URL!
    private let cipher = DataCipher(store: InMemoryKeyStore())
    private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array("pixels of a tax form".utf8))
    private var shots: URL { dir.appendingPathComponent("screenshots") }

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("likely-shots-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testEncryptedExtensionIsCaseInsensitive() throws {
        XCTAssertTrue(EvalScreenshots.isEncrypted("/a/X.PNG.enc"))
        XCTAssertTrue(EvalScreenshots.isEncrypted("/a/x.Png.Enc"))
        XCTAssertFalse(EvalScreenshots.isEncrypted("/a/x.png"))
        // encryptExisting makes X.PNG.enc of X.PNG; it loads and needs decrypting like any other.
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        try png.write(to: shots.appendingPathComponent("X.PNG"))
        XCTAssertEqual(try EvalScreenshots.encryptExisting(in: shots, caseFiles: [], cipher: cipher), 1)
        let sealed = shots.appendingPathComponent("X.PNG.enc").path
        XCTAssertTrue(EvalScreenshots.needsDecrypting(sealed))
        XCTAssertEqual(try EvalScreenshots.load(sealed, cipher: cipher), png)
        XCTAssertEqual(try EvalScreenshots.encryptExisting(in: shots, caseFiles: [], cipher: cipher), 0, "not encrypted twice")
    }

    /// Decrypted copies a killed eval run left behind are deleted at launch, but not a running one's
    /// (recent), and nothing else.
    func testLeftoverDecryptedCopiesAreRemoved() throws {
        let fm = FileManager.default
        let caseDir = dir.appendingPathComponent("runs/r1/cases/001-a/agent")
        try fm.createDirectory(at: caseDir, withIntermediateDirectories: true)
        let old = caseDir.appendingPathComponent("screenshot-0a1b2c3d.png")
        let recent = caseDir.appendingPathComponent("screenshot-99999999.png")
        let other = caseDir.appendingPathComponent("screenshot-notes.png")
        let report = dir.appendingPathComponent("runs/r1/report.html")
        for url in [old, recent, other, report] { try png.write(to: url) }
        let now = Date()
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-7200)], ofItemAtPath: old.path)
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-7200)], ofItemAtPath: other.path)
        XCTAssertEqual(EvalScreenshots.removeTemporaryCopies(under: dir.appendingPathComponent("runs"), now: now), 1)
        XCTAssertFalse(fm.fileExists(atPath: old.path))
        XCTAssertTrue(fm.fileExists(atPath: recent.path), "may belong to a run in progress")
        XCTAssertTrue(fm.fileExists(atPath: other.path))
        XCTAssertTrue(fm.fileExists(atPath: report.path))
        XCTAssertEqual(EvalScreenshots.removeTemporaryCopies(under: dir.appendingPathComponent("missing")), 0)
    }

    func testSaveEncryptsAndLoadDecrypts() throws {
        let path = try EvalScreenshots.save(png, id: "my-case", in: shots, cipher: cipher)
        XCTAssertTrue(path.hasSuffix("/my-case.png.enc"))
        let onDisk = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertNil(onDisk.range(of: Data("tax form".utf8)))
        XCTAssertEqual(OwnerOnly.mode(path), 0o600)
        XCTAssertEqual(try EvalScreenshots.load(path, cipher: cipher), png)
        XCTAssertThrowsError(try EvalScreenshots.load(path, cipher: DataCipher(store: InMemoryKeyStore(key: Data(repeating: 3, count: 32)))))
    }

    func testWithoutEncryptionScreenshotsArePlainOwnerOnlyFiles() throws {
        let path = try EvalScreenshots.save(png, id: "my-case", in: shots, cipher: nil)
        XCTAssertTrue(path.hasSuffix("/my-case.png"))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), png)
        XCTAssertEqual(OwnerOnly.mode(path), 0o600)
        XCTAssertEqual(try EvalScreenshots.load(path, cipher: nil), png)
        let file = try EvalScreenshots.materialize(path, in: dir, cipher: nil)
        XCTAssertFalse(file.isTemporary)
    }

    /// A build without encryption can't open another build's encrypted screenshot, and leaves it be.
    func testWithoutEncryptionEncryptedScreenshotsAreReportedAndKept() throws {
        let path = try EvalScreenshots.save(png, id: "c", in: shots, cipher: cipher)
        let before = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertThrowsError(try EvalScreenshots.load(path, cipher: nil)) {
            XCTAssertEqual($0 as? DataCipher.CipherError, .encryptionOff)
        }
        XCTAssertThrowsError(try EvalScreenshots.materialize(path, in: dir, cipher: nil))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), before)
    }

    func testPlainScreenshotsAreUsedAsTheyAre() throws {
        let plain = dir.appendingPathComponent("fixture.png")
        try png.write(to: plain)
        XCTAssertEqual(try EvalScreenshots.load(plain.path, cipher: cipher), png)
        let file = try EvalScreenshots.materialize(plain.path, in: dir, cipher: cipher)
        XCTAssertEqual(file.url.path, plain.path)
        XCTAssertFalse(file.isTemporary)
    }

    func testMaterializeWritesATemporaryOwnerOnlyCopy() throws {
        let path = try EvalScreenshots.save(png, id: "c", in: shots, cipher: cipher)
        let work = dir.appendingPathComponent("runs/x/cases/001-c")
        let file = try EvalScreenshots.materialize(path, in: work, cipher: cipher)
        XCTAssertTrue(file.isTemporary)
        XCTAssertTrue(file.url.path.hasPrefix(work.path + "/"))
        XCTAssertEqual(try Data(contentsOf: file.url), png)
        XCTAssertEqual(OwnerOnly.mode(file.url.path), 0o600)
    }

    func testEncryptExistingMigratesFilesAndReferences() throws {
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        let old = shots.appendingPathComponent("lease-20261101.png")
        let orphan = shots.appendingPathComponent("orphan.png")
        try png.write(to: old)
        try png.write(to: orphan)
        let cases = dir.appendingPathComponent("cases.jsonl")
        let drafts = dir.appendingPathComponent("drafts.jsonl")
        let c = EvalCase(id: "lease", query: ["lease"], context: EvalCase.Context(app: "Safari", screenshot: old.path),
                         expect: Expectation(anyOf: ["/x"]))
        let other = EvalCase(id: "other", query: ["q"], expect: Expectation(anyOf: ["/y"]))
        try EvalCaseFile.append(c, to: cases)
        try EvalCaseFile.append(other, to: cases)

        XCTAssertEqual(try EvalScreenshots.encryptExisting(in: shots, caseFiles: [cases, drafts], cipher: cipher), 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: shots.path)),
                       ["lease-20261101.png.enc", "orphan.png.enc"])
        let loaded = try EvalCaseFile.load(cases).cases
        XCTAssertEqual(loaded.map(\.id), ["lease", "other"])
        XCTAssertEqual(loaded[0].context?.screenshot, old.path + ".enc")
        XCTAssertEqual(try EvalScreenshots.load(loaded[0].context!.screenshot!, cipher: cipher), png)
        // A reference that still says .png (a file that couldn't be updated) finds the .png.enc.
        XCTAssertTrue(EvalScreenshots.needsDecrypting(old.path))
        XCTAssertEqual(try EvalScreenshots.load(old.path, cipher: cipher), png)
        XCTAssertEqual(try EvalScreenshots.encryptExisting(in: shots, caseFiles: [cases], cipher: cipher), 0)
    }

    func testCaseFilesAreOwnerOnly() throws {
        let cases = dir.appendingPathComponent("new/cases.jsonl")
        try EvalCaseFile.append(EvalCase(id: "a", query: ["q"], expect: Expectation(anyOf: ["/x"])), to: cases)
        XCTAssertEqual(OwnerOnly.mode(cases.path), 0o600)
        XCTAssertEqual(OwnerOnly.mode(cases.deletingLastPathComponent().path), 0o700)
        try EvalCaseFile.replace(id: "a", with: nil, in: cases)
        XCTAssertEqual(OwnerOnly.mode(cases.path), 0o600)
    }
}
