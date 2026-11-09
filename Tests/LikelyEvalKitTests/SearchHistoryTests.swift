import Foundation
import XCTest
@testable import LikelyEvalKit
import LikelyStorage

final class SearchHistoryTests: XCTestCase {
    private var dir: URL!
    /// An in-memory key: tests never touch the Keychain.
    private var cipher = DataCipher(store: InMemoryKeyStore())
    private var url: URL { dir.appendingPathComponent("history.jsonl") }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("likely-history-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func entry(_ id: String, queries: [String] = ["q"], suggested: [String] = [], picked: [String] = []) -> SearchHistoryEntry {
        SearchHistoryEntry(id: id, date: "2026-11-06T10:00:00Z", app: "Safari", windowTitle: "Upload", button: "Open",
                           queries: queries, suggested: suggested, picked: picked, outcome: "confirmed with Return")
    }

    func testAppendAndLoadRoundTrip() throws {
        XCTAssertEqual(try SearchHistoryFile.load(url, cipher: cipher), [])   // no file yet
        let a = entry("a", queries: ["my lease", "the signed one"], suggested: ["/d/lease.pdf"], picked: ["/d/lease-signed.pdf"])
        try SearchHistoryFile.append(a, to: url, cipher: cipher)
        try SearchHistoryFile.append(entry("b"), to: url, cipher: cipher)
        let loaded = try SearchHistoryFile.load(url, cipher: cipher)
        XCTAssertEqual(loaded.map(\.id), ["a", "b"])
        XCTAssertEqual(loaded[0], a)
        XCTAssertTrue(loaded[0].wasPicked)
        XCTAssertNotNil(loaded[0].timestamp)
        XCTAssertFalse(SearchHistoryFile.encodeLine(a).contains("\\/"), "paths are written without escaped slashes")
    }

    func testAppendCapsToLimitDroppingOldest() throws {
        for i in 0..<12 { try SearchHistoryFile.append(entry("e\(i)"), to: url, cipher: cipher, limit: 5) }
        XCTAssertEqual(try SearchHistoryFile.load(url, cipher: cipher).map(\.id), ["e7", "e8", "e9", "e10", "e11"])
    }

    func testClear() throws {
        try SearchHistoryFile.append(entry("a"), to: url, cipher: cipher)
        try SearchHistoryFile.clear(url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try SearchHistoryFile.load(url, cipher: cipher), [])
        try SearchHistoryFile.clear(url)   // clearing nothing is fine
    }

    func testDecodeTolerance() {
        let text = """
        {"id":"full","date":"2026-11-06T10:00:00Z","app":"Mail","queries":["a","b"],"suggested":["/x"],"picked":["/x"]}
        not json

        {"id":"minimal"}
        {"id":"single-query","queries":"just one","future":{"field":true},"picked":"not-an-array"}
        {"app":"no id"}
        """
        let entries = SearchHistoryFile.parse(text)
        XCTAssertEqual(entries.map(\.id), ["full", "minimal", "single-query"])
        XCTAssertEqual(entries[0].queries, ["a", "b"])
        XCTAssertEqual(entries[1].queries, [])
        XCTAssertEqual(entries[1].app, "")
        XCTAssertNil(entries[1].timestamp)
        XCTAssertEqual(entries[2].queries, ["just one"])
        XCTAssertEqual(entries[2].picked, [])
    }

