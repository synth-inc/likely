import CryptoKit
import Foundation

/// An entitlement the Onit server signed for one install (onit-server `entitlementSigning.ts`).
///
/// `payload` is base64url of the exact JSON bytes the server signed with Ed25519; `signature` is
/// base64url of the 64-byte signature; `kid` picks the public key. Likely caches this blob, never a
/// bare "active" flag, and verifies it every time it's loaded, so a forged or edited cache unlocks
/// nothing.
public struct SignedEntitlement: Codable, Equatable, Sendable {
    public var payload: String
    public var signature: String
    public var kid: String

    public init(payload: String, signature: String, kid: String) {
        self.payload = payload
        self.signature = signature
        self.kid = kid
    }
}

/// What the server vouched for. Only ever built from bytes whose signature checked out.
public struct EntitlementClaims: Codable, Equatable, Sendable {
    public var v: Int
    public var kid: String
    public var product: String
    public var installId: String
    public var active: Bool
    /// "subscription", "one_time" or "promo"; nil when nothing was bought.
    public var kind: String?
    public var status: String?
    /// Issued at, Unix seconds.
    public var iat: Int
    /// Expires at, Unix seconds. nil = never (an active one-time purchase).
    public var exp: Int?
    /// ISO 8601; subscriptions only.
    public var currentPeriodEnd: String?
    public var cancelAtPeriodEnd: Bool?

    public var isOneTime: Bool { kind == "one_time" }
    public var issuedAt: Date { Date(timeIntervalSince1970: TimeInterval(iat)) }
    public var expiresAt: Date? { exp.map { Date(timeIntervalSince1970: TimeInterval($0)) } }
    public var periodEnd: Date? { currentPeriodEnd.flatMap(EntitlementVerifier.parseDate) }
}

public enum EntitlementVerifier {
    public static let supportedVersion = 1

    /// How long past `exp` (and past a subscription's period end) a verified subscription keeps
    /// working when Likely can't get a fresh one: offline, server down. Online, the server's answer
    /// replaces the cache, so a cancelled subscription stops at the next check.
    public static let subscriptionGrace: TimeInterval = 14 * 24 * 3600

    public enum Failure: Error, Equatable, Sendable {
        case unknownKey, malformed, badSignature, unsupportedVersion, kidMismatch, wrongProduct, wrongInstall, expired

        /// Fixed text for the log (no values).
        public var logReason: StaticString {
            switch self {
            case .unknownKey: return "unknown key id"
            case .malformed: return "malformed"
            case .badSignature: return "bad signature"
            case .unsupportedVersion: return "unsupported version"
            case .kidMismatch: return "key id mismatch"
            case .wrongProduct: return "wrong product"
            case .wrongInstall: return "wrong install"
            case .expired: return "expired"
            }
        }
    }

    public enum Verdict: Equatable, Sendable {
        /// Signed for this install, active and in date.
        case active(EntitlementClaims)
        /// Signed for this install, but the server says nothing is active.
        case inactive(EntitlementClaims)
        case rejected(Failure)

        public var isActive: Bool { if case .active = self { return true } else { return false } }
        public var claims: EntitlementClaims? {
            switch self {
            case .active(let claims), .inactive(let claims): return claims
            case .rejected: return nil
            }
        }
    }

    /// Public keys by kid, from base64 of the raw 32-byte Ed25519 key. Entries that don't decode
    /// (the placeholder) are dropped, so they verify nothing.
    public static func keyring(_ base64Keys: [String: String]) -> [String: Curve25519.Signing.PublicKey] {
        base64Keys.compactMapValues { base64 in
            Data(base64Encoded: base64).flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }
        }
    }

    /// Signature, key id, product and install. Says nothing about whether it's still in date.
    public static func verifiedClaims(_ signed: SignedEntitlement, keys: [String: Curve25519.Signing.PublicKey],
                                      installId: String, product: String = "likely") -> Result<EntitlementClaims, Failure> {
        guard let key = keys[signed.kid] else { return .failure(.unknownKey) }
        guard let payload = base64URLDecode(signed.payload), let signature = base64URLDecode(signed.signature) else {
            return .failure(.malformed)
        }
        guard key.isValidSignature(signature, for: payload) else { return .failure(.badSignature) }
        guard let claims = try? JSONDecoder().decode(EntitlementClaims.self, from: payload) else { return .failure(.malformed) }
        guard claims.v == supportedVersion else { return .failure(.unsupportedVersion) }
        guard claims.kid == signed.kid else { return .failure(.kidMismatch) }
        guard claims.product == product else { return .failure(.wrongProduct) }
        guard claims.installId.lowercased() == installId.lowercased() else { return .failure(.wrongInstall) }
        return .success(claims)
    }

    /// The whole check: verified, and if active, still in date at `now`.
    ///
    /// - An active one-time purchase without `exp` never expires, so it keeps working if the server
    ///   is unreachable or gone. With an `exp`, it gets the same grace as a subscription.
    /// - Subscriptions (and promos) work until `exp` + `grace`, and until their period end + `grace`
    ///   when a period end is known. A subscription without `exp` is rejected.
    public static func evaluate(_ signed: SignedEntitlement, keys: [String: Curve25519.Signing.PublicKey], installId: String,
                                product: String = "likely", now: Date = Date(), grace: TimeInterval = subscriptionGrace) -> Verdict {
        let claims: EntitlementClaims
        switch verifiedClaims(signed, keys: keys, installId: installId, product: product) {
        case .failure(let failure): return .rejected(failure)
        case .success(let verified): claims = verified
        }
        guard claims.active else { return .inactive(claims) }
        if claims.isOneTime && claims.exp == nil { return .active(claims) }
        guard let expiresAt = claims.expiresAt, now < expiresAt.addingTimeInterval(grace) else { return .rejected(.expired) }
        if !claims.isOneTime, let end = claims.periodEnd, now > end.addingTimeInterval(grace) { return .rejected(.expired) }
        return .active(claims)
    }

    static func base64URLDecode(_ string: String) -> Data? {
        guard !string.isEmpty, string.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            return nil
        }
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }

    public static func parseDate(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}
