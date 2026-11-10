import XCTest
@testable import LikelyStorage

/// Settings → Tests → Run Tests' one-time permission for the `--eval` child (RunToken). In-memory key;
/// never the Keychain.
final class RunTokenTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var seal: SettingsSeal!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        suite = "likely-runtoken-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        seal = SettingsSeal(cipher: DataCipher(store: InMemoryKeyStore()), adoptedMarker: InMemoryKeyStore(key: Data([1])),
                            defaults: defaults, domain: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        let plist = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/\(suite!).plist")
        try? FileManager.default.removeItem(at: plist)
    }

    func testTokenWorksOnceThenIsGone() throws {
        let token = try RunToken.issue(seal: seal, defaults: defaults, now: now)
        XCTAssertTrue(RunToken.isWellFormed(token))
        XCTAssertFalse((defaults.string(forKey: RunToken.defaultsKey) ?? "").contains(token), "the stored record doesn't hold the token")
        XCTAssertTrue(RunToken.redeem(token, seal: seal, defaults: defaults, now: now.addingTimeInterval(2)))
        XCTAssertNil(defaults.object(forKey: RunToken.defaultsKey))
        XCTAssertFalse(RunToken.redeem(token, seal: seal, defaults: defaults, now: now.addingTimeInterval(3)), "one time only")
    }

    func testWrongMissingOrMalformedTokenIsRefused() throws {
        let token = try RunToken.issue(seal: seal, defaults: defaults, now: now)
        XCTAssertFalse(RunToken.redeem(nil, seal: seal, defaults: defaults, now: now))
        XCTAssertFalse(RunToken.redeem("", seal: seal, defaults: defaults, now: now))
        XCTAssertFalse(RunToken.redeem(RunToken.make(), seal: seal, defaults: defaults, now: now))
        XCTAssertFalse(RunToken.redeem(token + "x", seal: seal, defaults: defaults, now: now))
        // A wrong guess doesn't use up the real one.
        XCTAssertTrue(RunToken.redeem(token, seal: seal, defaults: defaults, now: now))
    }

    func testExpiredTokenIsRefusedAndDeleted() throws {
        let token = try RunToken.issue(seal: seal, defaults: defaults, now: now)
        XCTAssertFalse(RunToken.redeem(token, seal: seal, defaults: defaults, now: now.addingTimeInterval(RunToken.lifetime + 2)))
        XCTAssertNil(defaults.object(forKey: RunToken.defaultsKey))
    }

    func testRecordWrittenOutsideLikelyDoesntCount() throws {
        // Something that can write Likely's preferences, but not seal: a record for its own token.
        let token = RunToken.make()
        defaults.set("v1:\(Int64(now.timeIntervalSince1970) + 30):\(RunToken.digest(token))", forKey: RunToken.defaultsKey)
        XCTAssertFalse(RunToken.redeem(token, seal: seal, defaults: defaults, now: now))
        // With a made-up MAC.
        defaults.set("bm90IGEgbWFj", forKey: SettingsSeal.macPrefix + RunToken.defaultsKey)
        XCTAssertFalse(RunToken.redeem(token, seal: seal, defaults: defaults, now: now))
        // Sealed with another key (another Mac, another build's data key).
        let other = SettingsSeal(cipher: DataCipher(store: InMemoryKeyStore(key: Data(repeating: 7, count: 32))),
                                 adoptedMarker: InMemoryKeyStore(key: Data([1])), defaults: defaults, domain: suite)
        let foreign = try RunToken.issue(seal: other, defaults: defaults, now: now)
        XCTAssertFalse(RunToken.redeem(foreign, seal: seal, defaults: defaults, now: now))
    }

    func testRecordWithAFarExpiryIsRefused() throws {
        let token = RunToken.make()
        try seal.set("v1:\(Int64(now.timeIntervalSince1970) + 3600):\(RunToken.digest(token))", forKey: RunToken.defaultsKey)
        XCTAssertFalse(RunToken.redeem(token, seal: seal, defaults: defaults, now: now))
    }

    func testWithoutAKeychainIssueFailsAndNothingIsStored() {
        let broken = InMemoryKeyStore()
        broken.failure = NSError(domain: "keychain", code: -25308)
        let locked = SettingsSeal(cipher: DataCipher(store: broken), adoptedMarker: InMemoryKeyStore(key: Data([1])), defaults: defaults, domain: suite)
        XCTAssertThrowsError(try RunToken.issue(seal: locked, defaults: defaults, now: now))
        XCTAssertNil(defaults.object(forKey: RunToken.defaultsKey))
    }

    func testBuildsWithoutADataKeyStoreItPlainly() throws {
        let token = try RunToken.issue(seal: nil, defaults: defaults, now: now)
        XCTAssertTrue(RunToken.redeem(token, seal: nil, defaults: defaults, now: now))
        XCTAssertFalse(RunToken.redeem(token, seal: nil, defaults: defaults, now: now))
    }

    func testTokensAreRandom() {
        XCTAssertNotEqual(RunToken.make(), RunToken.make())
        XCTAssertFalse(RunToken.isWellFormed("$(id)"))
        XCTAssertFalse(RunToken.isWellFormed(String(repeating: "a", count: 44)))
    }
}
