import CryptoKit
import Foundation
import XCTest
@testable import LikelyStorage

private let redactor = LogRedactor(salt: SymmetricKey(size: .bits256))

private func hidden(_ message: LogMessage) -> String { message.rendered(details: false, redactor: redactor) }
private func shown(_ message: LogMessage) -> String { message.rendered(details: true, redactor: redactor) }

final class LogMessageTests: XCTestCase {
    func testPrivateValuesAreHashedWithDetailsOff() {
        let query = "invoice from Dr. Smith"
        let title = "Re: biopsy results – Mail"
        let line = hidden("request: \(query.count) chars \(sensitive: query) title=\(sensitive: title)")
        XCTAssertFalse(line.contains("invoice"), line)
        XCTAssertFalse(line.contains("Smith"), line)
        XCTAssertFalse(line.contains("biopsy"), line)
        XCTAssertTrue(line.hasPrefix("request: 22 chars <#"), line)
        XCTAssertNotNil(line.range(of: #"^request: 22 chars <#[0-9a-f]{6}> title=<#[0-9a-f]{6}>$"#, options: .regularExpression), line)
    }

    func testPrivateValuesAreShownWithDetailsOn() {
        let line = shown("request: \(sensitive: "invoice") in \(public: "Safari") added \(path: "/Users/me/Taxes/2025.pdf")")
        XCTAssertEqual(line, "request: invoice in Safari added /Users/me/Taxes/2025.pdf")
    }

    func testSameValueSameHashSoLinesCanBeFollowed() {
        let path = "/Users/me/Documents/Lease.pdf"
        let a = hidden("added \(path: path)")
        let b = hidden("skip \(path: path)")
        XCTAssertEqual(a.dropFirst("added ".count), b.dropFirst("skip ".count))
        XCTAssertNotEqual(hidden("\(sensitive: "a")"), hidden("\(sensitive: "b")"))
    }

    func testHashesDependOnTheSalt() {
        let other = LogRedactor(salt: SymmetricKey(size: .bits256))
        XCTAssertNotEqual(redactor.redact("invoice"), other.redact("invoice"))
    }

    func testPathsKeepOnlyAPlainExtension() {
        XCTAssertNotNil(hidden("\(path: "/Users/me/Photos/IMG_2041.HEIC")").range(of: #"^<#[0-9a-f]{6} \.heic>$"#, options: .regularExpression))
        XCTAssertNotNil(hidden("\(path: URL(fileURLWithPath: "/Users/me/Notes"))").range(of: #"^<#[0-9a-f]{6}>$"#, options: .regularExpression))
        // Something after the last dot that isn't an extension is part of the name.
        let odd = hidden("\(path: "/Users/me/Meeting with J. Doe")")
        XCTAssertFalse(odd.contains("Doe"), odd)
        XCTAssertEqual(hidden("\(paths: ["/a/x.pdf", "/b/y.png"])").components(separatedBy: ", ").count, 2)
    }

    func testListsHashEachValue() {
        let line = hidden("\(sensitive: ["one", "two"])")
        XCTAssertEqual(line, "[\(redactor.redact("one")), \(redactor.redact("two"))]")
        XCTAssertEqual(shown("\(sensitive: ["one", "two"])"), "[one, two]")
    }

    func testSafeValuesAndNilAndEmpty() {
        let count = 3
        let ms: Double = 12.5
        let pid: Int32 = 501
        let missing: String? = nil
        XCTAssertEqual(hidden("\(count) files in \(ms) ms pid=\(pid) ok=\(true) t=\(sensitive: missing) p=\(path: missing)"),
                       "3 files in 12.5 ms pid=501 ok=true t=- p=-")
        XCTAssertEqual(hidden("\(sensitive: "")"), "<empty>")
        XCTAssertEqual(hidden("\(CGRect(x: 10, y: 20, width: 300, height: 200))"), "10,20 300x200")
    }

    func testErrorsKeepDomainAndCodeOnly() {
        let error = NSError(domain: NSCocoaErrorDomain, code: 260,
                            userInfo: [NSFilePathErrorKey: "/Users/me/Secret plans.txt",
                                       NSLocalizedDescriptionKey: "The file “Secret plans.txt” couldn’t be opened."])
        let line = hidden("copy failed: \(error: error)")
        XCTAssertTrue(line.hasPrefix("copy failed: NSCocoaErrorDomain 260 (<#"), line)
        XCTAssertFalse(line.contains("Secret"), line)
        XCTAssertTrue(shown("\(error: error)").contains("Secret plans"))
    }

    func testErrnoIsItsFixedMessage() {
        XCTAssertEqual(hidden("\(errno: ENOENT)"), "No such file or directory (2)")
    }

    func testEmbeddedMessagesKeepTheirMarks() {
        let detail: LogMessage = "title=\(sensitive: "Payroll.xlsx")"
        let line = hidden("AXWindow \(detail) → \(LogMessage.joined(["\(public: "Open")", "\(sensitive: "Send to Bob")"]))")
        XCTAssertFalse(line.contains("Payroll"), line)
        XCTAssertFalse(line.contains("Bob"), line)
        XCTAssertTrue(line.contains("→ Open, <#"), line)
    }
}

final class LogDetailsSwitchTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private var now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        suite = "likely-log-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private func makeSwitch(alwaysOn: Bool = false) -> LogDetailsSwitch {
        LogDetailsSwitch(defaults: defaults, alwaysOn: alwaysOn, now: { [unowned self] in self.now })
    }

    func testOffByDefault() {
        let details = makeSwitch()
        XCTAssertFalse(details.showsDetails)
        XCTAssertNil(details.expiry)
    }

    func testTurnsItselfOffAfter24Hours() {
        let details = makeSwitch()
        details.turnOn()
        XCTAssertTrue(details.showsDetails)
        XCTAssertEqual(details.expiry, now.addingTimeInterval(24 * 60 * 60))
        now = now.addingTimeInterval(24 * 60 * 60 - 1)
        XCTAssertTrue(details.showsDetails)
        now = now.addingTimeInterval(1)
        XCTAssertFalse(details.showsDetails)
        XCTAssertNil(details.expiry)
        // A redaction decision made then hides values again.
        XCTAssertFalse(("\(sensitive: "invoice")" as LogMessage).rendered(details: details.showsDetails, redactor: redactor).contains("invoice"))
    }

    func testTurnOff() {
        let details = makeSwitch()
        details.turnOn()
        details.turnOff()
        XCTAssertFalse(details.showsDetails)
        XCTAssertNil(defaults.object(forKey: LogDetailsSwitch.defaultsKey))
    }

    func testDevBuildsAlwaysShowDetails() {
        let details = makeSwitch(alwaysOn: true)
        XCTAssertTrue(details.showsDetails)
        XCTAssertFalse(details.isSwitchedOn)
    }
}

final class LogFileTests: TempDirTestCase {
    func testLegacyContentIsDiscardedOnce() throws {
        let suite = "likely-log-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = dir.appendingPathComponent("likely.log")
        try Data("request: my old plaintext query\n".utf8).write(to: log)
        try Data("old\n".utf8).write(to: dir.appendingPathComponent("likely.log.1"))
        try Data("keep\n".utf8).write(to: dir.appendingPathComponent("other.txt"))

        XCTAssertTrue(LogFile.discardLegacyContent(at: log, defaults: defaults))
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("likely.log.1").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("other.txt").path))

        // Later launches leave the new log alone.
        try Data("new line\n".utf8).write(to: log)
        XCTAssertFalse(LogFile.discardLegacyContent(at: log, defaults: defaults))
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "new line\n")
    }
}

/// Every log line is a LogMessage, so a String interpolated without a label doesn't compile. What the
/// compiler can't judge is whether a value marked `public:` really is safe, or whether a type made
/// `LogSafe` holds no user content. This keeps both to a reviewed list: a new `public:` (or a changed
/// one) fails here until it's added below, deliberately.
final class LogPrivacySourceTests: XCTestCase {
    /// "<path under Sources>: <expression>", whitespace collapsed.
    static let reviewedPublic: Set<String> = [
        // Accessibility roles, subroles, identifiers, notification names, attribute names: set by apps' UI frameworks.
        "Likely/AX.swift: id",
        "Likely/AX.swift: string(element, kAXRoleAttribute) ?? \"?\"",
        "Likely/AX.swift: subrole",
        "Likely/AXWatcher.swift: notification",
        "Likely/Coordinator.swift: notification",
        "Likely/PickerHeuristics.swift: attribute",
        "Likely/PickerHeuristics.swift: identifier",
        "Likely/PickerHeuristics.swift: role ?? \"nil\"",
        "Likely/PickerHeuristics.swift: names.joined(separator: \", \")",
        // Only titles from the fixed Open/Cancel/Save list (buttonForLog).
        "Likely/PickerHeuristics.swift: title",
        // App names: the picker's host app, apps being watched, window owners.
        "Likely/AXWatcher.swift: app.localizedName",
        "Likely/AXWatcher.swift: appName",
        "Likely/Coordinator.swift: appName",
        "Likely/Coordinator.swift: picker.appName",
        "Likely/WindowList.swift: window.owner",
        // Agents, models, settings values.
        "Likely/Agents.swift: $0.key",
        "Likely/AgentRunner.swift: model",
        "Likely/ClaudeRunner.swift: model",
        "Likely/GeminiRunner.swift: model",
        "Likely/HermesRunner.swift: model",
        "Likely/OpenCodeRunner.swift: model",
        "Likely/GeminiRunner.swift: Self.vertexLocation",
        "Likely/AppDelegate.swift: Settings.agentID",
        "Likely/AppDelegate.swift: LikelyOnboardingStep.saved.rawValue",
        "Likely/MenuBarGlyph.swift: debugSelection ?? \"default\"",
        "Likely/Coordinator.swift: agentName",
        // Fixed words and messages built from constants and counts.
        "Likely/AgentRunner.swift: arguments.first == \"exec\" && arguments.dropFirst().first == \"resume\" ? \"resume\" : \"exec\"",
        "Likely/GeminiRunner.swift: arguments.contains(\"--resume\") ? \"resume\" : \"new\"",
        "Likely/OpenCodeRunner.swift: arguments.contains(\"-s\") ? \"resume\" : \"run\"",
        "Likely/HermesRunner.swift: arguments.prefix(4).joined(separator: \" \")",   // Likely's own profile commands
        "Likely/HermesRunner.swift: problem",       // built from the profile name
        "Likely/HermesRunner.swift: sessionName",   // likely-<random>
        "Likely/AppDelegate.swift: on ? \"on for 24 hours\" : \"off\"",
        "Likely/AppDelegate.swift: why",
        "Likely/AppDelegate.swift: url.scheme",     // likely:// links
        "Likely/AppDelegate.swift: url.host",
        "Likely/Coordinator.swift: capture.mode",   // "live capture of window #12"
        "Likely/Coordinator.swift: message",        // "Done – found 3 files"
        "Likely/Coordinator.swift: outcome.costUSD.map { String(format: \"$%.4f\", $0) }",
        "Likely/Coordinator.swift: pick.how",       // "confirmed with Return"
        "Likely/Coordinator.swift: picker.source",  // "ax:AXWindowCreated"
        "Likely/Coordinator.swift: reason",         // why the picker closed
        "Likely/Coordinator.swift: result.source",  // "spotlight", "folders"
        "Likely/LikelyFolder.swift: reason",        // SensitivePaths' fixed reasons
        "Likely/PickerNavigator.swift: why",
        "Likely/PickerHeuristics.swift: isPicker ? \"PICKER\" : \"no\"",
        "Likely/WindowList.swift: fromService ? \" [PANEL SERVICE]\" : \"\"",
        "Likely/Evals/SearchHistorySettings.swift: entry.picked.isEmpty ? \"no pick\" : \"picked\"",
        "Likely/DataProtection.swift: state.summary",   // encryption on/off and why
        // License and update servers: API paths, hosts, states.
        "Likely/License.swift: active ? \"active\" : \"inactive\"",
        "Likely/License.swift: entitlement.kind",
        "Likely/License.swift: entitlement.status",
        "Likely/LicenseClient.swift: URL(string: string)?.host",
        "Likely/LicenseClient.swift: path",
        "Likely/LicenseClient.swift: request.httpMethod",
        "Likely/LicenseClient.swift: request.url?.path",
        "Likely/Updater.swift: controller.updater.feedURL?.absoluteString",
    ]

