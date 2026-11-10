import XCTest
@testable import LikelyStorage

/// Settings that decide what Likely runs, sealed with an HMAC (SettingsSeal). In-memory key; never the Keychain.
final class SettingsSealTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var keyStore: InMemoryKeyStore!
    private var marker: InMemoryKeyStore!
    private var seal: SettingsSeal!

    override func setUp() {
        suite = "likely-seal-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        keyStore = InMemoryKeyStore()
        marker = InMemoryKeyStore()
        seal = SettingsSeal(cipher: DataCipher(store: keyStore), adoptedMarker: marker, defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        // removePersistentDomain leaves an empty plist behind.
        let plist = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/\(suite!).plist")
        try? FileManager.default.removeItem(at: plist)
    }

    func testRoundTripsStringsDataAndBools() throws {
        try seal.set("/Users/me/.local/bin/claude", forKey: "claudePath")
        try seal.set(Data([1, 2, 3]), forKey: "approvedTools")
        try seal.set(true, forKey: "allowCommandLineTests")
        XCTAssertEqual(seal.string("claudePath"), .valid("/Users/me/.local/bin/claude"))
        XCTAssertEqual(seal.data("approvedTools"), .valid(Data([1, 2, 3])))
        XCTAssertEqual(seal.bool("allowCommandLineTests"), .valid(true))
        XCTAssertEqual(seal.string("promptTemplate"), .absent)
        try seal.set(nil, forKey: "claudePath")
        XCTAssertEqual(seal.string("claudePath"), .absent)
        XCTAssertNil(defaults.object(forKey: "mac.claudePath"))
    }

    func testValueChangedOutsideLikelyIsTampered() throws {
        try seal.set("/Users/me/.local/bin/claude", forKey: "claudePath")
        // `defaults write … claudePath /tmp/evil`
        defaults.set("/tmp/evil", forKey: "claudePath")
        XCTAssertEqual(seal.string("claudePath"), .tampered)
        XCTAssertNil(seal.string("claudePath").value)
    }

    func testPlantedValueWithoutMACIsTampered() throws {
        try seal.adoptExisting(["claudePath"])   // adoption done (nothing to adopt)
        defaults.set("/tmp/evil", forKey: "claudePath")
        XCTAssertEqual(seal.string("claudePath"), .tampered)
        defaults.set("bm90IGEgbWFj", forKey: "mac.claudePath")   // a made-up MAC
        XCTAssertEqual(seal.string("claudePath"), .tampered)
    }

    func testMACCantBeMovedToAnotherKeyOrType() throws {
        try seal.set("sonnet", forKey: "model")
        defaults.set("sonnet", forKey: "codexModel")
        defaults.set(defaults.string(forKey: "mac.model"), forKey: "mac.codexModel")
        XCTAssertEqual(seal.string("codexModel"), .tampered)
        try seal.set(true, forKey: "allowCommandLineTests")
        defaults.set("YES", forKey: "allowCommandLineTests")   // a string, not a bool
        XCTAssertEqual(seal.bool("allowCommandLineTests"), .tampered)
    }

    func testAnotherKeysMACDoesntVerify() throws {
        try seal.set("/Users/me/.local/bin/claude", forKey: "claudePath")
        let other = SettingsSeal(cipher: DataCipher(store: InMemoryKeyStore(key: Data(repeating: 7, count: 32))),
                                 adoptedMarker: InMemoryKeyStore(), defaults: defaults)
        XCTAssertEqual(other.string("claudePath"), .tampered)
    }

    func testUnreadableKeyIsUnverifiableNotValid() throws {
        try seal.set("haiku", forKey: "model")
        let broken = InMemoryKeyStore()
        broken.failure = NSError(domain: "keychain", code: -25308)
        let locked = SettingsSeal(cipher: DataCipher(store: broken), adoptedMarker: InMemoryKeyStore(), defaults: defaults)
        XCTAssertEqual(locked.string("model"), .unverifiable)
        XCTAssertThrowsError(try locked.set("opus", forKey: "model"))
        XCTAssertEqual(defaults.string(forKey: "model"), "haiku", "nothing written without a key")
    }

    func testAdoptionSealsOldValuesOnceOnly() throws {
        defaults.set("You find files…", forKey: "promptTemplate")
        defaults.set("codex", forKey: "agentID")
        XCTAssertEqual(seal.string("agentID"), .tampered, "an unsealed value isn't trusted before adoption")
        XCTAssertEqual(Set(try seal.adoptExisting(["promptTemplate", "agentID", "claudePath"])), ["promptTemplate", "agentID"])
        XCTAssertEqual(seal.string("agentID"), .valid("codex"))
        XCTAssertNotNil(marker.key)
        // Later plants are never adopted: the marker (in the Keychain for the app) stays.
        defaults.set("/tmp/evil", forKey: "claudePath")
        XCTAssertEqual(try seal.adoptExisting(["claudePath"]), [])
        XCTAssertEqual(seal.string("claudePath"), .tampered)
    }
}
