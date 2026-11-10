import CryptoKit
import Foundation
import XCTest
@testable import LikelyStorage

private let redactor = LogRedactor(salt: SymmetricKey(size: .bits256))

private func hidden(_ message: LogMessage) -> String { message.rendered(details: false, redactor: redactor) }
private func shown(_ message: LogMessage) -> String { message.rendered(details: true, redactor: redactor) }

private let hashPattern = "<#[0-9a-f]{8}>"

final class LogMessageTests: XCTestCase {
    func testPrivateValuesAreHashedWithDetailsOff() {
        let query = "invoice from Dr. Smith"
        let title = "Re: biopsy results – Mail"
        let message: LogMessage = "request: \(query.count) chars \(sensitive: query) title=\(sensitive: title)"
        let line = hidden(message)
        XCTAssertFalse(line.contains("invoice"), line)
        XCTAssertFalse(line.contains("Smith"), line)
        XCTAssertFalse(line.contains("biopsy"), line)
        XCTAssertNotNil(line.range(of: "^request: 22 chars \(hashPattern) title=\(hashPattern)$", options: .regularExpression), line)
        XCTAssertTrue(message.hasPrivateValues)
        XCTAssertFalse(("plain \(3) \(public: "word")" as LogMessage).hasPrivateValues)
    }

    func testPrivateValuesAreShownWithDetailsOn() {
        let line = shown("request: \(sensitive: "invoice") in \(meta: "Safari") added \(path: "/Users/me/Taxes/2025.pdf") \(public: true ? "yes" : "no")")
        XCTAssertEqual(line, "request: invoice in Safari added /Users/me/Taxes/2025.pdf yes")
    }

    func testSameValueSameHashSoLinesCanBeFollowed() {
        let path = "/Users/me/Documents/Lease.pdf"
        let a = hidden("added \(path: path)")
        let b = hidden("skip \(path: path)")
        XCTAssertEqual(a.dropFirst("added ".count), b.dropFirst("skip ".count))
        XCTAssertNotEqual(hidden("\(sensitive: "a")"), hidden("\(sensitive: "b")"))
    }

    func testHashesAre32BitsAndDependOnTheSalt() {
        let other = LogRedactor(salt: SymmetricKey(size: .bits256))
        XCTAssertNotEqual(redactor.redact("invoice"), other.redact("invoice"))
        XCTAssertNotNil(redactor.redact("invoice").range(of: "^\(hashPattern)$", options: .regularExpression))
    }

