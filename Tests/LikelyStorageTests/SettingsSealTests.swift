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
        seal = SettingsSeal(cipher: DataCipher(store: keyStore), adoptedMarker: marker, defaults: defaults, domain: suite)
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

    func testPlantedValueWithoutMACIsIgnored() throws {
        try seal.adoptExisting(["claudePath"])   // adoption done (nothing to adopt)
        defaults.set("/tmp/evil", forKey: "claudePath")
        XCTAssertEqual(seal.string("claudePath"), .unsealed)
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
        XCTAssertEqual(seal.string("agentID"), .unverifiable, "an unsealed value isn't trusted before adoption")
        XCTAssertEqual(Set(try seal.adoptExisting(["promptTemplate", "agentID", "claudePath"]).adopted), ["promptTemplate", "agentID"])
        XCTAssertEqual(seal.string("agentID"), .valid("codex"))
        XCTAssertNotNil(marker.key)
        // Later plants are never adopted: the marker (in the Keychain for the app) stays.
        defaults.set("/tmp/evil", forKey: "claudePath")
        XCTAssertEqual(try seal.adoptExisting(["claudePath"]), SettingsSeal.Adoption())
        XCTAssertEqual(seal.string("claudePath"), .unsealed)
    }

    // MARK: Builds that can't seal (finding 1a)

    func testUnprofiledBuildWriteReadsAsUnsealedNotTampered() throws {
        try seal.adoptExisting([])
        try seal.set("You find files…", forKey: "promptTemplate")
        // An unprofiled ./build.sh or a free build saves a new prompt: it removes the stale MAC.
        SettingsSeal.writeUnsealed("My own prompt", forKey: "promptTemplate", defaults: defaults)
        XCTAssertNil(defaults.object(forKey: "mac.promptTemplate"))
        XCTAssertEqual(seal.string("promptTemplate"), .unsealed)
        // An older version (before seals, e.g. after a downgrade) leaves the MAC: that reads as tampered.
        try seal.set("sonnet", forKey: "model")
        defaults.set("opus", forKey: "model")
        XCTAssertEqual(seal.string("model"), .tampered)
        // Removing a value removes its MAC too.
        SettingsSeal.writeUnsealed(nil, forKey: "model", defaults: defaults)
        XCTAssertNil(defaults.object(forKey: "model"))
        XCTAssertNil(defaults.object(forKey: "mac.model"))
        XCTAssertEqual(seal.string("model"), .absent)
    }

    func testKeepSealsOnlyTheValueTheUserSaw() throws {
        try seal.adoptExisting([])
        SettingsSeal.writeUnsealed("My own prompt", forKey: "promptTemplate", defaults: defaults)
        XCTAssertEqual(seal.storedValue("promptTemplate") as? String, "My own prompt")
        // Changed again after Settings showed it: nothing is sealed.
        defaults.set("Something else", forKey: "promptTemplate")
        XCTAssertFalse(try seal.keep("promptTemplate", expected: "My own prompt"))
        XCTAssertEqual(seal.string("promptTemplate"), .unsealed)
        XCTAssertTrue(try seal.keep("promptTemplate", expected: "Something else"))
        XCTAssertEqual(seal.string("promptTemplate"), .valid("Something else"))
        // Data and bools too.
        defaults.set(Data([9]), forKey: "approvedTools")
        XCTAssertTrue(try seal.keep("approvedTools", expected: Data([9])))
        XCTAssertEqual(seal.data("approvedTools"), .valid(Data([9])))
    }

    // MARK: Adoption (findings 3, 4, 5)

    func testAdoptionReadsOnlyThePersistentDomain() throws {
        // What a `-agentID codex` launch argument or the global domain looks like to object(forKey:): a
        // value outside the app's persistent domain. (The registration domain is shared by the whole
        // process, so these keys are this test's own.)
        let planted = "plantedAgent-\(UUID().uuidString)"
        defaults.register(defaults: [planted: "codex"])
        XCTAssertEqual(defaults.string(forKey: planted), "codex")
        defaults.set("haiku", forKey: "model")
        XCTAssertEqual(try seal.adoptExisting([planted, "model"]).adopted, ["model"])
        XCTAssertEqual(seal.string("model"), .valid("haiku"))
        XCTAssertEqual(seal.string(planted), .unsealed)
    }

    func testAllowCommandLineTestsIsNeverAdopted() throws {
        defaults.set(true, forKey: "allowCommandLineTests")
        defaults.set("codex", forKey: "agentID")
        XCTAssertEqual(try seal.adoptExisting(["allowCommandLineTests", "agentID"]).adopted, ["agentID"])
        XCTAssertEqual(seal.bool("allowCommandLineTests"), .unsealed)
        XCTAssertNil(seal.bool("allowCommandLineTests").value)
    }

    func testBeforeAdoptionNoMACIsUnverifiableAndAdoptionIsRetried() throws {
        defaults.set("codex", forKey: "agentID")
        // Keychain locked at launch: the marker can't be read, so adoption can't run.
        marker.failure = NSError(domain: "keychain", code: -25308)
        XCTAssertThrowsError(try seal.adoptExisting(["agentID"]))
        XCTAssertEqual(seal.string("agentID"), .unverifiable, "not tampered: adoption will seal it")
        XCTAssertNil(marker.key)
        // The data key can't be read either: adoption doesn't write the marker.
        marker.failure = nil
        keyStore.failure = NSError(domain: "keychain", code: -25308)
        XCTAssertThrowsError(try seal.adoptExisting(["agentID"]))
        XCTAssertNil(marker.key, "no marker until the values could be sealed")
        XCTAssertEqual(seal.string("agentID"), .unverifiable)
        // The Keychain answers again: the retry adopts.
        keyStore.failure = nil
        XCTAssertEqual(try seal.adoptExisting(["agentID"]).adopted, ["agentID"])
        XCTAssertEqual(seal.string("agentID"), .valid("codex"))
        XCTAssertTrue(try seal.adoptionComplete())
    }

    func testAdoptionSkipsKeysItCantSealAndStillWritesTheMarker() throws {
        defaults.set(42, forKey: "agentID")                 // a number: not a type Likely stores
        defaults.set(["a", "b"], forKey: "claudePath")       // an array
        defaults.set("opus", forKey: "model")
        let result = try seal.adoptExisting(["agentID", "claudePath", "model"])
        XCTAssertEqual(result.adopted, ["model"])
        XCTAssertEqual(Set(result.skipped), ["agentID", "claudePath"])
        XCTAssertNotNil(marker.key)
        XCTAssertEqual(seal.string("model"), .valid("opus"))
        XCTAssertNil(seal.string("agentID").value)
    }

    func testValueAlreadySealedIsntAdoptedAgain() throws {
        try seal.set("sonnet", forKey: "model")
        XCTAssertEqual(try seal.adoptExisting(["model"]).adopted, [])
        XCTAssertEqual(seal.string("model"), .valid("sonnet"))
    }
}
