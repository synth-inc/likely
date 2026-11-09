import CryptoKit
import Foundation

/// Where the data key lives. The app uses `KeychainKeyStore`; tests use `InMemoryKeyStore`.
public protocol DataKeyStore: AnyObject {
    /// The stored key, or nil if there is none yet. Throws if there may be one that can't be read
    /// (keychain locked, an item this build isn't allowed to read, …): then no new key may be made.
    func loadKey() throws -> Data?
    /// Saves a new key. Throws if it couldn't be saved (the key must not be used then).
    func storeKey(_ key: Data) throws
}

/// Thrown by `DataKeyStore.storeKey` when a key was stored meanwhile (another Likely process, or
/// another thread of this one, made it first): the caller reads that key instead of using its own.
public struct DataKeyAlreadyStored: Error, CustomStringConvertible {
    public init() {}
    public var description: String { "a data key was stored meanwhile" }
}

public final class InMemoryKeyStore: DataKeyStore {
    public var key: Data?
    /// Makes `loadKey` throw, like a keychain item this build can't read.
    public var failure: Error?
    public init(key: Data? = nil) { self.key = key }
    public func loadKey() throws -> Data? {
        if let failure { throw failure }
        return key
    }
    public func storeKey(_ key: Data) throws {
        if let failure { throw failure }
        self.key = key
    }
}

/// AES-256-GCM encryption of Likely's private data (search history lines, saved test screenshots)
/// with one random key kept in the data-protection keychain (see KeychainKeyStore). Only builds with
/// a provisioning profile have one (EncryptionAvailability); the others keep that data in plaintext.
///
/// - A line (history.enc.jsonl): `lk1:<key id>:<base64 of nonce + ciphertext + tag>`. One sealed box per
///   line, so a damaged line, or one sealed by another build's key, is skipped on its own and the
///   rest of the file still reads.
/// - A file (`.png.enc`): "LKE1", the 4-byte key id, then nonce + ciphertext + tag.
///
/// The key id is the first 4 bytes of the key's SHA-256: it tells "made with another key" (another
/// build of Likely, see docs/PRIVACY.md) apart from "damaged". Each kind of data is sealed with its own
/// associated data, so a history line can't be passed off as a screenshot or the other way round.
public final class DataCipher {
    public enum Purpose: String {
        case historyLine = "inc.synth.likely.history-line.v1"
        case screenshot = "inc.synth.likely.screenshot.v1"
        var aad: Data { Data(rawValue.utf8) }
    }

    public enum CipherError: Error, CustomStringConvertible, Equatable {
        /// No key, and none could be made or read (Keychain unavailable, or another build's item).
        case keyUnavailable(String)
        /// Sealed with a different key (typically another build of Likely: dev vs. release).
        case otherKey
        /// Not something this format can open (damaged, truncated, or tampered with).
        case damaged
        /// Encrypted, and this build has no encryption (no provisioning profile, see
        /// EncryptionAvailability): another build of Likely encrypted it.
        case encryptionOff

        public var description: String {
            switch self {
            case .keyUnavailable(let why): return "the encryption key isn't available to this build (\(why))"
            case .otherKey: return "it was encrypted by another build of Likely, or with a key no longer in the Keychain"
            case .damaged: return "it's damaged"
            case .encryptionOff: return "it was encrypted by another build of Likely, and this build has no encryption"
            }
        }
    }

    public static let linePrefix = "lk1:"
    static let fileMagic = Data("LKE1".utf8)

    private let store: DataKeyStore
    private let lock = NSLock()
    private var cached: SymmetricKey?

    public init(store: DataKeyStore) {
        self.store = store
    }

