import CryptoKit
import Foundation
import XCTest
@testable import LikelyStorage

/// A fresh temporary folder per test (never the real ~/Library/Application Support/Likely).
class TempDirTestCase: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("likely-storage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func mode(_ url: URL) -> mode_t? { OwnerOnly.mode(url.path) }
}

final class OwnerOnlyTests: TempDirTestCase {
    func testCreateDirectoryMakesEveryNewLevel0700() throws {
        let nested = dir.appendingPathComponent("a/b/c")
        try OwnerOnly.createDirectory(nested)
        for path in ["a", "a/b", "a/b/c"] { XCTAssertEqual(mode(dir.appendingPathComponent(path)), 0o700, path) }
        try OwnerOnly.createDirectory(nested)   // existing: fine
    }

    func testCreateDirectoryRefusesAFile() throws {
        let file = dir.appendingPathComponent("f")
        try OwnerOnly.write(Data("x".utf8), to: file)
        XCTAssertThrowsError(try OwnerOnly.createDirectory(file.appendingPathComponent("sub")))
    }

    func testWriteIsAtomicAndOwnerOnly() throws {
        let url = dir.appendingPathComponent("new/file.json")
        try OwnerOnly.write(Data("one".utf8), to: url)
        XCTAssertEqual(mode(url), 0o600)
        XCTAssertEqual(mode(url.deletingLastPathComponent()), 0o700)
        // Replacing a 0644 file leaves a 0600 one, and no temporary files behind.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        try OwnerOnly.write("two", to: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "two")
        XCTAssertEqual(mode(url), 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path), ["file.json"])
    }

    func testWriteNeverPassesThrough0644EvenWithPermissiveUmask() throws {
        let old = umask(0)
        defer { umask(old) }
        let url = dir.appendingPathComponent("u/file")
        try OwnerOnly.write(Data("x".utf8), to: url)
        XCTAssertEqual(mode(url), 0o600)
        XCTAssertEqual(mode(url.deletingLastPathComponent()), 0o700)
    }

    func testExecutableMode() throws {
        let url = dir.appendingPathComponent("bin/stub")
        try OwnerOnly.write(Data("#!/bin/sh\n".utf8), to: url, mode: OwnerOnly.executableMode)
        XCTAssertEqual(mode(url), 0o700)
    }

    func testOpenForWritingAppendsAndTruncates() throws {
        let url = dir.appendingPathComponent("logs/likely.log")
        var handle = try OwnerOnly.openForWriting(url, truncate: false)
        handle.write(Data("a\n".utf8))
        try handle.close()
        handle = try OwnerOnly.openForWriting(url, truncate: false)
        handle.write(Data("b\n".utf8))
        try handle.close()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "a\nb\n")
        XCTAssertEqual(mode(url), 0o600)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        handle = try OwnerOnly.openForWriting(url, truncate: true)
        handle.write(Data("c".utf8))
        try handle.close()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "c")
        XCTAssertEqual(mode(url), 0o600, "an existing wider file is narrowed")
    }

    func testCreateExclusiveNeverTruncates() throws {
        let url = dir.appendingPathComponent("cases.jsonl")
        XCTAssertTrue(try OwnerOnly.createExclusive(url))
        XCTAssertEqual(mode(url), 0o600)
        try Data("keep".utf8).write(to: url)
        XCTAssertFalse(try OwnerOnly.createExclusive(url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "keep")
    }

    func testRepairNarrowsEverythingButFollowsNoLinks() throws {
        let fm = FileManager.default
        let root = dir.appendingPathComponent("Likely")
        let outside = dir.appendingPathComponent("outside.txt")
        try fm.createDirectory(at: root.appendingPathComponent("evals/screenshots"), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o755])
        fm.createFile(atPath: root.appendingPathComponent("tools.json").path, contents: Data(), attributes: [.posixPermissions: 0o644])
        fm.createFile(atPath: root.appendingPathComponent("evals/screenshots/a.png").path, contents: Data(), attributes: [.posixPermissions: 0o666])
        fm.createFile(atPath: root.appendingPathComponent("stub").path, contents: Data(), attributes: [.posixPermissions: 0o755])
        fm.createFile(atPath: outside.path, contents: Data(), attributes: [.posixPermissions: 0o644])
        try fm.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)

        XCTAssertGreaterThan(OwnerOnly.repair(root), 0)
        XCTAssertEqual(mode(root), 0o700)
        XCTAssertEqual(mode(root.appendingPathComponent("evals")), 0o700)
        XCTAssertEqual(mode(root.appendingPathComponent("evals/screenshots")), 0o700)
        XCTAssertEqual(mode(root.appendingPathComponent("tools.json")), 0o600)
        XCTAssertEqual(mode(root.appendingPathComponent("evals/screenshots/a.png")), 0o600)
        XCTAssertEqual(mode(root.appendingPathComponent("stub")), 0o700)
        XCTAssertEqual(mode(outside), 0o644, "a link's target outside the folder is left alone")
        XCTAssertEqual(OwnerOnly.repair(root), 0, "nothing left to fix")
    }

    func testRepairFollowsALinkedRoot() throws {
        let real = dir.appendingPathComponent("Likely.noindex")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("Likely").path, withDestinationPath: "Likely.noindex")
        OwnerOnly.repair(dir.appendingPathComponent("Likely"))
        XCTAssertEqual(mode(real), 0o700)
    }
}