    func testPathsKeepOnlyAPlainExtension() {
        XCTAssertNotNil(hidden("\(path: "/Users/me/Photos/IMG_2041.HEIC")").range(of: #"^<#[0-9a-f]{8} \.heic>$"#, options: .regularExpression))
        XCTAssertNotNil(hidden("\(path: URL(fileURLWithPath: "/Users/me/Notes"))").range(of: "^\(hashPattern)$", options: .regularExpression))
        let odd = hidden("\(path: "/Users/me/Meeting with J. Doe")")
        XCTAssertFalse(odd.contains("Doe"), odd)
        XCTAssertEqual(hidden("\(paths: ["/a/x.pdf", "/b/y.png"])").components(separatedBy: ", ").count, 2)
    }

    func testListsHashEachValue() {
        XCTAssertEqual(hidden("\(sensitive: ["one", "two"])"), "[\(redactor.redact("one")), \(redactor.redact("two"))]")
        XCTAssertEqual(shown("\(sensitive: ["one", "two"])"), "[one, two]")
    }

    func testSafeValuesAndNilAndEmpty() {
        let count = 3
        let ms: Double = 12.5
        let pid: Int32 = 501
        let missing: String? = nil
        let cost: Double? = nil
        XCTAssertEqual(hidden("\(count) files in \(ms) ms pid=\(pid) ok=\(true) t=\(sensitive: missing) p=\(path: missing) cost=\(cost)"),
                       "3 files in 12.5 ms pid=501 ok=true t=- p=- cost=-")
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

    func testSpotlightSkipReasonIsLeftOut() {
        let outcome = SpotlightExclusion.Outcome.skipped("/Users/me/Library/Logs/Likely is a link to /Volumes/Secret")
        XCTAssertEqual(hidden("Spotlight: \(outcome)"), "Spotlight: skipped")
    }

    func testAgentFailureKinds() {
        XCTAssertEqual(AgentFailureKind.classify("API Error: 429 Too Many Requests"), .rateLimit)
        XCTAssertEqual(AgentFailureKind.classify("Invalid API key · Please run /login"), .auth)
        XCTAssertEqual(AgentFailureKind.classify("model not found: gpt-9"), .modelNotFound)
        XCTAssertEqual(AgentFailureKind.classify("getaddrinfo ENOTFOUND api.example.com"), .network)
        XCTAssertEqual(AgentFailureKind.classify("Your credit balance is too low"), .quota)
        XCTAssertEqual(AgentFailureKind.classify("something odd about invoice.pdf"), .other)
        XCTAssertEqual(hidden("kind=\(AgentFailureKind.classify("Overloaded"))"), "kind=overloaded")
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
        XCTAssertEqual(defaults.double(forKey: LogDetailsSwitch.defaultsKey), now.addingTimeInterval(24 * 60 * 60).timeIntervalSince1970)
        now = now.addingTimeInterval(24 * 60 * 60 - 1)
        XCTAssertTrue(details.showsDetails)
        now = now.addingTimeInterval(1)
        XCTAssertFalse(details.showsDetails)
        XCTAssertNil(details.expiry)
        XCTAssertFalse(("\(sensitive: "invoice")" as LogMessage).rendered(details: details.showsDetails, redactor: redactor).contains("invoice"))
    }

    func testTheStoredValueCantTurnItOn() {
        // Something else writing Likely's preferences: the switch only trusts its own turnOn().
        defaults.set(now.addingTimeInterval(3600).timeIntervalSince1970, forKey: LogDetailsSwitch.defaultsKey)
        XCTAssertFalse(makeSwitch().showsDetails)
        let details = makeSwitch()
        details.turnOn()
        defaults.set(now.addingTimeInterval(10 * 24 * 3600).timeIntervalSince1970, forKey: LogDetailsSwitch.defaultsKey)
        XCTAssertEqual(details.expiry, now.addingTimeInterval(24 * 60 * 60))
    }

    func testClockSetBackCountsAsOff() {
        let details = makeSwitch()
        details.turnOn()
        now = now.addingTimeInterval(-3600)   // the end is now 25 hours away
        XCTAssertFalse(details.showsDetails)
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
    func testOlderFormatIsDeletedOnce() throws {
        let log = dir.appendingPathComponent("likely.log")
        try Data("request: my old plaintext query\n".utf8).write(to: log)
        try Data("old\n".utf8).write(to: dir.appendingPathComponent("likely.log.1"))
        try Data("keep\n".utf8).write(to: dir.appendingPathComponent("other.txt"))

        XCTAssertTrue(LogFile.upgrade(log: log))
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("likely.log.1").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("other.txt").path))
        XCTAssertEqual(mode(dir.appendingPathComponent(LogFile.versionFileName)), 0o600)

        // The folder records its format: the new log stays.
        try Data("new line\n".utf8).write(to: log)
        XCTAssertFalse(LogFile.upgrade(log: log))
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "new line\n")

        // An old log put back without its format file (restored from a backup) goes again.
        try FileManager.default.removeItem(at: dir.appendingPathComponent(LogFile.versionFileName))
        XCTAssertTrue(LogFile.upgrade(log: log))
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
    }

    func testClearRemovesTheDetailsLog() throws {
        let details = dir.appendingPathComponent(LogFile.detailsFileName)
        try Data("request: invoice\n".utf8).write(to: details)
        LogFile.clear(at: details)
        XCTAssertFalse(FileManager.default.fileExists(atPath: details.path))
    }
}

/// Every log line is a LogMessage whose literal type is StaticString, so a String can't go in unmarked.
/// What the compiler can't judge: whether a `meta:` value really is non-identifying, and whether a type
/// made `LogSafe` holds no user content. These keep both to a reviewed list, so a new `meta:` (or a
/// changed line with one) fails here until it's added below, deliberately.
final class LogPrivacySourceTests: XCTestCase {
    /// Each source line with `meta:` values ("<path under Sources>: <line, whitespace collapsed>") and
    /// how many. Reviewed: app names, agent ids, models, AX roles/identifiers/notification names,
    /// constants passed through String parameters (close reasons, pick methods, capture modes, refusal
    /// reasons), license/update server paths and states.
    static let reviewedMeta: [String: Int] = [
        // Fixed setting names (ProtectedSettings.keys), never user text.
        "Likely/ProtectedSettings.swift: Log.write(\"privacy\", \"can't check \\(meta: key) (Keychain); using the default\")": 1,
        "Likely/ProtectedSettings.swift: Log.write(\"privacy\", \"ignored \\(meta: key): changed outside Likely; using the default\")": 1,
        "Likely/ProtectedSettings.swift: Log.write(\"privacy\", \"couldn't save \\(meta: key): \\(error: error)\")": 1,
        "Likely/PrivateDataPermission.swift: Log.write(\"privacy\", \"\\(meta: area.rawValue): \\(public: outcome == .granted ? \"allowed\" : \"not allowed\")\")": 1,
        "Likely/PrivateDataPermission.swift: Log.write(\"privacy\", \"\\(meta: area.rawValue): blocked for agents again\")": 1,
        "Likely/AX.swift: if let id = string(element, kAXIdentifierAttribute) { line = \"\\(line) id=\\(meta: id)\" }": 1,
        "Likely/AX.swift: if let subrole = string(element, kAXSubroleAttribute) { line = \"\\(line) subrole=\\(meta: subrole)\" }": 1,
        "Likely/AX.swift: var line: LogMessage = \"\\(meta: string(element, kAXRoleAttribute) ?? \"?\")\"": 1,
        "Likely/AXWatcher.swift: Log.write(\"ax\", \"AXObserverCreate failed for \\(meta: app.localizedName) (\\(pid))\")": 1,
        "Likely/AXWatcher.swift: Log.write(\"ax\", \"\\(meta: app.localizedName) (\\(pid)) not responding, retry \\(attempt + 1)/5\")": 1,
        "Likely/AXWatcher.swift: Log.write(\"ax\", \"no notifications registered for \\(meta: app.localizedName) (\\(pid))\")": 1,
        "Likely/AXWatcher.swift: Log.write(\"ax-event\", \"\\(meta: appName): \\(meta: notification)\\(detail)\")": 2,
        "Likely/AXWatcher.swift: if verbose { Log.write(\"ax\", \"attached \\(meta: app.localizedName) (\\(pid)), \\(registered) notifications\") }": 1,
        "Likely/AgentRunner.swift: Log.write(\"codex\", \"started \\(public: arguments.first == \"exec\" && arguments.dropFirst().first == \"resume\" ? \"resume\" : \"exec\") model=\\(meta: model) pid=\\(process.processIdentifier)\")": 1,
        "Likely/Agents.swift: Log.write(\"agents\", \"found: \\(LogMessage.joined(found.sorted { $0.key < $1.key }.map { \"\\(meta: $0.key)=\\(path: $0.value)\" }))\")": 1,
        "Likely/AppDelegate.swift: Log.write(\"app\", \"onboarding finished, agent=\\(meta: Settings.agentID)\")": 1,
        "Likely/AppDelegate.swift: Log.write(\"app\", \"opened by \\(meta: url.scheme)://\\(meta: url.host)\")": 2,
        "Likely/AppDelegate.swift: Log.write(\"app\", \"showing onboarding at step \\(meta: LikelyOnboardingStep.saved.rawValue)\")": 1,
        "Likely/ClaudeRunner.swift: Log.write(\"claude\", \"started \\(path: claudePath) model=\\(meta: model) pid=\\(process.processIdentifier)\")": 1,
        "Likely/Coordinator.swift: : \"\\(meta: agentName) error kind=\\(AgentFailureKind.classify(outcome.summary)) – \\(sensitive: outcome.summary.prefix(60))\"": 1,
        "Likely/Coordinator.swift: Log.write(\"capture\", \"\\(meta: capture.mode) title=\\(sensitive: capture.windowTitle)\")": 1,
        "Likely/Coordinator.swift: Log.write(\"detect\", \"\\(meta: appName) \\(meta: notification) \\(AX.describe(window)) → \\(verdict.logLine)\")": 2,
        "Likely/Coordinator.swift: Log.write(\"detect\", \"panel service window #\\(window.id) while \\(meta: picker.appName) is frontmost\")": 1,
        "Likely/Coordinator.swift: Log.write(\"evals\", \"picker closed without a confirmed pick (\\(meta: pick.how))\")": 1,
        "Likely/Coordinator.swift: Log.write(\"picker\", \"CLOSED in \\(meta: picker.appName) (\\(meta: reason))\")": 2,
        "Likely/Coordinator.swift: Log.write(\"picker\", \"OPENED in \\(meta: picker.appName) via \\(meta: picker.source) frame=\\(picker.frame) title=\\(sensitive: picker.windowTitle)\")": 2,
        "Likely/Coordinator.swift: Log.write(\"picker\", \"picked \\(picked.count) (\\(meta: pick.how)): \\(paths: picked)\")": 1,
        "Likely/Coordinator.swift: Log.write(\"recent\", \"\\(added.count) via \\(meta: result.source) in \\(result.milliseconds) ms: \\(paths: added)\")": 1,
        "Likely/Coordinator.swift: let logged: LogMessage = outcome.success ? \"\\(meta: message)\"": 1,
        "Likely/DataProtection.swift: Log.write(\"privacy\", \"\\(meta: initial.summary)\")": 1,
        "Likely/DataProtection.swift: Log.write(\"privacy\", \"\\(meta: new.summary)\")": 1,
        "Likely/GeminiRunner.swift: Log.write(\"gemini\", \"started \\(public: arguments.contains(\"--resume\") ? \"resume\" : \"new\") model=\\(meta: model) project=\\(sensitive: Self.vertexProject) location=\\(meta: Self.vertexLocation) pid=\\(process.processIdentifier)\")": 2,
        "Likely/HermesRunner.swift: Log.write(\"hermes\", \"\\(meta: arguments.prefix(4).joined(separator: \" \")) → \\(process.terminationStatus)\")": 1,
        "Likely/HermesRunner.swift: Log.write(\"hermes\", \"not started: \\(meta: problem)\")": 1,
        "Likely/HermesRunner.swift: Log.write(\"hermes\", \"started session=\\(meta: sessionName) model=\\(meta: model) pid=\\(process.processIdentifier)\")": 2,
        "Likely/License.swift: Log.write(\"license\", \"entitlement active=\\(entitlement.active) kind=\\(meta: entitlement.kind) status=\\(meta: entitlement.status)\")": 2,
        "Likely/LicenseClient.swift: Log.write(\"license\", \"\\(meta: path) got 401, logging in again\")": 1,
        "Likely/LicenseClient.swift: Log.write(\"license\", \"\\(meta: request.httpMethod) \\(meta: request.url?.path) -> \\(status) \\(sensitive: message)\")": 2,
        "Likely/LicenseClient.swift: Log.write(\"license\", \"\\(meta: request.url?.path) failed: \\(error: error)\")": 1,
        "Likely/LicenseClient.swift: Log.write(\"license\", \"\\(meta: request.url?.path) undecodable: \\(error: error)\")": 1,
        "Likely/LicenseClient.swift: Log.write(\"license\", \"refused session URL host=\\(meta: URL(string: string)?.host)\")": 1,
        "Likely/LikelyFolder.swift: Log.write(\"likely\", \"skip \\(path: source) (opened \\(path: item.realPath): \\(meta: reason))\")": 1,
        "Likely/LikelyFolder.swift: if reason != \"in the Likely folder\" { Log.write(\"likely\", \"skip \\(path: source) (\\(meta: reason))\") }": 1,
        "Likely/MenuBarGlyph.swift: Log.write(\"app\", \"menu bar glyph: \\(meta: debugSelection ?? \"default\")\")": 1,
        "Likely/OpenCodeRunner.swift: Log.write(\"opencode\", \"started \\(public: arguments.contains(\"-s\") ? \"resume\" : \"run\") model=\\(meta: model) pid=\\(process.processIdentifier)\")": 1,
        "Likely/PickerHeuristics.swift: Log.write(\"picker-diag\", \"attributes: \\(meta: names.joined(separator: \", \"))\")": 1,
        "Likely/PickerHeuristics.swift: Log.write(\"picker-diag\", \"probe \\(meta: attribute) = \\(sensitive: value)\")": 1,
        "Likely/PickerHeuristics.swift: return Verdict(isPicker: false, reason: \"identifier=\\(meta: identifier)\")": 1,
        "Likely/PickerHeuristics.swift: return Verdict(isPicker: false, reason: \"role \\(meta: role ?? \"nil\")\")": 1,
        "Likely/PickerHeuristics.swift: return Verdict(isPicker: true, reason: \"identifier=\\(meta: identifier)\", buttonTitle: defaultButtonTitle(window))": 1,
        "Likely/PickerHeuristics.swift: return known ? \"\\(meta: title)\" : \"\\(sensitive: title)\"": 1,
        "Likely/PickerNavigator.swift: Log.write(\"navigate\", \"gave up: \\(meta: why). Is ~/Likely pinned in the Finder sidebar?\")": 1,
        "Likely/Updater.swift: Log.write(\"update\", \"updater started, feed \\(meta: controller.updater.feedURL?.absoluteString)\")": 1,
        "Likely/WindowList.swift: Log.write(\"cg-window\", \"appeared #\\(id) owner=\\(meta: window.owner)(\\(window.pid)) layer=\\(window.layer) name=\\(sensitive: window.name) bounds=\\(window.bounds)\\(public: fromService ? \" [PANEL SERVICE]\" : \"\")\")": 1,
        "Likely/WindowList.swift: Log.write(\"cg-window\", \"disappeared #\\(id) owner=\\(meta: window.owner)(\\(window.pid))\")": 1,
    ]

