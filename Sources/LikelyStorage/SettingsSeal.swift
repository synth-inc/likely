import CryptoKit
import Foundation

/// Tamper-evident preferences: the settings that decide what Likely runs (the agent and its path, the
/// model, the prompt, the tool approvals, whether `--eval` may run from the command line) are stored
/// in UserDefaults as before, each with an HMAC-SHA256 next to it (`mac.<key>`). Anything that can
/// write Likely's preferences (`defaults write`, another process of the user's) can change a value but
/// can't make a matching MAC: the key is derived (HKDF) from the data key in the data-protection
/// keychain (DataCipher, KeychainKeyStore), which only Likely's own team-signed builds can read.
///
/// A value whose MAC doesn't match, or that has none, reads as absent (the caller uses its safe
/// default) and is reported as tampered. Builds without a provisioning profile have no data key, so
/// they don't seal anything (`SettingsSeal` isn't used; see docs/PRIVACY.md).
///
/// Values written by versions without seals are adopted once (`adoptExisting`): sealed as they are,
/// then a marker is stored in the keychain (`adoptedMarker`), which nothing outside Likely can remove,
/// so planting a value later never gets it adopted.
public final class SettingsSeal {
    public enum Read<T: Equatable>: Equatable {
        case absent
        case valid(T)
        /// Present, but its MAC is missing or wrong (or the key can't be read): don't use it.
        case tampered
        case unverifiable

        public var value: T? { if case .valid(let v) = self { return v } else { return nil } }
    }

    public static let macPrefix = "mac."
    static let info = Data("inc.synth.likely.settings-mac.v1".utf8)

    private let cipher: DataCipher
    private let adoptedMarker: DataKeyStore
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var cachedKey: SymmetricKey?

    public init(cipher: DataCipher, adoptedMarker: DataKeyStore, defaults: UserDefaults = .standard) {
        self.cipher = cipher
        self.adoptedMarker = adoptedMarker
        self.defaults = defaults
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
        guard let (type, bytes) = encoded(raw), let stored = defaults.string(forKey: Self.macPrefix + key),
              let storedMAC = Data(base64Encoded: stored) else { return .tampered }
        let expected: String
        do { expected = try mac(key: key, type: type, bytes: bytes) } catch { return .unverifiable }
        // Constant-time compare.
        guard let expectedMAC = Data(base64Encoded: expected), expectedMAC.count == storedMAC.count,
              zip(expectedMAC, storedMAC).reduce(0, { $0 | ($1.0 ^ $1.1) }) == 0 else { return .tampered }
        return .valid(AnyHashableBox(raw))
    }

    public func string(_ key: String) -> Read<String> { map(read(key)) { $0.value as? String } }
    public func data(_ key: String) -> Read<Data> { map(read(key)) { $0.value as? Data } }
    public func bool(_ key: String) -> Read<Bool> {
        map(read(key)) { box in (box.value as? NSNumber).flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? $0.boolValue : nil } }
    }

    private func map<T>(_ r: Read<AnyHashableBox>, _ f: (AnyHashableBox) -> T?) -> Read<T> {
        switch r {
        case .absent: return .absent
        case .tampered: return .tampered
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

    /// Seals the values of `keys` that are present, once per data key: the first launch of a version
    /// with seals keeps the user's settings. Returns the keys adopted (empty if already done).
    @discardableResult
    public func adoptExisting(_ keys: [String]) throws -> [String] {
        if try adoptedMarker.loadKey() != nil { return [] }
        var adopted: [String] = []
        for key in keys {
            guard let raw = defaults.object(forKey: key) else { continue }
            if case .valid = read(key) { continue }
            try set(raw, forKey: key)
            adopted.append(key)
        }
        do {
            try adoptedMarker.storeKey(Data([1]))
        } catch is DataKeyAlreadyStored {
            // Another Likely process adopted at the same time.
        }
        return adopted
    }
}

/// Wraps a preferences value for `Read` (which needs Equatable).
struct AnyHashableBox: Equatable {
    let value: Any
    init(_ value: Any) { self.value = value }
    static func == (a: AnyHashableBox, b: AnyHashableBox) -> Bool { (a.value as? NSObject) == (b.value as? NSObject) }
}