    func testUpdateMarksEvalAndKeepsUnreadableLines() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "garbage line\n".write(to: url, atomically: true, encoding: .utf8)
        try SearchHistoryFile.append(entry("a"), to: url, cipher: cipher)
        try SearchHistoryFile.append(entry("b"), to: url, cipher: cipher)
        let updated = try SearchHistoryFile.update(id: "a", in: url, cipher: cipher) { $0.evalCaseID = "my-case" }
        XCTAssertEqual(updated?.evalCaseID, "my-case")
        XCTAssertNil(try SearchHistoryFile.update(id: "missing", in: url, cipher: cipher) { $0.evalCaseID = "x" })
        let loaded = try SearchHistoryFile.load(url, cipher: cipher)
        XCTAssertEqual(loaded.map(\.id), ["a", "b"])
        XCTAssertTrue(loaded[0].hasEval)
        XCTAssertFalse(loaded[1].hasEval)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).hasPrefix("garbage line\n"))
    }

    // MARK: Review fixes

    func testUnreadableFileThrowsAndIsNotOverwritten() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Not valid UTF-8: reading fails, so neither append nor update may replace the file.
        let bad = Data([0x7B, 0x22, 0x69, 0x64, 0x22, 0xFF, 0xFE, 0x0A])
        try bad.write(to: url)
        XCTAssertThrowsError(try SearchHistoryFile.load(url, cipher: cipher))
        XCTAssertThrowsError(try SearchHistoryFile.append(entry("a"), to: url, cipher: cipher))
        XCTAssertThrowsError(try SearchHistoryFile.update(id: "a", in: url, cipher: cipher) { $0.evalCaseID = "x" })
        XCTAssertEqual(try Data(contentsOf: url), bad)
    }

    func testFileAndFolderAreOwnerOnly() throws {
        let nested = dir.appendingPathComponent("History/history.jsonl")
        try SearchHistoryFile.append(entry("a"), to: nested, cipher: cipher)
        let fileMode = try FileManager.default.attributesOfItem(atPath: nested.path)[.posixPermissions] as? Int
        let dirMode = try FileManager.default.attributesOfItem(atPath: nested.deletingLastPathComponent().path)[.posixPermissions] as? Int
        XCTAssertEqual(fileMode, 0o600)
        XCTAssertEqual(dirMode, 0o700)
        try SearchHistoryFile.update(id: "a", in: nested, cipher: cipher) { $0.evalCaseID = "c" }
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: nested.path)[.posixPermissions] as? Int, 0o600)
    }

    func testMigrateMovesLegacyFileOnce() throws {
        let legacy = dir.appendingPathComponent("history.jsonl")
        let moved = dir.appendingPathComponent("History/history.jsonl")
        try SearchHistoryFile.append(entry("old"), to: legacy, cipher: cipher)
        try SearchHistoryFile.migrate(from: legacy, to: moved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertEqual(try SearchHistoryFile.load(moved, cipher: cipher).map(\.id), ["old"])
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: moved.path)[.posixPermissions] as? Int, 0o600)
        // Never overwrites an existing file at the new location.
        try SearchHistoryFile.append(entry("stray"), to: legacy, cipher: cipher)
        try SearchHistoryFile.migrate(from: legacy, to: moved)
        XCTAssertEqual(try SearchHistoryFile.load(moved, cipher: cipher).map(\.id), ["old"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testDefaultLocationIsItsOwnFolder() {
        XCTAssertEqual(SearchHistoryFile.plaintextURL.deletingLastPathComponent(), SearchHistoryFile.defaultDirectory)
        XCTAssertEqual(SearchHistoryFile.defaultDirectory.lastPathComponent, "History")
        XCTAssertEqual(SearchHistoryFile.legacyURL.deletingLastPathComponent().standardizedFileURL,
                       SearchHistoryFile.defaultDirectory.deletingLastPathComponent().standardizedFileURL)
    }

    /// JSONEncoder leaves U+2028, U+2029 and U+0085 unescaped; they must not split an entry.
    func testUnicodeLineSeparatorsInsideEntriesSurvive() throws {
        let weird = "a\u{2028}b\u{2029}c\u{0085}d\u{000B}e\u{000C}f"
        let e = entry("w", queries: [weird], suggested: ["/d/x\u{2028}y.pdf"])
        XCTAssertTrue(SearchHistoryFile.encodeLine(e).contains("\u{2028}"), "precondition: the encoder writes it raw")
        try SearchHistoryFile.append(e, to: url, cipher: cipher)
        try SearchHistoryFile.append(entry("next"), to: url, cipher: cipher)
        try SearchHistoryFile.update(id: "w", in: url, cipher: cipher) { $0.evalCaseID = "case" }
        let loaded = try SearchHistoryFile.load(url, cipher: cipher)
        XCTAssertEqual(loaded.map(\.id), ["w", "next"])
        XCTAssertEqual(loaded[0].queries, [weird])
        XCTAssertEqual(loaded[0].suggested, ["/d/x\u{2028}y.pdf"])
        XCTAssertEqual(loaded[0].evalCaseID, "case")
    }

    func testCRLFLinesParse() {
        let text = "{\"id\":\"a\"}\r\n{\"id\":\"b\"}\r\n\r\n"
        XCTAssertEqual(SearchHistoryFile.parse(text).map(\.id), ["a", "b"])
    }

    func testEvalCaseFileKeepsUnicodeSeparatorsInsideLines() throws {
        let c = EvalCase(id: "sep", query: ["first\u{2028}second\u{0085}third"], expect: Expectation(anyOf: ["/x\u{2029}y"]))
        XCTAssertTrue(EvalCaseFile.encodeLine(c).contains("\u{2028}"), "precondition: the encoder writes it raw")
        let text = "# header\r\n" + EvalCaseFile.encodeLine(c) + "\r\nnot json\n"
        let (cases, errors) = EvalCaseFile.parse(text)
        XCTAssertEqual(cases, [c])
        XCTAssertEqual(errors.map(\.line), [3], "line numbers count \\n only")
        XCTAssertEqual(EvalCaseFile.splitLines("a\r\nb\u{2028}c\nd"), ["a", "b\u{2028}c", "d"])
    }

    // MARK: Encryption

    func testLinesAreEncryptedOnDisk() throws {
        try SearchHistoryFile.append(entry("a", queries: ["my tax form"], suggested: ["/Users/me/K-1.pdf"]), to: url, cipher: cipher)
        try SearchHistoryFile.append(entry("b"), to: url, cipher: cipher)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("tax"))
        XCTAssertFalse(text.contains("K-1"))
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines.allSatisfy { $0.hasPrefix(DataCipher.linePrefix) })
        XCTAssertEqual(try SearchHistoryFile.load(url, cipher: DataCipher(store: InMemoryKeyStore())).count, 0,
                       "another key reads nothing")
    }

    private var plainURL: URL { dir.appendingPathComponent("history.jsonl") }
    private var encURL: URL { dir.appendingPathComponent("history.enc.jsonl") }

    func testConvertsPlaintextHistoryIntoTheEncryptedFile() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let old = SearchHistoryFile.encodeLine(entry("old1", queries: ["lease"])) + "\n"
            + "not json but kept\n"
            + SearchHistoryFile.encodeLine(entry("old2")) + "\n"
        try old.write(to: plainURL, atomically: true, encoding: .utf8)
        try SearchHistoryFile.append(entry("enc0"), to: encURL, cipher: cipher)
        XCTAssertEqual(try SearchHistoryFile.convertPlaintext(from: plainURL, to: encURL, cipher: cipher), 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plainURL.path), "nothing left in plaintext")
        let text = try String(contentsOf: encURL, encoding: .utf8)
        XCTAssertFalse(text.contains("lease"))
        XCTAssertFalse(text.contains("kept"))
        XCTAssertEqual(try SearchHistoryFile.load(encURL, cipher: cipher).map(\.id), ["enc0", "old1", "old2"])
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: encURL.path)[.posixPermissions] as? Int, 0o600)
        // Only once.
        let before = try Data(contentsOf: encURL)
        XCTAssertEqual(try SearchHistoryFile.convertPlaintext(from: plainURL, to: encURL, cipher: cipher), 0)
        XCTAssertEqual(try Data(contentsOf: encURL), before)
        try SearchHistoryFile.append(entry("new"), to: encURL, cipher: cipher)
        XCTAssertEqual(try SearchHistoryFile.load(encURL, cipher: cipher).map(\.id), ["enc0", "old1", "old2", "new"])
    }

    func testConversionThatStoppedHalfWayAddsNothingTwice() throws {
        try SearchHistoryFile.append(entry("a"), to: plainURL, cipher: nil)
        try SearchHistoryFile.append(entry("b"), to: plainURL, cipher: nil)
        // As if the encrypted file was written but the plaintext one not yet removed.
        try SearchHistoryFile.append(entry("a"), to: encURL, cipher: cipher)
        try SearchHistoryFile.convertPlaintext(from: plainURL, to: encURL, cipher: cipher)
        XCTAssertEqual(try SearchHistoryFile.load(encURL, cipher: cipher).map(\.id), ["a", "b"])
    }

    /// Lines sealed by an earlier test build (in history.jsonl) aren't converted or dropped.
    func testConversionLeavesOtherEncryptedLinesInThePlaintextFile() throws {
        let earlier = DataCipher(store: InMemoryKeyStore())
        try SearchHistoryFile.append(entry("sealed-earlier"), to: plainURL, cipher: earlier)
        try SearchHistoryFile.append(entry("plain"), to: plainURL, cipher: nil)
        XCTAssertEqual(try SearchHistoryFile.convertPlaintext(from: plainURL, to: encURL, cipher: cipher), 1)
        XCTAssertEqual(try SearchHistoryFile.load(encURL, cipher: cipher).map(\.id), ["plain"])
        XCTAssertEqual(try SearchHistoryFile.load(plainURL, cipher: earlier).map(\.id), ["sealed-earlier"])
        XCTAssertEqual(try SearchHistoryFile.read(plainURL, cipher: nil).unreadable, 1)
    }

    func testConversionWithoutAKeyLeavesBothFilesAlone() throws {
        struct NoKeychain: Error {}
        try SearchHistoryFile.append(entry("old"), to: plainURL, cipher: nil)
        let before = try Data(contentsOf: plainURL)
        let store = InMemoryKeyStore()
        store.failure = NoKeychain()
        let broken = DataCipher(store: store)
        XCTAssertThrowsError(try SearchHistoryFile.convertPlaintext(from: plainURL, to: encURL, cipher: broken))
        XCTAssertThrowsError(try SearchHistoryFile.append(entry("x"), to: encURL, cipher: broken), "never written in plaintext")
        XCTAssertEqual(try Data(contentsOf: plainURL), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: encURL.path))
    }

    func testNoPlaintextMeansNoConversionAndNoFiles() throws {
        XCTAssertEqual(try SearchHistoryFile.convertPlaintext(from: plainURL, to: encURL, cipher: cipher), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: encURL.path))
    }

    // MARK: Without encryption

    func testWithoutEncryptionHistoryIsPlainJSONLines() throws {
        try SearchHistoryFile.append(entry("a", queries: ["my lease"]), to: plainURL, cipher: nil)
        try SearchHistoryFile.update(id: "a", in: plainURL, cipher: nil) { $0.evalCaseID = "c" }
        let text = try String(contentsOf: plainURL, encoding: .utf8)
        XCTAssertTrue(text.contains("my lease"))
        XCTAssertFalse(text.contains(DataCipher.linePrefix))
        XCTAssertEqual(SearchHistoryFile.parse(text).map(\.evalCaseID), ["c"])
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: plainURL.path)[.posixPermissions] as? Int, 0o600)
    }

    /// A build without encryption can't read encrypted lines: reported, kept, never rewritten as plaintext.
    func testWithoutEncryptionEncryptedLinesAreReportedAndKept() throws {
        try SearchHistoryFile.append(entry("secret"), to: encURL, cipher: cipher)
        let before = try Data(contentsOf: encURL)
        let contents = try SearchHistoryFile.read(encURL, cipher: nil)
        XCTAssertEqual(contents.entries, [])
        XCTAssertEqual(contents.unreadable, 1)
        XCTAssertEqual(contents.problem, .encryptionOff)
        XCTAssertNil(try SearchHistoryFile.update(id: "secret", in: encURL, cipher: nil) { $0.evalCaseID = "x" })
        XCTAssertEqual(try Data(contentsOf: encURL), before)
    }

    func testEncryptedAndPlaintextFilesAreSeparate() {
        XCTAssertEqual(SearchHistoryFile.url(encrypted: true, in: dir).lastPathComponent, "history.enc.jsonl")
        XCTAssertEqual(SearchHistoryFile.url(encrypted: false, in: dir).lastPathComponent, "history.jsonl")
        XCTAssertEqual(SearchHistoryFile.encryptedURL.deletingLastPathComponent(), SearchHistoryFile.defaultDirectory)
        XCTAssertEqual(SearchHistoryFile.plaintextURL.deletingLastPathComponent(), SearchHistoryFile.defaultDirectory)
    }

    /// Builds with different keys (e.g. signed by different teams): neither wipes the other's lines.
    func testAnotherBuildsLinesAreKeptAndReported() throws {
        let release = DataCipher(store: InMemoryKeyStore())
        let dev = DataCipher(store: InMemoryKeyStore())
        try SearchHistoryFile.append(entry("r1"), to: url, cipher: release)
        try SearchHistoryFile.append(entry("r2"), to: url, cipher: release)

        let seenByDev = try SearchHistoryFile.read(url, cipher: dev)
        XCTAssertEqual(seenByDev.entries, [])
        XCTAssertEqual(seenByDev.unreadable, 2)
        XCTAssertEqual(seenByDev.problem, .otherKey)

        try SearchHistoryFile.append(entry("d1"), to: url, cipher: dev)
        XCTAssertNil(try SearchHistoryFile.update(id: "r1", in: url, cipher: dev) { $0.evalCaseID = "x" })
        XCTAssertNotNil(try SearchHistoryFile.update(id: "d1", in: url, cipher: dev) { $0.evalCaseID = "x" })
        XCTAssertEqual(try SearchHistoryFile.load(url, cipher: release).map(\.id), ["r1", "r2"])
        XCTAssertEqual(try SearchHistoryFile.load(url, cipher: dev).map(\.id), ["d1"])
        XCTAssertEqual(try SearchHistoryFile.read(url, cipher: release).unreadable, 1)
    }

    func testMissingKeyReadsAsUnreadableNotEmpty() throws {
        try SearchHistoryFile.append(entry("a"), to: url, cipher: cipher)
        let noKey = DataCipher(store: InMemoryKeyStore())
        let contents = try SearchHistoryFile.read(url, cipher: noKey)
        XCTAssertEqual(contents.unreadable, 1)
        XCTAssertEqual(contents.problem, .otherKey)
    }

    func testDamagedLineIsSkippedAndKept() throws {
        try SearchHistoryFile.append(entry("a"), to: url, cipher: cipher)
        var text = try String(contentsOf: url, encoding: .utf8)
        text += "lk1:00000000:AAAA\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
        try SearchHistoryFile.append(entry("b"), to: url, cipher: cipher)
        let contents = try SearchHistoryFile.read(url, cipher: cipher)
        XCTAssertEqual(contents.entries.map(\.id), ["a", "b"])
        XCTAssertEqual(contents.unreadable, 1)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("lk1:00000000:AAAA\n"))
    }

    func testSharedDateFormatter() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let e = SearchHistoryEntry(id: "d", date: SearchHistoryEntry.dateFormatter.string(from: date), app: "A", queries: [], suggested: [])
        XCTAssertEqual(e.timestamp, date)
    }

    func testCandidatesPickFirstWithoutDuplicates() {
        let e = entry("a", suggested: ["/d/a.pdf", "/d/B.pdf", "/d/c.pdf"], picked: ["/d/b.pdf"])
        XCTAssertEqual(e.candidates, ["/d/b.pdf", "/d/a.pdf", "/d/c.pdf"])
    }

    func testMakeCaseAnyOf() throws {
        let e = entry("a", queries: ["my lease"], suggested: ["/Users/me/Docs/lease.pdf", "/Users/me/x.pdf"], picked: ["/Users/me/Docs/lease.pdf"])
        let existing = [EvalCase(id: "my-lease", query: ["old"], expect: Expectation(anyOf: ["/z"]))]
        let c = e.makeCase(queries: ["my lease"], expected: ["/Users/me/Docs/lease.pdf", "/elsewhere/lease.pdf"], kind: .anyOf,
                           existing: existing, home: "/Users/me")
        XCTAssertEqual(c.id, "my-lease-2")
        XCTAssertEqual(c.query, ["my lease"])
        XCTAssertEqual(c.source, "history")
        XCTAssertEqual(c.tags, ["history"])
        XCTAssertEqual(c.expect.kind, .anyOf)
        XCTAssertEqual(c.expect.paths, ["~/Docs/lease.pdf", "/elsewhere/lease.pdf"])
        XCTAssertEqual(c.context?.app, "Safari")
        XCTAssertEqual(c.context?.windowTitle, "Upload")
        XCTAssertEqual(c.context?.button, "Open")
        XCTAssertNil(c.context?.screenshot)
        XCTAssertTrue(c.notes?.contains("including an expected one") == true, c.notes ?? "")
        // Survives the case file round trip.
        let line = EvalCaseFile.encodeLine(c)
        XCTAssertEqual(try JSONDecoder().decode(EvalCase.self, from: Data(line.utf8)), c)
    }

    func testMakeCaseAllOfMultiTurnAndAppend() throws {
        let e = entry("a", queries: ["k1s"], suggested: ["/T/a.pdf"])
        let c = e.makeCase(queries: ["k1s", "the 2025 ones"], expected: ["/T/K1s", "/T/1099s/K-1.pdf"], kind: .allOf, existing: [], home: "/Users/me")
        XCTAssertEqual(c.expect.kind, .allOf)
        XCTAssertEqual(c.expect.paths, ["/T/K1s", "/T/1099s/K-1.pdf"])
        XCTAssertEqual(c.tags, ["history", "multi-turn"])
        XCTAssertEqual(c.id, "k1s")
        XCTAssertTrue(c.notes?.contains("none of them expected") == true, c.notes ?? "")

        // Written with the existing case API into a temp cases file.
        let cases = dir.appendingPathComponent("cases.jsonl")
        try EvalCaseFile.append(c, to: cases)
        let (loaded, errors) = try EvalCaseFile.load(cases)
        XCTAssertEqual(errors.count, 0)
        XCTAssertEqual(loaded, [c])
    }

    func testMakeCaseWithoutQueryUsesAppForID() {
        let e = SearchHistoryEntry(id: "x", app: "Google Chrome", queries: [], suggested: [])
        let c = e.makeCase(queries: [], expected: [], kind: .anyOf, existing: [])
        XCTAssertEqual(c.id, "google-chrome")
        XCTAssertTrue(c.expect.isEmpty)
    }
}