    /// Files that may declare `LogSafe` conformances.
    static let logSafeDeclarations: Set<String> = ["LikelyStorage/LogPrivacy.swift"]

    /// Files that may write to a log other than through Log.write.
    static let otherLogging: Set<String> = [
        "Likely/Log.swift",               // Log.write's own unified-log line (already redacted)
        "Likely/Evals/EvalCLI.swift",     // dev builds only
        "OnboardingKit/CopyEditor.swift", // copy editor's save error (dev tool)
    ]

    private static var sourcesURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    private static func swiftFiles() throws -> [(path: String, text: String)] {
        let root = sourcesURL
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        var files: [(String, String)] = []
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let relative = String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
            files.append((relative, try String(contentsOf: url, encoding: .utf8)))
        }
        XCTAssertGreaterThan(files.count, 20, "didn't find the sources at \(root.path)")
        return files
    }

    /// The expression in each `\(public: …)`, up to its matching parenthesis (string literals skipped).
    static func publicExpressions(in text: String) -> [String] {
        let chars = Array(text)
        let marker = Array("\\(public:")
        var found: [String] = []
        var i = 0
        while i + marker.count <= chars.count {
            guard Array(chars[i..<i + marker.count]) == marker else { i += 1; continue }
            var j = i + marker.count
            var depth = 1
            var inString = false
            while j < chars.count, depth > 0 {
                let c = chars[j]
                if inString {
                    if c == "\\" { j += 1 } else if c == "\"" { inString = false }
                } else if c == "\"" {
                    inString = true
                } else if c == "(" {
                    depth += 1
                } else if c == ")" {
                    depth -= 1
                }
                j += 1
            }
            let expression = String(chars[(i + marker.count)..<(j - 1)])
            found.append(expression.split(whereSeparator: \.isWhitespace).joined(separator: " "))
            i = j
        }
        return found
    }