    /// Every type made `LogSafe` (all in LogPrivacy.swift, each with its own logDescription).
    static let logSafeTypes: Set<String> = [
        "Int", "Int32", "Int64", "UInt", "UInt32", "UInt64", "Double", "Float", "Bool", "CGFloat", "CGRect",
        "SpotlightExclusion.Outcome",
    ]

    /// Files that may write to a log, stdout or stderr other than through Log.write.
    static let otherLogging: Set<String> = [
        "Likely/Log.swift",               // Log.write itself
        "Likely/Evals/EvalCLI.swift",     // dev builds only
        "OnboardingKit/CopyEditor.swift", // its save error, domain and code only
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
        return files.sorted { $0.0 < $1.0 }
    }

    private static func count(_ pattern: String, in text: String) -> Int {
        (try? NSRegularExpression(pattern: pattern))?.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) ?? 0
    }

    /// `meta:` uses per source line, any spacing (`\( meta : x)`).
    static func metaUses(path: String, text: String) -> [String: Int] {
        var uses: [String: Int] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let n = count(#"\\\(\s*meta\s*:"#, in: String(line))
            if n > 0 { uses[path + ": " + line.split(whereSeparator: \.isWhitespace).joined(separator: " "), default: 0] += n }
        }
        return uses
    }

