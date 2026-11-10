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
        // With every area on, only the always-denied stores are left.
        let none = PrivateDataAccess.sandboxRules(blocked: [], home: "/Users/someone")
        XCTAssertFalse(none.contains("Library/Photos") || none.contains("Library/Mail") || none.contains("Containers"), none)
        XCTAssertTrue(none.contains(#"(subpath "/Users/someone/Library/Application Support/com.apple.TCC")"#), none)

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
        XCTAssertTrue(rules.contains(#"com\\.apple\\.mail(\\..+)?"#), rules)
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
        XCTAssertEqual(pending.first?.summary, ["+ needs access to your Mail"])
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
        XCTAssertEqual(ToolApproval.pending([planted], approvals: [:]).first?.summary.first { $0.contains("Mail") }, "+ needs access to your Mail")
    }

    func testSetupPromptDocumentsNeeds() {
        let prompt = ToolPrompts.setupPrompt
        XCTAssertTrue(prompt.contains("- needs (optional)"))
        XCTAssertTrue(prompt.contains("\"osxphotos\""))
        XCTAssertTrue(prompt.contains("\"needs\" : [") || prompt.contains("\"needs\": ["), prompt)
    }

    // MARK: Review fixes

    /// A tool changed outside Likely stays pending whatever its switch does: flipping it (or Allow on
    /// its needs, which ends in the same call) never approves it.
    func testToggleNeverApproves() {
        let approved = CustomTool(id: "r", name: "R", commands: ["rclip -n"], instructions: "Use it.")
        let approvals = [approved.id: ToolApproval.record(for: approved)]
        var planted = approved
        planted.commands = ["rclip -n", "mdls -raw"]
        planted.needs = ["messages"]
        XCTAssertEqual(planted.problems, [])
        for enabled in [false, true, false, true] {
            planted.enabled = enabled
            let after = ToolApproval.afterToggle(planted, approvals: approvals)
            XCTAssertEqual(after, approvals, "the planted fingerprint was approved")
            XCTAssertEqual(ToolApproval.usable([planted], approvals: after), [])
            XCTAssertEqual(ToolApproval.pending([planted], approvals: after).count, enabled ? 1 : 0)
        }
        // A brand-new planted tool: no record appears.
        let fresh = CustomTool(id: "new", name: "N", commands: ["mdls"], instructions: "x", needs: ["mail"])
        XCTAssertNil(ToolApproval.afterToggle(fresh, approvals: [:])["new"])
        // An approved tool stays approved through the switch, and an old record (from before `needs`)
        // that matches is refreshed.
        var off = approved
        off.enabled = false
        XCTAssertEqual(ToolApproval.afterToggle(off, approvals: approvals), approvals)
        let old = ToolApproval.Record(fingerprint: ToolApproval.fingerprint(of: approved), commands: [], needs: nil)
        XCTAssertEqual(ToolApproval.afterToggle(approved, approvals: ["r": old])["r"], ToolApproval.record(for: approved))
    }

    /// The tools the agent gets: approved and with every area they need on.
    func testActiveToolsFiltering() {
        let plain = CustomTool(id: "plain", name: "Plain", commands: ["rclip -n"], instructions: "x")
        let photos = ToolPrompts.photosLibraryExample
        let unapproved = CustomTool(id: "u", name: "U", commands: ["mdls"], instructions: "x")
        var disabled = CustomTool(id: "d", name: "D", commands: ["mdls"], instructions: "x")
        disabled.enabled = false
        let tools = [plain, photos, unapproved, disabled]
        let approvals = Dictionary(uniqueKeysWithValues: [plain, photos, disabled].map { ($0.id, ToolApproval.record(for: $0)) })
        XCTAssertEqual(PrivateDataAccess.activeTools(tools, approvals: approvals) { _ in false }.map(\.id), ["plain"])
        XCTAssertEqual(PrivateDataAccess.activeTools(tools, approvals: approvals) { $0 == .photos }.map(\.id), ["plain", "osxphotos"])
        XCTAssertEqual(PrivateDataAccess.activeTools(tools, approvals: approvals) { $0 == .mail }.map(\.id), ["plain"])
    }

    /// Container folder names found on macOS 26.3 belong to their area, and nothing else does.
    func testContainerNamesByArea() {
        let names: [PrivateDataArea: [String]] = [
            .photos: ["com.apple.photolibraryd", "com.apple.photoanalysisd", "com.apple.mediaanalysisd", "com.apple.Photos",
                      "com.apple.Photos.PhotosReliveWidget", "com.apple.CloudPhotosConfiguration",
                      "group.com.apple.photolibraryd.private", "group.com.apple.Photos.PhotosFileProvider",
                      "group.com.apple.mobileslideshow.PhotosFileProvider"],
            .messages: ["com.apple.messages", "com.apple.MessagesLegacyTransferArchive", "com.apple.MobileSMS",
                        "com.apple.MobileSMS.MessagesActionExtension", "com.apple.messages.ShareExtension", "com.apple.iChat"],
            .mail: ["com.apple.mail", "com.apple.MailPersonaStorage", "com.apple.mail.SpotlightIndexExtension",
                    "com.apple.MailCacheDelete", "group.com.apple.mail"],
            .contacts: ["group.com.apple.contacts", "com.apple.iCal", "com.apple.iCal.CalendarNC", "com.apple.reminders",
                        "com.apple.reminders.RemindersNC", "group.com.apple.calendar", "group.com.apple.reminders",
                        "com.apple.AddressBook"],
            .notes: ["group.com.apple.notes", "com.apple.Notes"],
            .safari: ["com.apple.Safari", "com.apple.Safari.SafariWidgetExtension"],
        ]
        for (area, list) in names {
            for name in list { XCTAssertEqual(PrivateDataArea.owner(ofContainer: name), area, name) }
        }
        for other in ["com.example.app", "com.apple.mailx", "com.apple.PhotosX", "group.com.apple.notes.extra",
                      "com.apple.Notesy", "com.apple.SafariTechnologyPreviewX", "com.apple.TextEdit", "6N38VWS5BX.ru.keepcoder.Telegram"] {
            XCTAssertNil(PrivateDataArea.owner(ofContainer: other), other)
        }
        XCTAssertEqual(PrivateDataArea(id: "notes"), .notes)
        XCTAssertEqual(PrivateDataArea.notes.paths(home: "/h"), ["/h/Library/Group Containers/group.com.apple.notes"])
    }

    private func makeHome(_ files: [String]) throws -> URL {
        let home = URL(fileURLWithPath: AgentSandbox.realPath(NSTemporaryDirectory())).appendingPathComponent("likely-pd-\(UUID().uuidString)")
        for file in files {
            let url = home.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        return home
    }

    private func status(_ path: String, home: URL, blocked: [PrivateDataArea], extraRules: String = "") throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", AgentSandbox.compose(profile: AgentSandbox.privacyOnlyProfile, extraRules: extraRules,
                                                        blockedAreas: blocked, home: home.path),
                             "/bin/cat", home.appendingPathComponent(path).path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    static let containerFiles: [PrivateDataArea: String] = [
        .contacts: "Library/Group Containers/group.com.apple.contacts/AddressBook.sqlite",
        .photos: "Library/Containers/com.apple.photoanalysisd/Data/x",
        .mail: "Library/Containers/com.apple.MailPersonaStorage/Data/x",
        .messages: "Library/Containers/com.apple.messages/Data/x",
        .notes: "Library/Group Containers/group.com.apple.notes/NoteStore.sqlite",
        .safari: "Library/Containers/com.apple.Safari.SafariWidgetExtension/Data/x",
    ]
    static let thirdParty = "Library/Containers/com.example.app/Data/secret"

    /// Turning an area on opens its containers even while "Other apps' private data" is off, and only
    /// those: Contacts on, app data off.
    func testContactsOnAppDataOffUnderSandboxExec() throws {
        let home = try makeHome(Array(Self.containerFiles.values) + [Self.thirdParty, "Library/Calendars/x"])
        defer { try? FileManager.default.removeItem(at: home) }
        let blocked = PrivateDataArea.allCases.filter { $0 != .contacts }
        XCTAssertEqual(try status(Self.containerFiles[.contacts]!, home: home, blocked: blocked), 0, "contacts container")
        XCTAssertEqual(try status("Library/Calendars/x", home: home, blocked: blocked), 0)
        XCTAssertNotEqual(try status(Self.thirdParty, home: home, blocked: blocked), 0, "other apps' data stays closed")
        for (area, file) in Self.containerFiles where area != .contacts {
            XCTAssertNotEqual(try status(file, home: home, blocked: blocked), 0, "\(area)")
        }
        // An eval's isolation rules (before these) still win: the exception doesn't re-open anything.
        let isolation = "(deny file-read* (subpath \(AgentSandbox.quoted(home.path + "/Library"))))"
        XCTAssertNotEqual(try status(Self.containerFiles[.contacts]!, home: home, blocked: blocked, extraRules: isolation), 0)
    }

    /// Each area's containers follow its own toggle, with app data on or off.
    func testEachAreasContainersUnderSandboxExec() throws {
        let home = try makeHome(Array(Self.containerFiles.values) + [Self.thirdParty])
        defer { try? FileManager.default.removeItem(at: home) }
        for (area, file) in Self.containerFiles {
            XCTAssertNotEqual(try status(file, home: home, blocked: PrivateDataArea.allCases), 0, "\(area) all off")
            XCTAssertNotEqual(try status(file, home: home, blocked: [area]), 0, "\(area) off, app data on")
            XCTAssertEqual(try status(file, home: home, blocked: [.appData]), 0, "\(area) on, app data off")
            XCTAssertEqual(try status(file, home: home, blocked: []), 0, "\(area) all on")
        }
        XCTAssertEqual(try status(Self.thirdParty, home: home, blocked: [.mail]), 0)
    }

    /// Full-Disk-Access-only stores stay denied with every toggle on; the login keychain file stays
    /// readable (agents' own sign-ins), its subfolders (the data-protection keychain) don't.
    func testFullDiskAccessStoresAlwaysDenied() throws {
        let stores = PrivateDataAccess.alwaysDeniedRelativePaths.map { $0 + "/x" }
        let home = try makeHome(stores + ["Library/Keychains/login.keychain-db", "Library/Keychains/0A1B-2C3D/keychain-2.db",
                                          "Documents/tax.pdf"])
        defer { try? FileManager.default.removeItem(at: home) }
        for file in stores + ["Library/Keychains/0A1B-2C3D/keychain-2.db"] {
            XCTAssertNotEqual(try status(file, home: home, blocked: []), 0, file)
        }
        XCTAssertEqual(try status("Library/Keychains/login.keychain-db", home: home, blocked: []), 0)
        XCTAssertEqual(try status("Documents/tax.pdf", home: home, blocked: []), 0)
    }

    /// Codex has no regexes: containers are found by listing, Photos libraries come from the scan.
    func testCodexEntriesEnumerateContainersAndLibraries() throws {
        let home = try makeHome(Array(Self.containerFiles.values) + [Self.thirdParty])
        defer { try? FileManager.default.removeItem(at: home) }
        let h = home.path
        func entries(_ blocked: [PrivateDataArea], libraries: [String] = []) -> [String: String] {
            Dictionary(uniqueKeysWithValues: PrivateDataAccess.codexEntries(blocked: blocked, home: h, photoLibraries: libraries)
                .map { ($0.path, $0.access) })
        }
        let contactsOn = entries(PrivateDataArea.allCases.filter { $0 != .contacts }, libraries: ["/Volumes/Ext/Old.photoslibrary"])
        XCTAssertEqual(contactsOn[h + "/Library/Containers"], "none")
        XCTAssertEqual(contactsOn[h + "/Library/Group Containers"], "none")
        XCTAssertEqual(contactsOn[h + "/Library/Group Containers/group.com.apple.contacts"], "read")
        XCTAssertEqual(contactsOn[h + "/Library/Containers/com.apple.MailPersonaStorage"], "none")
        XCTAssertEqual(contactsOn[h + "/Library/Containers/com.apple.photoanalysisd"], "none")
        XCTAssertEqual(contactsOn["/Volumes/Ext/Old.photoslibrary"], "none")
        XCTAssertNil(contactsOn[h + "/Library/Containers/com.example.app"], "covered by the Containers entry")
        XCTAssertEqual(contactsOn[h + "/Library/Cookies"], "none")
        XCTAssertEqual(contactsOn[h + "/Library/Keychains"], "none")

        let mailOff = entries([.mail])
        XCTAssertNil(mailOff[h + "/Library/Containers"], "app data on")
        XCTAssertEqual(mailOff[h + "/Library/Containers/com.apple.MailPersonaStorage"], "none")
        XCTAssertNil(mailOff[h + "/Library/Group Containers/group.com.apple.contacts"])
        XCTAssertNil(mailOff["/Volumes/Ext/Old.photoslibrary"])

        // The whole table is valid TOML-ish: every key once.
        let table = AgentSandbox.codexFilesystem(home: h, readable: [h + "/Library/Application Support/Likely/run"],
                                                 blockedAreas: PrivateDataArea.allCases.filter { $0 != .contacts },
                                                 photoLibraries: ["/Volumes/Ext/Old.photoslibrary"])
        let keys = table.components(separatedBy: "\" = \"").dropLast().map { $0.components(separatedBy: ", \"").last ?? $0 }
        XCTAssertEqual(Set(keys).count, keys.count, table)
        XCTAssertTrue(table.contains(#"/Volumes/Ext/Old.photoslibrary" = "none""#))
    }

    func testPhotoLibraryScan() throws {
        let home = try makeHome(["Pictures/Photos Library.photoslibrary/database/Photos.sqlite",
                                 "Pictures/Archive/2019.photoslibrary/x", "Projects/a/Trip.PhotosLibrary/x",
                                 "Projects/a/b/TooDeep.photoslibrary/x", "Library/Photos/Libraries/Syndication.photoslibrary/x",
                                 ".hidden/Hidden.photoslibrary/x", "Pictures/Some.app/Inner.photoslibrary/x"])
        let volumes = try makeHome(["Ext/Old.photoslibrary/x", "Ext/Photos/Family.photoslibrary/x", "Ext/a/b/Deep.photoslibrary/x"])
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: volumes)
        }
        let found = PhotoLibraryScan.find(home: home.path, volumes: volumes.path)
        XCTAssertEqual(Set(found), Set([home.path + "/Pictures/Photos Library.photoslibrary", home.path + "/Pictures/Archive/2019.photoslibrary",
                                        home.path + "/Projects/a/Trip.PhotosLibrary", volumes.path + "/Ext/Old.photoslibrary",
                                        volumes.path + "/Ext/Photos/Family.photoslibrary"]), "\(found)")
    }
}
