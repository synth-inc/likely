import RecentFilesCore
import XCTest

final class RecentSelectorTests: XCTestCase {
    let desktop = "/Users/alex/Desktop"
    let documents = "/Users/alex/Documents"
    let downloads = "/Users/alex/Downloads"
    var roots: [String] { [desktop, documents, downloads] }
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func at(_ secondsAgo: TimeInterval) -> Date { now.addingTimeInterval(-secondsAgo) }

    /// Runs the selector over `items` (sorted newest first here, as Spotlight returns them).
    private func select(_ items: [RecentItem], limit: Int = 10, appFolders: Set<String> = [],
                        candidates: ((String) -> Bool)? = nil) -> (paths: [String], selector: RecentSelector) {
        var iterator = items.sorted { $0.added > $1.added }.makeIterator()
        let selector = RecentSelector(roots: roots, next: { iterator.next() },
                                      isCandidate: candidates ?? { _ in true }, isAppFolder: { appFolders.contains($0) })
        return (selector.select(limit: limit).map(\.path), selector)
    }

    func testLooseFilesDraggedInTogetherAreOneEntry() {
        let items = (0..<5).map { RecentItem(path: "\(desktop)/photo\($0).jpg", added: at(100 + Double($0) * 1.5)) }
        // Chained: 6 s from first to last, but never more than 1.5 s between neighbours.
        XCTAssertEqual(select(items).paths, ["\(desktop)/photo0.jpg"])
    }

    func testLooseFilesAddedSeparatelyAreSeparateEntries() {
        let items = [RecentItem(path: "\(desktop)/a.pdf", added: at(10), isDownload: true),
                     RecentItem(path: "\(desktop)/b.pdf", added: at(30), isDownload: true)]
        XCTAssertEqual(select(items).paths, ["\(desktop)/a.pdf", "\(desktop)/b.pdf"])
    }

    func testAFolderInsideASearchFolderGivesOneEntry() {
        // A slow move: 4 s gaps, and files keep arriving later too.
        let items = [RecentItem(path: "\(desktop)/Junk/dump/report.pdf", added: at(10)),
                     RecentItem(path: "\(desktop)/Junk/dump/clip.mov", added: at(14), isScreenCapture: true),
                     RecentItem(path: "\(desktop)/Junk/other/notes.txt", added: at(5_000)),
                     RecentItem(path: "\(downloads)/invoice.pdf", added: at(20), isDownload: true)]
        XCTAssertEqual(select(items).paths, ["\(desktop)/Junk/dump/report.pdf", "\(downloads)/invoice.pdf"])
    }

    func testABatchStillGivesAnEntryWhenItsNewestFileIsRejected() {
        let items = [RecentItem(path: "\(desktop)/Unzipped/.DS_Store", added: at(10)),
                     RecentItem(path: "\(desktop)/Unzipped/readme.txt", added: at(10.5))]
        let result = select(items, candidates: { !$0.hasSuffix(".DS_Store") })
        XCTAssertEqual(result.paths, ["\(desktop)/Unzipped/readme.txt"])
    }

    func testDevFoldersAreAlwaysSkipped() {
        let items = [RecentItem(path: "\(documents)/app/node_modules/x/index.js", added: at(1), lastUsed: at(1)),
                     RecentItem(path: "\(documents)/app/.build/debug/app", added: at(2)),
                     RecentItem(path: "\(documents)/Proj/DerivedData/x.o", added: at(3)),
                     RecentItem(path: "\(documents)/ios/Pods/a.h", added: at(4)),
                     RecentItem(path: "\(documents)/Proj.xcodeproj/project.pbxproj", added: at(5)),
                     RecentItem(path: "\(downloads)/build.pdf", added: at(6), isDownload: true)]
        XCTAssertEqual(select(items).paths, ["\(downloads)/build.pdf"])
    }

