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

    func testSaveEncryptsAndLoadDecrypts() throws {
        let path = try EvalScreenshots.save(png, id: "my-case", in: shots, cipher: cipher)
        XCTAssertTrue(path.hasSuffix("/my-case.png.enc"))
        let onDisk = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertNil(onDisk.range(of: Data("tax form".utf8)))
        XCTAssertEqual(OwnerOnly.mode(path), 0o600)
        XCTAssertEqual(try EvalScreenshots.load(path, cipher: cipher), png)
        XCTAssertThrowsError(try EvalScreenshots.load(path, cipher: DataCipher(store: InMemoryKeyStore(key: Data(repeating: 3, count: 32)))))
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
