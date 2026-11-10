import CryptoKit
import Foundation

/// Tamper-evident preferences: the settings that decide what Likely runs (the agent and its path, the
/// model, the prompt, the tool approvals, whether `--eval` may run from the command line) are stored
/// in UserDefaults as before, each with an HMAC-SHA256 next to it (`mac.<key>`). Anything that can
/// write Likely's preferences (`defaults write`, another process of the user's) can change a value but
/// can't make a matching MAC: the key is derived (HKDF) from the data key in the data-protection
/// keychain (DataCipher, KeychainKeyStore), which only Likely's own team-signed builds can read.
///
/// How a stored value reads (`Read`):
/// - its MAC matches: `.valid`;
/// - its MAC doesn't match: `.tampered` (changed outside Likely, or by an older Likely that predates
///   seals, e.g. after a downgrade);
/// - it has no MAC: `.unsealed` once adoption is done (written by a build that can't seal, such as an
///   unprofiled `./build.sh` or a free build, which removes the stale MAC when it writes, see
///   `writeUnsealed`; or planted), and `.unverifiable` before then (adoption will seal it);
/// - the key or the adoption marker can't be read (Keychain locked or not answering): `.unverifiable`.
/// Anything but `.valid` reads as absent for the caller (its safe default is used). Settings can show an
/// ignored value and seal it on the user's confirmation (`keep`). Builds without a provisioning profile
/// have no data key, so they don't seal anything (`SettingsSeal` isn't used; see docs/PRIVACY.md).
///
/// Values written by versions without seals are adopted once (`adoptExisting`): sealed as they are,
/// then a marker is stored in the keychain (`adoptedMarker`), which nothing outside Likely can remove,
/// so planting a value later never gets it adopted. Only the app's own persistent domain is adopted
/// (never launch arguments or the global domain).
public final class SettingsSeal {
    public enum Read<T: Equatable>: Equatable {
        case absent
        case valid(T)
        /// Present, but its MAC is wrong: don't use it.
        case tampered
        /// Present with no MAC, after adoption: don't use it.
        case unsealed
        /// Couldn't be checked (Keychain), or has no MAC and adoption hasn't happened yet: don't use it.
        case unverifiable

        public var value: T? { if case .valid(let v) = self { return v } else { return nil } }
    }

    public static let macPrefix = "mac."
    static let info = Data("inc.synth.likely.settings-mac.v1".utf8)

    private let cipher: DataCipher
    private let adoptedMarker: DataKeyStore
    private let defaults: UserDefaults
    /// The preferences domain adoption reads (`persistentDomain(forName:)`); nil adopts nothing.
    private let domain: String?
    private let lock = NSLock()
    private var cachedKey: SymmetricKey?
    private var adoptionDone = false

    public init(cipher: DataCipher, adoptedMarker: DataKeyStore, defaults: UserDefaults = .standard,
                domain: String? = Bundle.main.bundleIdentifier) {
        self.cipher = cipher
        self.adoptedMarker = adoptedMarker
        self.defaults = defaults
        self.domain = domain
    }

    private func macKey() throws -> SymmetricKey {
        lock.lock()
        defer { lock.unlock() }
        if let cachedKey { return cachedKey }
        let data = try cipher.key(create: true)
        let derived = HKDF<SHA256>.deriveKey(inputKeyMaterial: data, info: Self.info, outputByteCount: 32)
        cachedKey = derived
        return derived
    }

    /// Whether the settings older versions saved were adopted (the marker is in the keychain). Throws
    /// when the marker can't be read. Only `true` is cached.
    public func adoptionComplete() throws -> Bool {
        lock.lock()
        let done = adoptionDone
        lock.unlock()
        if done { return true }
        guard try adoptedMarker.loadKey() != nil else { return false }
        lock.lock()
        adoptionDone = true
        lock.unlock()
        return true
    }

    /// What's authenticated: the key's name, the value's type and its bytes, so a value can't be moved
    /// to another key or reinterpreted.
    static func message(key: String, type: String, bytes: Data) -> Data {
        var m = Data("v1\u{0}\(key)\u{0}\(type)\u{0}".utf8)
        m.append(bytes)
        return m
    }

    private func mac(key: String, type: String, bytes: Data) throws -> String {
        let code = HMAC<SHA256>.authenticationCode(for: Self.message(key: key, type: type, bytes: bytes), using: try macKey())
        return Data(code).base64EncodedString()
    }

    private func encoded(_ value: Any) -> (String, Data)? {
        switch value {
        case let s as String: return ("string", Data(s.utf8))
        case let d as Data: return ("data", d)
        case let n as NSNumber where CFGetTypeID(n) == CFBooleanGetTypeID(): return ("bool", Data((n.boolValue ? "1" : "0").utf8))
        default: return nil
        }
    }

    private func read(_ key: String) -> Read<AnyHashableBox> {
        guard let raw = defaults.object(forKey: key) else { return .absent }
        return check(key, raw)
    }

