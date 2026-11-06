import Foundation
import XCTest
@testable import LikelyEvalKit

final class SearchHistoryTests: XCTestCase {
    private var dir: URL!
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
        XCTAssertEqual(SearchHistoryFile.load(url), [])   // no file yet
        let a = entry("a", queries: ["my lease", "the signed one"], suggested: ["/d/lease.pdf"], picked: ["/d/lease-signed.pdf"])
        try SearchHistoryFile.append(a, to: url)
        try SearchHistoryFile.append(entry("b"), to: url)
        let loaded = SearchHistoryFile.load(url)
        XCTAssertEqual(loaded.map(\.id), ["a", "b"])
        XCTAssertEqual(loaded[0], a)
        XCTAssertTrue(loaded[0].wasPicked)
        XCTAssertNotNil(loaded[0].timestamp)
        XCTAssertFalse(SearchHistoryFile.encodeLine(a).contains("\\/"), "paths are written without escaped slashes")
    }

    func testAppendCapsToLimitDroppingOldest() throws {
        for i in 0..<12 { try SearchHistoryFile.append(entry("e\(i)"), to: url, limit: 5) }
        XCTAssertEqual(SearchHistoryFile.load(url).map(\.id), ["e7", "e8", "e9", "e10", "e11"])
    }

    func testClear() throws {
        try SearchHistoryFile.append(entry("a"), to: url)
        try SearchHistoryFile.clear(url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(SearchHistoryFile.load(url), [])
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
        try SearchHistoryFile.append(entry("a"), to: url)
        try SearchHistoryFile.append(entry("b"), to: url)
        let updated = try SearchHistoryFile.update(id: "a", in: url) { $0.evalCaseID = "my-case" }
        XCTAssertEqual(updated?.evalCaseID, "my-case")
        XCTAssertNil(try SearchHistoryFile.update(id: "missing", in: url) { $0.evalCaseID = "x" })
        let loaded = SearchHistoryFile.load(url)
        XCTAssertEqual(loaded.map(\.id), ["a", "b"])
        XCTAssertTrue(loaded[0].hasEval)
        XCTAssertFalse(loaded[1].hasEval)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).hasPrefix("garbage line\n"))
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
