import Foundation
import XCTest
@testable import LikelyEvalKit

final class EvalScoringTests: XCTestCase {
    private func any(_ paths: [String]) -> ResolvedExpectation { ResolvedExpectation(kind: .anyOf, paths: paths) }

    func testAnyOfHitAtRankTwo() {
        let s = EvalScorer.score(suggestions: ["/a/x.pdf", "/a/lease.pdf", "/a/y.pdf"], expected: any(["/a/lease.pdf", "/b/lease.pdf"]), k: 8)
        XCTAssertTrue(s.scorable)
        XCTAssertTrue(s.pass)
        XCTAssertEqual(s.firstHitRank, 2)
        XCTAssertFalse(s.hitAt1)
        XCTAssertTrue(s.hitAt3)
        XCTAssertTrue(s.hitAtK)
        XCTAssertEqual(s.recall, 1)
        XCTAssertEqual(s.precision!, 1.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(s.extras, ["/a/x.pdf", "/a/y.pdf"])
        XCTAssertEqual(s.missing, [])
    }

    func testAnyOfMissBeyondK() {
        let s = EvalScorer.score(suggestions: ["/1", "/2", "/3", "/hit"], expected: any(["/hit"]), k: 3)
        XCTAssertFalse(s.pass)
        XCTAssertEqual(s.firstHitRank, 4)
        XCTAssertFalse(s.hitAtK)
        XCTAssertEqual(s.recall, 0)
        XCTAssertEqual(s.precision, 0)
        XCTAssertEqual(s.missing, ["/hit"])
    }

    func testCaseInsensitiveAndDeduplicated() {
        let s = EvalScorer.score(suggestions: ["/Docs/Lease.PDF", "/docs/lease.pdf"], expected: any(["/docs/lease.pdf"]), k: 8)
        XCTAssertTrue(s.hitAt1)
        XCTAssertEqual(s.precision, 1)
        XCTAssertEqual(s.matched.count, 1)
    }

    func testAllOfPartialRecall() {
        let e = ResolvedExpectation(kind: .allOf, paths: ["/k/a.pdf", "/k/b.pdf", "/k/c.pdf"])
        let s = EvalScorer.score(suggestions: ["/k/b.pdf", "/other", "/k/a.pdf"], expected: e, k: 8)
        XCTAssertFalse(s.pass)
        XCTAssertEqual(s.recall, 2.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(s.firstHitRank, 1)
        XCTAssertEqual(s.missing, ["/k/c.pdf"])
        XCTAssertEqual(s.precision!, 2.0 / 3.0, accuracy: 1e-9)
    }

    func testAllOfComplete() {
        let e = ResolvedExpectation(kind: .allOf, paths: ["/k/a.pdf", "/k/b.pdf"])
        let s = EvalScorer.score(suggestions: ["/k/a.pdf", "/k/b.pdf"], expected: e, k: 8)
        XCTAssertTrue(s.pass)
        XCTAssertEqual(s.recall, 1)
    }

    func testAllOfWithFolderEntry() {
        // The K1s folder plus a K-1 filed elsewhere: the folder, or files inside it, cover the first entry.
        let e = ResolvedExpectation(kind: .allOf, paths: ["/T/K1s", "/T/1099s/Fundrise/K-1.pdf"], folderEntries: ["/T/K1s"])
        let viaFolder = EvalScorer.score(suggestions: ["/T/K1s", "/T/1099s/Fundrise/K-1.pdf"], expected: e, k: 8)
        XCTAssertTrue(viaFolder.pass)
        let viaContents = EvalScorer.score(suggestions: ["/T/K1s/MS/a.pdf", "/T/1099s/Fundrise/K-1.pdf"], expected: e, k: 8)
        XCTAssertTrue(viaContents.pass)
        XCTAssertEqual(viaContents.precision, 1)
        let missingFundrise = EvalScorer.score(suggestions: ["/T/K1s"], expected: e, k: 8)
        XCTAssertFalse(missingFundrise.pass)
        XCTAssertEqual(missingFundrise.missing, ["/T/1099s/Fundrise/K-1.pdf"])
        XCTAssertEqual(missingFundrise.recall, 0.5)
    }

    func testFolderOrContents() {
        let e = ResolvedExpectation(kind: .folder, paths: ["/T/K1s"], folderFiles: ["/T/K1s/a.pdf", "/T/K1s/b.pdf", "/T/K1s/sub/c.pdf", "/T/K1s/sub/d.pdf"])
        let folder = EvalScorer.score(suggestions: ["/T/K1s"], expected: e, k: 8)
        XCTAssertTrue(folder.pass)
        XCTAssertEqual(folder.recall, 1)

        let contents = EvalScorer.score(suggestions: ["/T/other.pdf", "/T/K1s/a.pdf", "/T/K1s/sub"], expected: e, k: 8)
        XCTAssertTrue(contents.pass)
        XCTAssertEqual(contents.firstHitRank, 2)
        // a.pdf plus the two files inside the suggested subfolder.
        XCTAssertEqual(contents.recall, 0.75, accuracy: 1e-9)

        // Not fooled by a sibling with the same prefix.
        let sibling = EvalScorer.score(suggestions: ["/T/K1s-old/a.pdf"], expected: e, k: 8)
        XCTAssertFalse(sibling.pass)
    }

    func testFolderOnlyMode() {
        let e = ResolvedExpectation(kind: .folder, paths: ["/T/K1s"], folderOnly: true)
        XCTAssertFalse(EvalScorer.score(suggestions: ["/T/K1s/a.pdf"], expected: e, k: 8).pass)
        XCTAssertTrue(EvalScorer.score(suggestions: ["/T/K1s"], expected: e, k: 8).pass)
    }

    func testNothingSuggested() {
        let s = EvalScorer.score(suggestions: [], expected: any(["/x"]), k: 8)
        XCTAssertFalse(s.pass)
        XCTAssertNil(s.precision)
        XCTAssertNil(s.firstHitRank)
    }

    func testUnscorableWithoutExpectation() {
        let s = EvalScorer.score(suggestions: ["/x"], expected: ResolvedExpectation(kind: .none, paths: []), k: 8)
        XCTAssertFalse(s.scorable)
    }

    func testCaseFileRoundTrip() throws {
        let text = """
        # comment
        {"id":"a","query":"my lease","expect":{"anyOf":["files/lease.pdf"]},"tags":["documents"]}

        {"id":"b","query":["an invoice","the hosting one"],"context":{"app":"Safari","windowTitle":"Upload"},"expect":{"folder":"~/T","mode":"folder-or-contents"},"tags":[]}
        not json
        """
        let (cases, errors) = EvalCaseFile.parse(text)
        XCTAssertEqual(cases.map(\.id), ["a", "b"])
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(cases[0].query, ["my lease"])
        XCTAssertEqual(cases[1].query.count, 2)
        XCTAssertEqual(cases[1].expect.kind, .folder)
        XCTAssertEqual(cases[1].context?.app, "Safari")
        let line = EvalCaseFile.encodeLine(cases[0])
        XCTAssertTrue(line.contains("\"query\":\"my lease\""), line)
        XCTAssertEqual(try JSONDecoder().decode(EvalCase.self, from: Data(line.utf8)), cases[0])
    }

    func testContextUserName() throws {
        let line = #"{"id":"c","query":"my lease","context":{"userName":"Sam Lee"},"expect":{"anyOf":["a.pdf"]}}"#
        let c = try JSONDecoder().decode(EvalCase.self, from: Data(line.utf8))
        XCTAssertEqual(c.context?.userName, "Sam Lee")
        XCTAssertEqual(c.context?.isEmpty, false)
        XCTAssertTrue(EvalCaseFile.encodeLine(c).contains("\"userName\":\"Sam Lee\""))
        XCTAssertNil(EvalCase.Context(app: "Safari").userName)
    }

    func testPathResolution() {
        let base = URL(fileURLWithPath: "/repo/evals/fixtures")
        XCTAssertEqual(EvalPath.resolve("files/a.pdf", relativeTo: base), "/repo/evals/fixtures/files/a.pdf")
        XCTAssertEqual(EvalPath.resolve("~/x", relativeTo: base), FileManager.default.homeDirectoryForCurrentUser.path + "/x")
        XCTAssertEqual(EvalPath.normalize("/repo/a/../b/"), "/repo/b")
        XCTAssertTrue(EvalPath.isInside("/a/b/c", "/a/b"))
        XCTAssertFalse(EvalPath.isInside("/a/bc", "/a/b"))
    }

    func testSummaryAndSlug() {
        func result(_ id: String, _ pass: Bool, rank: Int?) -> EvalCaseResult {
            let score = EvalScorer.score(suggestions: rank == nil ? ["/no"] : Array(repeating: "/no", count: rank! - 1).enumerated().map { "/no\($0.offset)" } + ["/yes"],
                                         expected: any(["/yes"]), k: 8)
            XCTAssertEqual(score.pass, pass)
            return EvalCaseResult(id: id, query: ["q"], tags: ["t"], expectKind: .anyOf, expected: ["/yes"], attempt: 1, status: "ok", error: nil,
                                  suggestions: [], turnSuggestions: [], refused: [], score: score, turns: 1, firstFileSeconds: 2,
                                  totalSeconds: Double(rank ?? 9), costUSD: 0.01, toolCalls: 3, transcriptPath: nil, promptPath: nil)
        }
        let summary = EvalSummary.of([result("a", true, rank: 1), result("b", true, rank: 3), result("c", false, rank: nil)])
        XCTAssertEqual(summary.passed, 2)
        XCTAssertEqual(summary.hitAt1, 1.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(summary.hitAt3, 2.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(summary.medianTotalSeconds, 3)
        XCTAssertEqual(summary.totalCostUSD!, 0.03, accuracy: 1e-9)
        XCTAssertEqual(EvalCase.slug("My K1s from 2025!"), "my-k1s-from-2025")
    }
}