    func testNotesAnAppKeepsRewritingAreSkipped() {
        // Never opened, modified an hour after it was added: an app is writing it.
        let note = RecentItem(path: "\(documents)/notes.md", added: at(4_000), modified: at(400))
        let opened = RecentItem(path: "\(documents)/draft.md", added: at(5_000), modified: at(100), lastUsed: at(100))
        let result = select([note, opened])
        XCTAssertEqual(result.paths, ["\(documents)/draft.md"])
        XCTAssertEqual(result.selector.verdicts.first?.verdict, .rewritten)
    }

    func testFilesInAnAppFolderNeedAUserSignal() {
        let vault = "\(documents)/Vault"
        let items = [RecentItem(path: "\(vault)/Daily/2026-11-09.md", added: at(10), modified: at(10)),
                     RecentItem(path: "\(vault)/Attachments/scan.pdf", added: at(20), isDownload: true),
                     RecentItem(path: "\(documents)/letter.pdf", added: at(30), modified: at(30))]
        let result = select(items, appFolders: [vault])
        XCTAssertEqual(result.paths, ["\(vault)/Attachments/scan.pdf", "\(documents)/letter.pdf"])
    }

    func testTheSearchFolderItselfIsNotCheckedForMarkers() {
        // A search folder that happens to be a repo or vault doesn't rule out everything in it.
        let items = [RecentItem(path: "\(documents)/letter.pdf", added: at(10))]
        XCTAssertEqual(select(items, appFolders: [documents]).paths, ["\(documents)/letter.pdf"])
    }

    func testABurstOfSeparateWritesToOneFolderIsSkipped() {
        // Five files written one at a time over a few minutes by a sync tool.
        let synced = (0..<5).map { RecentItem(path: "\(documents)/Sync/log\($0).txt", added: at(60 + Double($0) * 45)) }
        let screenshot = RecentItem(path: "\(documents)/Sync/shot.png", added: at(70), isScreenCapture: true)
        let alone = RecentItem(path: "\(documents)/Taxes/1099.pdf", added: at(900))
        let result = select(synced + [screenshot, alone])
        XCTAssertEqual(result.paths, ["\(documents)/Sync/shot.png", "\(documents)/Taxes/1099.pdf"])
        XCTAssertTrue(result.selector.verdicts.contains { $0.verdict == .burst })
    }

    func testThreeSeparateFilesInAFolderAreNotABurst() {
        let items = (0..<3).map { RecentItem(path: "\(desktop)/doc\($0).pdf", added: at(60 + Double($0) * 60)) }
        XCTAssertEqual(select(items).paths.count, 3)
    }

    func testUserSignals() {
        XCTAssertTrue(RecentRules.hasUserAddedSignal(RecentItem(path: "/a", added: now, lastUsed: now)))
        XCTAssertTrue(RecentRules.hasUserAddedSignal(RecentItem(path: "/a", added: now, isScreenCapture: true)))
        XCTAssertTrue(RecentRules.hasUserAddedSignal(RecentItem(path: "/a", added: now, isDownload: true)))
        XCTAssertFalse(RecentRules.hasUserAddedSignal(RecentItem(path: "/a", added: now, modified: now)))
        XCTAssertFalse(RecentRules.isStillRewritten(RecentItem(path: "/a", added: at(600), modified: at(590))))
        XCTAssertTrue(RecentRules.isStillRewritten(RecentItem(path: "/a", added: at(600), modified: at(0))))
    }

    func testLimitAndBatchKeys() {
        let items = (0..<5).map { RecentItem(path: "\(downloads)/f\($0).pdf", added: at(Double($0) * 100), isDownload: true) }
        XCTAssertEqual(select(items, limit: 2).paths, ["\(downloads)/f0.pdf", "\(downloads)/f1.pdf"])
        XCTAssertEqual(RecentRules.batchKey("\(desktop)/Photos/2026/a.jpg", roots: roots), "\(desktop)/Photos")
        XCTAssertEqual(RecentRules.batchKey("\(desktop)/a.jpg", roots: roots), desktop)
        XCTAssertEqual(RecentRules.foldersBelowRoot("\(documents)/Vault/Daily/x.md", roots: roots),
                       ["\(documents)/Vault/Daily", "\(documents)/Vault"])
    }
}
