import CryptoKit
import Foundation

/// The one-time permission Settings → Tests → Run Tests gives the `Likely --eval` process it starts,
/// so that run works with "Allow command-line test runs" off.
///
/// Before launching the child, the app makes a random token and stores a record of it in its
/// preferences: the token's SHA-256 and an expiry (`lifetime`, 60 s), sealed with `SettingsSeal` (an
/// HMAC keyed from the data key, which only Likely's own builds can read). The token itself goes to the
/// child only, in its environment (`environmentKey`). The child redeems it once: the record must be
/// sealed, unexpired and match the token; it's deleted when redeemed (or found expired), so it can't be
/// used again. Anything else that can write Likely's preferences can't make a record that verifies,
/// and reading the record doesn't give the token.
///
/// Builds without a data key (no provisioning profile) store the record plainly: there, anything can
/// also turn on "Allow command-line test runs" itself, so this is no weaker than the switch.
public enum RunToken {
    public static let environmentKey = "LIKELY_RUN_TOKEN"
    public static let defaultsKey = "evalRunToken"
    public static let lifetime: TimeInterval = 60

    /// 32 random bytes, base64url without padding (43 characters).
    public static func make() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        var rng = SystemRandomNumberGenerator()
        for i in bytes.indices { bytes[i] = rng.next() }
        return base64url(Data(bytes))
    }

    /// The shape of a token: anything else in the environment is ignored (and never passed on).
    public static func isWellFormed(_ token: String) -> Bool {
        token.count == 43 && token.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// Stores the record for a new token and returns the token, for the child's environment. Throws,
    /// storing nothing, when the record can't be sealed (the keychain doesn't answer).
    public static func issue(seal: SettingsSeal?, defaults: UserDefaults = .standard, now: Date = Date()) throws -> String {
        let token = make()
        let record = "v1:\(Int64((now.timeIntervalSince1970 + lifetime).rounded(.up))):\(digest(token))"
        if let seal { try seal.set(record, forKey: defaultsKey) } else { defaults.set(record, forKey: defaultsKey) }
        defaults.synchronize()   // the child is another process
        return token
    }

    /// The child: whether `token` (from its environment) matches the stored record, unexpired. Deletes
    /// the record when it matched or had expired; a wrong token leaves it (it can't be guessed).
    public static func redeem(_ token: String?, seal: SettingsSeal?, defaults: UserDefaults = .standard, now: Date = Date()) -> Bool {
        guard let token, isWellFormed(token) else { return false }
        let record: String?
        if let seal { record = seal.string(defaultsKey).value } else { record = defaults.string(forKey: defaultsKey) }
        guard let record else { return false }
        let parts = record.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "v1", let expiry = Int64(parts[1]) else { return false }
        let delete = {
            if let seal { try? seal.set(nil, forKey: defaultsKey) } else { defaults.removeObject(forKey: defaultsKey) }
            defaults.synchronize()
        }
        guard now.timeIntervalSince1970 <= TimeInterval(expiry), expiry - Int64(now.timeIntervalSince1970) <= Int64(lifetime) + 1 else {
            delete()
            return false
        }
        // Constant-time compare.
        let expected = Array(digest(token).utf8)
        let stored = Array(parts[2].utf8)
        guard expected.count == stored.count, zip(expected, stored).reduce(0, { $0 | ($1.0 ^ $1.1) }) == 0 else { return false }
        delete()
        return true
    }

    static func digest(_ token: String) -> String {
        base64url(Data(SHA256.hash(data: Data(token.utf8))))
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