    /// The key. `create`: make and store one if there's none yet (only when about to encrypt; reading
    /// never makes a key). Thread-safe.
    public func key(create: Bool) throws -> SymmetricKey {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let stored: Data?
        do {
            stored = try store.loadKey()
        } catch {
            throw CipherError.keyUnavailable("\(error)")
        }
        if let stored {
            guard stored.count == 32 else { throw CipherError.keyUnavailable("the stored key has the wrong size") }
            cached = SymmetricKey(data: stored)
            return cached!
        }
        // Nothing to open with: whatever was sealed came from another key (another build of Likely,
        // or a key that was removed from the Keychain).
        guard create else { throw CipherError.otherKey }
        let fresh = SymmetricKey(size: .bits256)
        let bytes = fresh.withUnsafeBytes { Data($0) }
        do {
            try store.storeKey(bytes)
        } catch is DataKeyAlreadyStored {
            // Someone else made the key first: use theirs, never ours (theirs may already seal data).
            guard let winner = try? store.loadKey(), winner.count == 32 else {
                throw CipherError.keyUnavailable("a key was stored meanwhile but can't be read")
            }
            cached = SymmetricKey(data: winner)
            return cached!
        } catch {
            throw CipherError.keyUnavailable("couldn't save a new key: \(error)")
        }
        cached = fresh
        return fresh
    }

    /// Whether a key exists and can be read, without making one.
    public var hasKey: Bool { (try? key(create: false)) != nil }

    static func keyID(_ key: SymmetricKey) -> Data {
        Data(key.withUnsafeBytes { SHA256.hash(data: Data($0)) }.prefix(4))
    }

    // MARK: Lines

    public static func isSealedLine(_ line: String) -> Bool { line.hasPrefix(linePrefix) }

    public func sealLine(_ text: String, purpose: Purpose = .historyLine) throws -> String {
        let key = try key(create: true)
        let box = try AES.GCM.seal(Data(text.utf8), using: key, authenticating: purpose.aad)
        guard let combined = box.combined else { throw CipherError.damaged }
        return Self.linePrefix + Self.hex(Self.keyID(key)) + ":" + combined.base64EncodedString()
    }

    /// The text of a sealed line. Throws `CipherError`.
    public func openLine(_ line: String, purpose: Purpose = .historyLine) throws -> String {
        guard line.hasPrefix(Self.linePrefix) else { throw CipherError.damaged }
        let parts = line.dropFirst(Self.linePrefix.count).split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let id = Self.unhex(String(parts[0])), id.count == 4,
              let combined = Data(base64Encoded: String(parts[1])) else { throw CipherError.damaged }
        return String(decoding: try open(combined, keyID: id, purpose: purpose), as: UTF8.self)
    }

    // MARK: Files

    public func sealFile(_ data: Data, purpose: Purpose = .screenshot) throws -> Data {
        let key = try key(create: true)
        let box = try AES.GCM.seal(data, using: key, authenticating: purpose.aad)
        guard let combined = box.combined else { throw CipherError.damaged }
        return Self.fileMagic + Self.keyID(key) + combined
    }

    public func openFile(_ data: Data, purpose: Purpose = .screenshot) throws -> Data {
        let magic = Self.fileMagic.count
        guard data.count > magic + 4, data.prefix(magic) == Self.fileMagic else { throw CipherError.damaged }
        let id = Data(data.dropFirst(magic).prefix(4))
        return try open(Data(data.dropFirst(magic + 4)), keyID: id, purpose: purpose)
    }

    public static func isSealedFile(_ data: Data) -> Bool { data.prefix(fileMagic.count) == fileMagic }

    private func open(_ combined: Data, keyID id: Data, purpose: Purpose) throws -> Data {
        let key = try key(create: false)
        guard id == Self.keyID(key) else { throw CipherError.otherKey }
        do {
            return try AES.GCM.open(AES.GCM.SealedBox(combined: combined), using: key, authenticating: purpose.aad)
        } catch {
            throw CipherError.damaged
        }
    }

    private static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    private static func unhex(_ s: String) -> Data? {
        guard s.count % 2 == 0 else { return nil }
        var out = Data()
        var index = s.startIndex
        while index < s.endIndex {
            let next = s.index(index, offsetBy: 2)
            guard let byte = UInt8(s[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        return out
    }
}
