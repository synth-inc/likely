import XCTest
import LikelyStorage
@testable import LikelyTools

/// The saved tool approvals (ApprovalsBook): a read that failed never leads to a smaller saved set.
final class ApprovalsBookTests: XCTestCase {
    private var stored: SettingsSeal.Read<Data> = .absent
    private var writes: [Data] = []

    private func encode(_ approvals: ToolApproval.Approvals) -> Data { try! JSONEncoder().encode(approvals) }
    private let rclip = ToolApproval.Record(fingerprint: "f1", commands: ["rclip -n"])
    private let notes = ToolApproval.Record(fingerprint: "f2", commands: ["notes"])

    private func makeBook() -> ApprovalsBook {
        ApprovalsBook(read: { [unowned self] in self.stored },
                      write: { [unowned self] data in
                          self.writes.append(data)
                          self.stored = .valid(data)
                          return true
                      })
    }

    func testRefusesToSaveWhileTheSavedApprovalsCantBeVerified() {
        stored = .unverifiable   // the Keychain didn't answer at launch
        var book = makeBook()
        XCTAssertTrue(book.unreadable)
        XCTAssertEqual(book.approvals, [:], "nothing counts as approved meanwhile")
        XCTAssertFalse(book.update { $0["notes"] = self.notes })
        XCTAssertEqual(writes, [], "a save would have replaced the saved approvals with just this one")
        for state: SettingsSeal.Read<Data> in [.tampered, .unsealed] {
            stored = state
            XCTAssertFalse(book.update { $0["notes"] = self.notes })
        }
        XCTAssertEqual(writes, [])
    }

    func testRereadsOnRecoveryAndKeepsWhatWasSaved() throws {
        stored = .unverifiable
        var book = makeBook()
        // The Keychain answers again: the change applies on top of what was saved.
        stored = .valid(encode(["rclip": rclip]))
        XCTAssertTrue(book.update { $0["notes"] = self.notes })
        XCTAssertFalse(book.unreadable)
        let saved = try JSONDecoder().decode(ToolApproval.Approvals.self, from: try XCTUnwrap(writes.last))
        XCTAssertEqual(saved, ["rclip": rclip, "notes": notes])
        XCTAssertEqual(book.approvals, saved)
    }

    func testNormalSavesAndNoneSavedYet() {
        var book = makeBook()
        XCTAssertFalse(book.unreadable)
        XCTAssertTrue(book.update { $0["rclip"] = self.rclip })
        XCTAssertTrue(book.update { $0["rclip"] = nil })
        XCTAssertEqual(book.approvals, [:])
        XCTAssertEqual(writes.count, 2)
    }

    func testFailedWriteChangesNothing() {
        stored = .valid(encode(["rclip": rclip]))
        var book = ApprovalsBook(read: { [unowned self] in self.stored }, write: { _ in false })
        XCTAssertFalse(book.update { $0["notes"] = self.notes })
        XCTAssertEqual(book.approvals, ["rclip": rclip])
    }
}