    /// Whether `raw` is the sealed value of `key`.
    private func check(_ key: String, _ raw: Any) -> Read<AnyHashableBox> {
        guard let storedObject = defaults.object(forKey: Self.macPrefix + key) else {
            do { return try adoptionComplete() ? .unsealed : .unverifiable } catch { return .unverifiable }
        }
        guard let (type, bytes) = encoded(raw), let stored = storedObject as? String,
              let storedMAC = Data(base64Encoded: stored) else { return .tampered }
        let expected: String
        do { expected = try mac(key: key, type: type, bytes: bytes) } catch { return .unverifiable }
        // Constant-time compare.
        guard let expectedMAC = Data(base64Encoded: expected), expectedMAC.count == storedMAC.count,
              zip(expectedMAC, storedMAC).reduce(0, { $0 | ($1.0 ^ $1.1) }) == 0 else { return .tampered }
        return .valid(AnyHashableBox(raw))
    }

    /// Any stored type (for checking a key whatever it holds).
    public func object(_ key: String) -> Read<NSObject> { map(read(key)) { $0.value as? NSObject } }
    public func string(_ key: String) -> Read<String> { map(read(key)) { $0.value as? String } }
    public func data(_ key: String) -> Read<Data> { map(read(key)) { $0.value as? Data } }
    public func bool(_ key: String) -> Read<Bool> {
        map(read(key)) { box in (box.value as? NSNumber).flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? $0.boolValue : nil } }
    }

    private func map<T>(_ r: Read<AnyHashableBox>, _ f: (AnyHashableBox) -> T?) -> Read<T> {
        switch r {
        case .absent: return .absent
        case .tampered: return .tampered
        case .unsealed: return .unsealed
        case .unverifiable: return .unverifiable
        case .valid(let box): return f(box).map { .valid($0) } ?? .tampered
        }
    }

    /// Stores `value` (String, Data or Bool) with its MAC, or removes both for nil. Throws, writing
    /// nothing, if the key can't be read.
    public func set(_ value: Any?, forKey key: String) throws {
        guard let value else {
            defaults.removeObject(forKey: key)
            defaults.removeObject(forKey: Self.macPrefix + key)
            return
        }
        let stored: Any = (value as? Bool).map { NSNumber(value: $0) } ?? value
        guard let (type, bytes) = encoded(stored) else { throw SealError.unsupportedType }
        let code = try mac(key: key, type: type, bytes: bytes)
        defaults.set(stored, forKey: key)
        defaults.set(code, forKey: Self.macPrefix + key)
    }

    public enum SealError: Error { case unsupportedType }

    /// For a build that can't seal (no data key): writes `value` (nil removes it) and removes the
    /// key's MAC, which no longer matches. A protected build then reads it as `.unsealed` (shown in
    /// Settings, where the user can keep it), not as `.tampered`.
    public static func writeUnsealed(_ value: Any?, forKey key: String, defaults: UserDefaults = .standard) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        defaults.removeObject(forKey: macPrefix + key)
    }

    /// The value stored for `key`, sealed or not (for Settings to show before the user keeps it).
    public func storedValue(_ key: String) -> Any? { defaults.object(forKey: key) }

    /// The user confirmed an ignored value in Settings: seals it, if it's still `expected` (what Settings
    /// showed). Returns false, sealing nothing, when the value changed meanwhile.
    public func keep(_ key: String, expected: Any) throws -> Bool {
        guard let raw = defaults.object(forKey: key), AnyHashableBox(raw) == AnyHashableBox(expected) else { return false }
        try set(raw, forKey: key)
        return true
    }

    public struct Adoption: Equatable {
        /// Sealed as they were.
        public var adopted: [String] = []
        /// Couldn't be sealed (a type Likely doesn't store): left unsealed, so they read as `.unsealed`.
        public var skipped: [String] = []
        public init(adopted: [String] = [], skipped: [String] = []) {
            self.adopted = adopted
            self.skipped = skipped
        }
    }

    /// Seals the values of `keys` present in the app's own persistent domain, once per data key: the
    /// first launch of a version with seals keeps the user's settings. A key that can't be sealed is
    /// skipped; the marker is still written. Throws, adopting nothing, while the keychain doesn't
    /// answer (the marker or the key can't be read): the caller retries later.
    /// Keys never adopted: "Allow command-line test runs" is new with seals, so an unsealed value was
    /// never set in Likely.
    public static let neverAdopted: Set<String> = ["allowCommandLineTests"]

    @discardableResult
    public func adoptExisting(_ keys: [String]) throws -> Adoption {
        if try adoptionComplete() { return Adoption() }
        _ = try macKey()
        let saved = domain.flatMap { defaults.persistentDomain(forName: $0) } ?? [:]
        var result = Adoption()
        for key in keys where !Self.neverAdopted.contains(key) {
            guard let raw = saved[key] else { continue }
            if case .valid = check(key, raw) { continue }
            do {
                try set(raw, forKey: key)
                result.adopted.append(key)
            } catch {
                result.skipped.append(key)
            }
        }
        do {
            try adoptedMarker.storeKey(Data([1]))
        } catch is DataKeyAlreadyStored {
            // Another Likely process adopted at the same time.
        }
        lock.lock()
        adoptionDone = true
        lock.unlock()
        return result
    }
}

/// Wraps a preferences value for `Read` (which needs Equatable).
struct AnyHashableBox: Equatable {
    let value: Any
    init(_ value: Any) { self.value = value }
    static func == (a: AnyHashableBox, b: AnyHashableBox) -> Bool { (a.value as? NSObject) == (b.value as? NSObject) }
}