    func testEveryPublicValueWasReviewed() throws {
        var seen = Set<String>()
        var unreviewed: [String] = []
        for (path, text) in try Self.swiftFiles() where path != "LikelyStorage/LogPrivacy.swift" {
            for expression in Self.publicExpressions(in: text) {
                let key = "\(path): \(expression)"
                seen.insert(key)
                if !Self.reviewedPublic.contains(key) { unreviewed.append(key) }
            }
        }
        XCTAssertEqual(unreviewed, [], """
            Values logged as public: that aren't on the reviewed list in LogPrivacySourceTests. If one can hold \
            what the user typed, a window title, a path or file name, or agent text, use sensitive: or path: \
            instead; otherwise add it to reviewedPublic.
            """)
        XCTAssertEqual(Self.reviewedPublic.subtracting(seen).sorted(), [], "reviewed entries no longer in the code: remove them")
    }

    func testLogSafeIsOnlyDeclaredInLogPrivacy() throws {
        for (path, text) in try Self.swiftFiles() where !Self.logSafeDeclarations.contains(path) {
            XCTAssertNil(text.range(of: #"(:|,)\s*LogSafe\b"#, options: .regularExpression),
                         "\(path) makes a type LogSafe; declare it in LogPrivacy.swift so it gets reviewed")
        }
    }

    func testNothingLogsAroundLogWrite() throws {
        let pattern = #"\b(NSLog|os_log|print|debugPrint)\(|Logger\(|\.standardError\.write"#
        for (path, text) in try Self.swiftFiles() where !Self.otherLogging.contains(path) {
            XCTAssertNil(text.range(of: pattern, options: .regularExpression),
                         "\(path) logs outside Log.write; use Log.write so private values get redacted")
        }
    }

    func testTheScannerFindsNestedExpressions() {
        let text = #"Log.write("x", "a \(public: f("(", g(1)) ? "b)" : "c") d \(public: name)")"#
        XCTAssertEqual(Self.publicExpressions(in: text), [#"f("(", g(1)) ? "b)" : "c""#, "name"])
    }
}
