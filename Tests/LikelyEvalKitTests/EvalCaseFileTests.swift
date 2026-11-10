import Foundation
import XCTest
@testable import LikelyEvalKit
import LikelyStorage

final class EvalCaseFileTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("likely-cases-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testCaseFilesAreOwnerOnly() throws {
        let cases = dir.appendingPathComponent("new/cases.jsonl")
        try EvalCaseFile.append(EvalCase(id: "a", query: ["q"], expect: Expectation(anyOf: ["/x"])), to: cases)
        XCTAssertEqual(OwnerOnly.mode(cases.path), 0o600)
        XCTAssertEqual(OwnerOnly.mode(cases.deletingLastPathComponent().path), 0o700)
        try EvalCaseFile.replace(id: "a", with: nil, in: cases)
        XCTAssertEqual(OwnerOnly.mode(cases.path), 0o600)
    }

    /// Cases saved by older versions name a screenshot: they still load, and the field is kept as is.
    func testOldCasesWithAScreenshotStillLoad() throws {
        let line = #"{"id":"old","query":["w2"],"context":{"app":"Safari","screenshot":"~/Library/Application Support/Likely/evals/screenshots/old.png.enc"},"expect":{"anyOf":["~/w2.pdf"]}}"#
        let c = try JSONDecoder().decode(EvalCase.self, from: Data(line.utf8))
        XCTAssertEqual(c.context?.app, "Safari")
        XCTAssertNotNil(c.context?.screenshot)
        XCTAssertEqual(try JSONDecoder().decode(EvalCase.self, from: Data(EvalCaseFile.encodeLine(c).utf8)), c)
    }

    /// Screenshot-only cases (no query) have nothing to replay now; EvalCLI skips them.
    func testScreenshotOnlyCasesHaveNoQuery() {
        XCTAssertFalse(EvalCase(id: "a", query: [""], expect: Expectation(anyOf: ["/x"])).hasQuery)
        XCTAssertFalse(EvalCase(id: "b", query: [], expect: Expectation(anyOf: ["/x"])).hasQuery)
        XCTAssertFalse(EvalCase(id: "c", query: ["  ", "\n"], expect: Expectation(anyOf: ["/x"])).hasQuery)
        XCTAssertTrue(EvalCase(id: "d", query: ["", "the lease"], expect: Expectation(anyOf: ["/x"])).hasQuery)
    }
}
