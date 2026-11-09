import XCTest
@testable import LikelyEvalKit

/// Which cases get the user's tools (tools.json), and how runs record and compare them.
final class EvalToolsTests: XCTestCase {
    private func evalCase(source: String?, useTools: Bool? = nil) -> EvalCase {
        EvalCase(id: "c", query: ["my lease"], context: useTools.map { EvalCase.Context(useTools: $0) },
                 expect: Expectation.make(kind: .anyOf, paths: ["a.pdf"]), source: source)
    }

    func testPersonalCasesUseTheUsersTools() {
        for source in ["manual", "captured", "history", nil] {
            XCTAssertTrue(EvalToolPolicy.usesTools(evalCase(source: source), inFixtureSuite: false, withTools: false), "\(source ?? "nil")")
        }
    }

    func testFixtureCasesIgnoreToolsUnlessOptedIn() {
        // By source, or by coming from the fixtures suite file.
        XCTAssertFalse(EvalToolPolicy.usesTools(evalCase(source: "fixture"), inFixtureSuite: false, withTools: false))
        XCTAssertFalse(EvalToolPolicy.usesTools(evalCase(source: "manual"), inFixtureSuite: true, withTools: false))
        // --with-tools, or the case's own flag.
        XCTAssertTrue(EvalToolPolicy.usesTools(evalCase(source: "fixture"), inFixtureSuite: true, withTools: true))
        XCTAssertTrue(EvalToolPolicy.usesTools(evalCase(source: "fixture", useTools: true), inFixtureSuite: true, withTools: false))
    }

    func testCaseFlagWinsEitherWay() {
        XCTAssertFalse(EvalToolPolicy.usesTools(evalCase(source: "manual", useTools: false), inFixtureSuite: false, withTools: false))
        XCTAssertFalse(EvalToolPolicy.usesTools(evalCase(source: "fixture", useTools: false), inFixtureSuite: true, withTools: true))
    }

    func testUseToolsRoundTrips() throws {
        let line = #"{"id":"c","query":"photo of the dog","context":{"useTools":true},"expect":{"anyOf":["a.jpg"]},"source":"fixture"}"#
        let c = try JSONDecoder().decode(EvalCase.self, from: Data(line.utf8))
        XCTAssertEqual(c.context?.useTools, true)
        XCTAssertEqual(c.context?.isEmpty, false)
        XCTAssertTrue(EvalCaseFile.encodeLine(c).contains("\"useTools\":true"))
        XCTAssertNil(EvalCase.Context(app: "Safari").useTools)
    }

    func testToolSetHashesCommandsAndInstructions() {
        let a = EvalToolSet([(id: "rclip", commands: ["rclip -n"], instructions: "Search photos by content.")])
        let same = EvalToolSet([(id: "rclip", commands: ["rclip -n"], instructions: "Search photos by content.")])
        let newCommand = EvalToolSet([(id: "rclip", commands: ["rclip -n", "rclip -f"], instructions: "Search photos by content.")])
        let newText = EvalToolSet([(id: "rclip", commands: ["rclip -n"], instructions: "Search photos.")])
        XCTAssertEqual(a, same)
        XCTAssertEqual(a.ids, ["rclip"])
        XCTAssertEqual(a.hash.count, 8)
        XCTAssertNotEqual(a.hash, newCommand.hash)
        XCTAssertNotEqual(a.hash, newText.hash)
        XCTAssertEqual(EvalToolSet.empty.hash, "")
        XCTAssertEqual(EvalToolSet.empty.summary, "none")
        // Order in tools.json doesn't matter.
        let ab = EvalToolSet([(id: "b", commands: ["b"], instructions: ""), (id: "a", commands: ["a"], instructions: "")])
        let ba = EvalToolSet([(id: "a", commands: ["a"], instructions: ""), (id: "b", commands: ["b"], instructions: "")])
        XCTAssertEqual(ab, ba)
        XCTAssertEqual(ab.ids, ["a", "b"])
    }

    func testToolChanges() {
        let rclip = (id: "rclip", commands: ["rclip -n"], instructions: "Photos.")
        let notes = (id: "notes", commands: ["notes-cli search"], instructions: "Notes.")
        XCTAssertEqual(EvalToolSet([rclip]).changes(since: .empty), ["+rclip"])
        XCTAssertEqual(EvalToolSet.empty.changes(since: EvalToolSet([rclip])), ["-rclip"])
        XCTAssertEqual(EvalToolSet([rclip, notes]).changes(since: EvalToolSet([rclip, notes])), [])
        let edited = (id: "rclip", commands: ["rclip -n"], instructions: "Photos, by content.")
        XCTAssertEqual(EvalToolSet([edited]).changes(since: EvalToolSet([rclip, notes])), ["~rclip", "-notes"])
    }

    private func run(startedAt: String, tools: EvalToolSet?) -> EvalRun {
        EvalRun(suite: "personal", suiteFiles: [], agent: "claude", model: "haiku", startedAt: startedAt, finishedAt: startedAt,
                k: 8, timeoutSeconds: 120, tags: [], isolated: false, promptHash: "abc", likelyVersion: "dev", cases: [],
                tools: tools)
    }

    func testRunRecordsToolsAndComparisonFlagsChanges() throws {
        let rclip = EvalToolSet([(id: "rclip", commands: ["rclip -n"], instructions: "Photos.")])
        let before = run(startedAt: "2026-11-01T00:00:00Z", tools: .empty)
        let after = run(startedAt: "2026-11-02T00:00:00Z", tools: rclip)

        // Recorded in results.json.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("evaltools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("results.json")
        try after.write(to: url)
        XCTAssertEqual(EvalRun.load(url)?.tools, rclip)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("\"rclip\""))

        // A different tool set is still the run to compare against (that's how a tool gets measured),
        // and the comparison says what changed.
        XCTAssertEqual(after.mismatches(with: before), [])
        XCTAssertEqual(after.toolChanges(since: before), ["+rclip"])
        let text = EvalReport.textSummary(after, previous: before)
        XCTAssertTrue(text.contains("Tools: rclip (\(rclip.hash))"), text)
        XCTAssertTrue(text.contains("tools changed: +rclip"), text)
        let html = EvalReport.html(after, previous: before)
        XCTAssertTrue(html.contains("tools: rclip (\(rclip.hash))"))
        XCTAssertTrue(html.contains("Tools changed: +rclip"))

        // Same tools: no note.
        XCTAssertFalse(EvalReport.textSummary(after, previous: after).contains("tools changed"))
        // Older results without a tools record: nothing to compare, no note.
        let old = run(startedAt: "2026-10-01T00:00:00Z", tools: nil)
        XCTAssertEqual(after.toolChanges(since: old), [])
        XCTAssertFalse(EvalReport.textSummary(after, previous: old).contains("tools changed"))
    }

    func testOlderResultsDecodeWithoutTools() throws {
        let data = try JSONEncoder().encode(run(startedAt: "2026-11-01T00:00:00Z", tools: nil))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["tools"] = nil
        let decoded = try JSONDecoder().decode(EvalRun.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.tools)
    }
}