    func testEveryMetaValueWasReviewed() throws {
        var seen: [String: Int] = [:]
        for (path, text) in try Self.swiftFiles() where path != "LikelyStorage/LogPrivacy.swift" {
            seen.merge(Self.metaUses(path: path, text: text)) { $0 + $1 }
        }
        let unreviewed = seen.filter { Self.reviewedMeta[$0.key] != $0.value }.keys.sorted()
        XCTAssertEqual(unreviewed, [], """
            Lines logging meta: values that aren't on the reviewed list in LogPrivacySourceTests (or with more \
            of them). If one can hold what the user typed, a window title, a path or file name, or agent text, \
            use sensitive: or path: instead; a constant can use public:. Otherwise add the line to reviewedMeta.
            """)
        XCTAssertEqual(Set(Self.reviewedMeta.keys).subtracting(seen.keys).sorted(), [], "reviewed lines no longer in the code: remove them")
    }

    func testOnlyLogPrivacyBuildsMessagesFromStrings() throws {
        // The ways around the StaticString literal type: building a LogMessage or its interpolation by hand.
        for (path, text) in try Self.swiftFiles() where path != "LikelyStorage/LogPrivacy.swift" {
            for pattern in [#"stringLiteral\s*:"#, #"appendLiteral\s*\("#, #"StringInterpolation\s*\("#, #"\.init\s*\(\s*stringInterpolation"#] {
                XCTAssertEqual(Self.count(pattern, in: text), 0, "\(path) uses \(pattern); write log lines as literals")
            }
        }
    }