final class DataCipherTests: XCTestCase {
    func testLineRoundTrip() throws {
        let store = InMemoryKeyStore()
        let cipher = DataCipher(store: store)
        let text = #"{"id":"a","queries":["my lease x"]}"#
        let line = try cipher.sealLine(text)
        XCTAssertTrue(line.hasPrefix("lk1:"))
        XCTAssertFalse(line.contains("\n"))
        XCTAssertFalse(line.contains("lease"))
        XCTAssertEqual(try cipher.openLine(line), text)
        XCTAssertEqual(store.key?.count, 32, "a 256-bit key was made on first use")
        // Each seal uses a fresh nonce.
        XCTAssertNotEqual(try cipher.sealLine(text), line)
        // A new cipher with the same stored key reads it.
        XCTAssertEqual(try DataCipher(store: store).openLine(line), text)
    }

    func testFileRoundTrip() throws {
        let cipher = DataCipher(store: InMemoryKeyStore())
        let png = Data([0x89, 0x50, 0x4E, 0x47] + (0..<5000).map { UInt8($0 % 251) })
        let sealed = try cipher.sealFile(png)
        XCTAssertTrue(DataCipher.isSealedFile(sealed))
        XCTAssertNil(sealed.range(of: png.prefix(64)))
        XCTAssertEqual(try cipher.openFile(sealed), png)
    }

    func testOtherKeyIsReportedAsSuch() throws {
        let line = try DataCipher(store: InMemoryKeyStore()).sealLine("secret")
        let file = try DataCipher(store: InMemoryKeyStore()).sealFile(Data("png".utf8))
        let other = DataCipher(store: InMemoryKeyStore(key: Data(repeating: 7, count: 32)))
        XCTAssertThrowsError(try other.openLine(line)) { XCTAssertEqual($0 as? DataCipher.CipherError, .otherKey) }
        XCTAssertThrowsError(try other.openFile(file)) { XCTAssertEqual($0 as? DataCipher.CipherError, .otherKey) }
    }

