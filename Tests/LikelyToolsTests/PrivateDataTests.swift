import Foundation
import XCTest
@testable import LikelyTools

final class PrivateDataTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "likely-private-data-tests-\(UUID().uuidString)"

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testAllAreasBlockedByDefault() {
        XCTAssertEqual(PrivateDataAccess.blocked(defaults: defaults), PrivateDataArea.allCases)
        PrivateDataAccess.setAllowed(true, .photos, defaults: defaults)
        XCTAssertTrue(PrivateDataAccess.isAllowed(.photos, defaults: defaults))
        XCTAssertFalse(PrivateDataAccess.blocked(defaults: defaults).contains(.photos))
        PrivateDataAccess.setAllowed(false, .photos, defaults: defaults)
        XCTAssertTrue(PrivateDataAccess.blocked(defaults: defaults).contains(.photos))
    }

    func testAreaToRuleMapping() {
        let rules = PrivateDataAccess.sandboxRules(blocked: [.photos, .mail], home: "/Users/someone")
        XCTAssertTrue(rules.hasPrefix("(deny file-read* "), rules)
        XCTAssertTrue(rules.contains(#"(subpath "/Users/someone/Library/Photos")"#))
        XCTAssertTrue(rules.contains(#"(subpath "/Users/someone/Pictures/Photos Library.photoslibrary")"#))
        XCTAssertTrue(rules.contains("(regex "), "photos libraries anywhere")
        XCTAssertTrue(rules.contains(#"(subpath "/Users/someone/Library/Mail")"#))
        XCTAssertFalse(rules.contains("Library/Messages"))
        XCTAssertEqual(PrivateDataAccess.sandboxRules(blocked: [], home: "/Users/someone"), "")

        let all = PrivateDataAccess.sandboxRules(blocked: PrivateDataArea.allCases, home: "/Users/someone")
        for path in ["Library/Messages", "Library/Application Support/AddressBook", "Library/Calendars", "Library/Reminders",
                     "Library/Safari", "Library/Cookies", "Library/Containers", "Library/Group Containers"] {
            XCTAssertTrue(all.contains("(subpath \"/Users/someone/\(path)\")"), path)
        }
    }

    /// Allowing other apps' data doesn't open the containers of an area that's still blocked.
    func testAppDataOnKeepsMailContainersClosed() {
        let blocked = PrivateDataArea.allCases.filter { $0 != .appData }
        let rules = PrivateDataAccess.sandboxRules(blocked: blocked, home: "/Users/someone")
        XCTAssertFalse(rules.contains(#"(subpath "/Users/someone/Library/Containers")"#))
        XCTAssertTrue(rules.contains(#"(subpath "/Users/someone/Library/Containers/com.apple.mail")"#))
    }

    func testProfileCompositionWithTogglesOnAndOff() {
        let off = AgentSandbox.compose(profile: AgentSandbox.privacyOnlyProfile, blockedAreas: PrivateDataArea.allCases, home: "/Users/someone")
        XCTAssertTrue(off.contains("/Users/someone/Library/Photos"))
        XCTAssertTrue(off.hasSuffix(AgentSandbox.protectionRules(home: "/Users/someone")), "Likely's own data rules stay last")
        let photosOn = AgentSandbox.compose(profile: AgentSandbox.privacyOnlyProfile,
                                            blockedAreas: PrivateDataArea.allCases.filter { $0 != .photos }, home: "/Users/someone")
        XCTAssertFalse(photosOn.contains("/Users/someone/Library/Photos\""))
        XCTAssertTrue(photosOn.contains("/Users/someone/Library/Mail"))
        let allOn = AgentSandbox.compose(profile: AgentSandbox.privacyOnlyProfile, blockedAreas: [], home: "/Users/someone")
        XCTAssertFalse(allOn.contains("Library/Mail"))

        let codex = AgentSandbox.codexFilesystem(home: "/Users/someone", readable: [], blockedAreas: [.mail])
        XCTAssertTrue(codex.contains(#""/Users/someone/Library/Mail" = "none""#), codex)
        XCTAssertFalse(codex.contains("Library/Photos"))
    }

    /// Real sandbox-exec against a fake home: blocked areas (and a library anywhere) fail with EPERM.
    func testDenyUnderSandboxExec() throws {
        let home = URL(fileURLWithPath: AgentSandbox.realPath(NSTemporaryDirectory())).appendingPathComponent("likely-pd-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let files = ["Library/Photos/Libraries/Syndication.photoslibrary/database/Photos.sqlite",
                     "Elsewhere/Old.photoslibrary/originals/a.jpg", "Library/Mail/V10/x.emlx",
                     "Library/Containers/com.example.app/Data/secret", "Documents/tax.pdf"]
        for file in files {
            let url = home.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        func status(_ path: String, blocked: [PrivateDataArea]) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            process.arguments = ["-p", AgentSandbox.compose(profile: AgentSandbox.privacyOnlyProfile, blockedAreas: blocked, home: home.path),
                                 "/bin/cat", home.appendingPathComponent(path).path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
        for file in files.dropLast() { XCTAssertNotEqual(try status(file, blocked: PrivateDataArea.allCases), 0, file) }
        XCTAssertEqual(try status("Documents/tax.pdf", blocked: PrivateDataArea.allCases), 0)
        XCTAssertEqual(try status(files[0], blocked: []), 0)
        XCTAssertEqual(try status(files[1], blocked: [.mail]), 0)
        XCTAssertNotEqual(try status(files[2], blocked: [.mail]), 0)
    }

    // MARK: needs

    func testNeedsDecoding() throws {
        let json = #"{"tools": [{"name": "P", "commands": ["osxphotos query --json"], "needs": ["photos", "Mail"]},"#
            + #"{"name": "S", "commands": ["x"], "needs": "contacts"},"#
            + #"{"name": "N", "commands": ["x"], "needs": 3},"#
            + #"{"name": "Q", "commands": ["x"]}]}"#
        let file = try ToolsFile.decode(Data(json.utf8))
        XCTAssertEqual(file.tools[0].needs, ["photos", "Mail"])
        XCTAssertEqual(file.tools[0].neededAreas, [.photos, .mail])
        XCTAssertEqual(file.tools[0].normalizedNeeds, ["mail", "photos"])
        XCTAssertEqual(file.tools[1].neededAreas, [.contacts])
        XCTAssertEqual(file.tools[2].needs, [])
        XCTAssertTrue(file.issues.contains { $0.contains("\"needs\"") })
        XCTAssertEqual(file.tools[3].needs, [])
        // Round trip; no "needs" key written for tools without any.
        let encoded = String(decoding: try ToolsFile(tools: file.tools).encoded(), as: UTF8.self)
        XCTAssertEqual(try ToolsFile.decode(Data(encoded.utf8)).tools, file.tools)
        XCTAssertEqual(encoded.components(separatedBy: "\"needs\"").count - 1, 2)
    }

    func testUnknownNeedIsAProblem() {
        var tool = ToolPrompts.photosLibraryExample
        XCTAssertEqual(tool.problems, [])
        tool.needs = ["photos", "bank-account"]
        XCTAssertTrue(tool.problems.contains { $0.contains("bank-account") }, "\(tool.problems)")
        XCTAssertFalse(tool.isActive)
    }

    func testUnmetNeeds() {
        let tool = ToolPrompts.photosLibraryExample
        XCTAssertEqual(PrivateDataAccess.unmetNeeds(of: tool, defaults: defaults), [.photos])
        PrivateDataAccess.setAllowed(true, .photos, defaults: defaults)
        XCTAssertEqual(PrivateDataAccess.unmetNeeds(of: tool, defaults: defaults), [])
    }

    func testApprovalCoversNeeds() {
        let tool = ToolPrompts.photosLibraryExample
        let approvals = [tool.id: ToolApproval.record(for: tool)]
        XCTAssertEqual(ToolApproval.usable([tool], approvals: approvals), [tool])

        var wantsMail = tool
        wantsMail.needs = ["photos", "mail"]
        XCTAssertNotEqual(ToolApproval.fingerprint(of: wantsMail), ToolApproval.fingerprint(of: tool))
        let pending = ToolApproval.pending([wantsMail], approvals: approvals)
        XCTAssertEqual(pending.first?.summary, ["+ needs access to Mail"])
        XCTAssertEqual(ToolApproval.usable([wantsMail], approvals: approvals), [])

        // Order and spelling of needs don't matter; tools without needs keep their old fingerprint.
        var reordered = wantsMail
        reordered.needs = ["Mail", "photos"]
        XCTAssertEqual(ToolApproval.fingerprint(of: reordered), ToolApproval.fingerprint(of: wantsMail))
        let plain = CustomTool(id: "r", name: "R", commands: ["cd", "rclip -n"], instructions: "Use it.")
        var plainWithEmptyNeeds = plain
        plainWithEmptyNeeds.needs = []
        XCTAssertEqual(ToolApproval.fingerprint(of: plainWithEmptyNeeds), ToolApproval.fingerprint(of: plain))

        // A planted tool asking for Mail is pending, with the need in the diff.
        let planted = CustomTool(id: "p", name: "P", commands: ["mdls"], instructions: "x", needs: ["mail"])
        XCTAssertEqual(ToolApproval.pending([planted], approvals: [:]).first?.summary.first { $0.contains("Mail") }, "+ needs access to Mail")
    }

    func testSetupPromptDocumentsNeeds() {
        let prompt = ToolPrompts.setupPrompt
        XCTAssertTrue(prompt.contains("- needs (optional)"))
        XCTAssertTrue(prompt.contains("\"osxphotos\""))
        XCTAssertTrue(prompt.contains("\"needs\" : [") || prompt.contains("\"needs\": ["), prompt)
    }
}