    func testLogSafeTypesAreReviewed() throws {
        let files = try Self.swiftFiles()
        let privacy = try XCTUnwrap(files.first { $0.path == "LikelyStorage/LogPrivacy.swift" }).text
        // extension <Type>: LogSafe { … logDescription … }
        let regex = try NSRegularExpression(pattern: #"extension\s+([\w.]+)\s*:\s*LogSafe\s*\{"#)
        var declared = Set<String>()
        for match in regex.matches(in: privacy, range: NSRange(privacy.startIndex..., in: privacy)) {
            let name = String(privacy[Range(match.range(at: 1), in: privacy)!])
            declared.insert(name)
            let after = privacy[Range(match.range, in: privacy)!.upperBound...]
            let body = after.prefix(while: { $0 != "}" }) + after.drop(while: { $0 != "}" }).prefix(400)
            XCTAssertTrue(body.contains("logDescription"), "\(name) must give its own logDescription")
        }
        XCTAssertEqual(declared, Self.logSafeTypes, "LogSafe types changed: review them (an enum case carrying text must leave it out)")
        XCTAssertEqual(Self.count(#"extension\s+[\w.]+\s*:[^{\n]*\bLogSafe\b(?!Enum)"#, in: privacy), declared.count,
                       "a LogSafe conformance that isn't an `extension X: LogSafe {` block")
        XCTAssertEqual(Self.count(#"(enum|struct|class)\s+\w+[^{\n]*\bLogSafe\b(?!Enum)"#, in: privacy), 0, "declare LogSafe in an extension")

        for (path, text) in files where path != "LikelyStorage/LogPrivacy.swift" {
            XCTAssertEqual(Self.count(#"\bLogSafe\b(?!Enum)"#, in: text), 0, "\(path) mentions LogSafe; declare conformances in LogPrivacy.swift")
            // LogSafeEnum is for String-backed enums only (constant raw values, no associated values).
            XCTAssertEqual(Self.count(#"(:|,)\s*LogSafeEnum\b"#, in: text), Self.count(#"enum\s+\w+\s*:\s*String\s*,\s*LogSafeEnum\b"#, in: text),
                           "\(path): LogSafeEnum only on `enum X: String, LogSafeEnum`")
        }
    }

    func testNothingLogsAroundLogWrite() throws {
        let patterns = [
            #"\b(NSLog|os_log|print|debugPrint|dump|fputs|fprintf|printf|puts|perror)\s*\("#,
            #"\bLogger\s*\("#,
            #"FileHandle\s*\.\s*standard(Error|Output)\b"#,
            #"\bwrite\s*\(\s*(1|2|STDOUT_FILENO|STDERR_FILENO)\s*,"#,
            #"\b(fatalError|preconditionFailure|assertionFailure|precondition|assert)\s*\([^\n]*\\\("#,
        ]
        for (path, text) in try Self.swiftFiles() where !Self.otherLogging.contains(path) {
            for pattern in patterns {
                XCTAssertEqual(Self.count(pattern, in: text), 0, "\(path) matches \(pattern): use Log.write so private values get redacted")
            }
        }
    }

    func testTheScannersSeeSpacingVariants() {
        let uses = Self.metaUses(path: "x", text: #"Log.write("a", "\(meta: a) \( meta : b) \(meta:c)")"#)
        XCTAssertEqual(uses.values.first, 3)
    }
}