    func testTamperingAndWrongPurposeAreDamaged() throws {
        let cipher = DataCipher(store: InMemoryKeyStore())
        let line = try cipher.sealLine("secret")
        var bytes = Array(line)
        let i = bytes.count - 5
        bytes[i] = bytes[i] == "A" ? "B" : "A"
        XCTAssertThrowsError(try cipher.openLine(String(bytes))) { XCTAssertEqual($0 as? DataCipher.CipherError, .damaged) }
        XCTAssertThrowsError(try cipher.openLine("lk1:zz:notbase64")) { XCTAssertEqual($0 as? DataCipher.CipherError, .damaged) }
        XCTAssertThrowsError(try cipher.openLine("plain text"))
        // A history line can't be opened as a screenshot or the other way round.
        XCTAssertThrowsError(try cipher.openLine(line, purpose: .screenshot)) { XCTAssertEqual($0 as? DataCipher.CipherError, .damaged) }
        let file = try cipher.sealFile(Data("x".utf8), purpose: .screenshot)
        XCTAssertThrowsError(try cipher.openFile(file, purpose: .historyLine))
        XCTAssertThrowsError(try cipher.openFile(Data("LKE1".utf8)))
    }

    func testReadingNeverMakesAKey() throws {
        let store = InMemoryKeyStore()
        let line = try DataCipher(store: InMemoryKeyStore()).sealLine("x")
        let cipher = DataCipher(store: store)
        XCTAssertFalse(cipher.hasKey)
        XCTAssertThrowsError(try cipher.openLine(line)) { XCTAssertEqual($0 as? DataCipher.CipherError, .otherKey) }
        XCTAssertNil(store.key)
    }

    func testUnreadableKeyIsNeverReplaced() throws {
        struct Locked: Error {}
        let store = InMemoryKeyStore(key: Data(repeating: 1, count: 32))
        store.failure = Locked()
        let cipher = DataCipher(store: store)
        XCTAssertThrowsError(try cipher.sealLine("x")) {
            guard case .keyUnavailable = $0 as? DataCipher.CipherError else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(store.key, Data(repeating: 1, count: 32), "the existing key wasn't overwritten")
        // Once the store can be read again, the same key is used.
        store.failure = nil
        let line = try cipher.sealLine("x")
        XCTAssertEqual(try DataCipher(store: InMemoryKeyStore(key: Data(repeating: 1, count: 32))).openLine(line), "x")
    }

    func testWrongSizeKeyIsRefused() {
        let cipher = DataCipher(store: InMemoryKeyStore(key: Data(repeating: 1, count: 16)))
        XCTAssertThrowsError(try cipher.sealLine("x"))
    }
}

final class SpotlightExclusionTests: TempDirTestCase {
    func testMovesAFolderAndLinksIt() throws {
        let folder = dir.appendingPathComponent("Likely")
        try OwnerOnly.write("{}", to: folder.appendingPathComponent("tools.json"))
        XCTAssertEqual(try SpotlightExclusion.exclude(folder), .excluded)
        let real = dir.appendingPathComponent("Likely.noindex")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: folder.path), "Likely.noindex")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("tools.json"), encoding: .utf8), "{}")
        XCTAssertTrue(FileManager.default.fileExists(atPath: real.appendingPathComponent("tools.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: real.appendingPathComponent(".metadata_never_index").path))
        XCTAssertEqual(try SpotlightExclusion.exclude(folder), .alreadyExcluded)
    }

    func testCreatesItWhenMissing() throws {
        let folder = dir.appendingPathComponent("Logs/Likely")
        XCTAssertEqual(try SpotlightExclusion.exclude(folder), .excluded)
        XCTAssertEqual(OwnerOnly.mode(dir.appendingPathComponent("Logs/Likely.noindex").path), 0o700)
        try OwnerOnly.createDirectory(folder.appendingPathComponent("sub"))   // through the link
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Logs/Likely.noindex/sub").path))
    }

    func testLeavesConflictsAndForeignLinksAlone() throws {
        let folder = dir.appendingPathComponent("Likely")
        try OwnerOnly.createDirectory(folder)
        try OwnerOnly.createDirectory(dir.appendingPathComponent("Likely.noindex"))
        guard case .skipped = try SpotlightExclusion.exclude(folder) else { return XCTFail() }
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir) && isDir.boolValue)

        let other = dir.appendingPathComponent("Other")
        try FileManager.default.createSymbolicLink(atPath: other.path, withDestinationPath: "/tmp")
        guard case .skipped = try SpotlightExclusion.exclude(other) else { return XCTFail() }
    }
}
