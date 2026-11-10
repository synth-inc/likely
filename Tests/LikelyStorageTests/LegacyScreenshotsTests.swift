import Foundation
import XCTest
@testable import LikelyStorage

/// The launch cleanup of older versions' screenshots, in a fake data folder laid out like the real
/// one (…/Likely a link to …/Likely.noindex).
final class LegacyScreenshotsTests: TempDirTestCase {
    private var support: URL { dir.appendingPathComponent("Application Support/Likely") }
    private var real: URL { dir.appendingPathComponent("Application Support/Likely.noindex") }

    private func put(_ relative: String, in root: URL? = nil) throws -> String {
        let url = (root ?? real).appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
        return url.path
    }

    func testRemovesScreenshotsAndNothingElse() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: support.path, withDestinationPath: "Likely.noindex")

        let gone = try [
            "evals/screenshots/case.png.enc", "evals/screenshots/old.png", "evals/screenshots/X.PNG.enc",
            "run/context.png", "run/context-1A2B.png", "debug/3F2504E0.png", "debug/OLD.PNG",
            "evals/runs/r1/cases/001-a/agent/screenshot-0a1b2c3d.png",
            "evals/runs/r2/cases/002-b-2/agent/screenshot-99999999.png",
        ].map { try put($0) }
        let kept = try [
            "evals/cases.jsonl", "evals/drafts.jsonl", "evals/runs/r1/report.html",
            "evals/runs/r1/cases/001-a/prompt.txt", "evals/runs/r1/cases/001-a/agent/screenshot-notes.png",
            "evals/runs/r1/cases/001-a/agent/gemini-settings.json", "run/last-run.jsonl", "run/gemini-settings.json",
            "run/photo.png", "debug/notes.txt", "History/history.enc.jsonl", "tools.json", "screenshot-0a1b2c3d.png",
        ].map { try put($0) }
        // Links are never followed: not to a folder elsewhere, not to a file elsewhere.
        let outside = dir.appendingPathComponent("outside", isDirectory: true)
        let outsideShot = try put("screenshot-0a1b2c3d.png", in: outside)
        let outsidePNG = try put("context-9.png", in: outside)
        try fm.createSymbolicLink(atPath: real.appendingPathComponent("evals/runs/linked").path, withDestinationPath: outside.path)
        try fm.createSymbolicLink(atPath: real.appendingPathComponent("run/context-link.png").path, withDestinationPath: outsidePNG)

        XCTAssertEqual(LegacyScreenshots.removeAll(support: support), gone.count)
        for path in gone { XCTAssertFalse(fm.fileExists(atPath: path), path) }
        for path in kept + [outsideShot, outsidePNG] { XCTAssertTrue(fm.fileExists(atPath: path), path) }
        XCTAssertFalse(fm.fileExists(atPath: real.appendingPathComponent("evals/screenshots").path), "the emptied folder goes too")
        XCTAssertNotNil(try? fm.destinationOfSymbolicLink(atPath: real.appendingPathComponent("run/context-link.png").path))
        XCTAssertTrue(fm.fileExists(atPath: support.path))
        // Nothing left to do the next time.
        XCTAssertEqual(LegacyScreenshots.removeAll(support: support), 0)
    }

    /// A data folder that's a link anywhere but `Likely.noindex` next to it is left alone.
    func testIgnoresAFolderLinkedElsewhere() throws {
        let fm = FileManager.default
        let elsewhere = dir.appendingPathComponent("elsewhere", isDirectory: true)
        let shot = try put("evals/screenshots/a.png", in: elsewhere)
        try fm.createDirectory(at: support.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: support.path, withDestinationPath: elsewhere.path)
        XCTAssertEqual(LegacyScreenshots.removeAll(support: support), 0)
        XCTAssertTrue(fm.fileExists(atPath: shot))
    }

    func testMissingFolderIsFine() {
        XCTAssertEqual(LegacyScreenshots.removeAll(support: dir.appendingPathComponent("nothing-here")), 0)
    }
}
