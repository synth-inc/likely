import CryptoKit
import Foundation
import XCTest
@testable import LicenseCore

private let install = "6f1c1c7e-2a49-4d0e-9a39-0d6a0f1b2c3d"
private let issued = Date(timeIntervalSince1970: 1_794_225_600) // 2026-11-09 12:00 UTC
private let day: TimeInterval = 24 * 3600

/// A server stand-in: a throwaway keypair per test run.
private struct TestServer {
    let kid: String
    let privateKey = Curve25519.Signing.PrivateKey()
    var keys: [String: Curve25519.Signing.PublicKey] { [kid: privateKey.publicKey] }

    init(kid: String = "test-1") { self.kid = kid }

    func claims(active: Bool = true, kind: String? = "subscription", installId: String = install, exp: Date? = issued.addingTimeInterval(30 * day),
                periodEnd: String? = nil, product: String = "likely", v: Int = 1, kid: String? = nil) -> [String: Any] {
        var claims: [String: Any] = [
            "v": v, "kid": kid ?? self.kid, "product": product, "installId": installId, "active": active,
            "kind": kind ?? NSNull(), "status": active ? "active" : NSNull(), "iat": Int(issued.timeIntervalSince1970),
            "exp": exp.map { Int($0.timeIntervalSince1970) } ?? NSNull(),
            "currentPeriodEnd": periodEnd ?? NSNull(), "cancelAtPeriodEnd": false,
        ]
        if kind == "one_time" { claims["status"] = "paid" }
        return claims
    }

    func sign(_ claims: [String: Any]) throws -> SignedEntitlement {
        let bytes = try JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys])
        return SignedEntitlement(payload: base64URL(bytes), signature: base64URL(try privateKey.signature(for: bytes)), kid: kid)
    }
}

private func base64URL(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

final class SignedEntitlementTests: XCTestCase {
    private let server = TestServer()

    private func evaluate(_ signed: SignedEntitlement, keys: [String: Curve25519.Signing.PublicKey]? = nil, installId: String = install,
                          at now: Date = issued.addingTimeInterval(day)) -> EntitlementVerifier.Verdict {
        EntitlementVerifier.evaluate(signed, keys: keys ?? server.keys, installId: installId, now: now)
    }

    // MARK: Valid

    func testValidSubscriptionIsActive() throws {
        let verdict = evaluate(try server.sign(server.claims()))
        XCTAssertTrue(verdict.isActive)
        XCTAssertEqual(verdict.claims?.kind, "subscription")
        XCTAssertEqual(verdict.claims?.installId, install)
    }

    func testOneTimeWithoutExpiryWorksForever() throws {
        let signed = try server.sign(server.claims(kind: "one_time", exp: nil))
        XCTAssertTrue(evaluate(signed).isActive)
        // Years later, server long gone: still licensed.
        XCTAssertTrue(evaluate(signed, at: issued.addingTimeInterval(20 * 365 * day)).isActive)
    }

    func testInstallIdComparisonIgnoresCase() throws {
        XCTAssertTrue(evaluate(try server.sign(server.claims()), installId: install.uppercased()).isActive)
    }

    func testServerSaysInactive() throws {
        let verdict = evaluate(try server.sign(server.claims(active: false, kind: nil)))
        XCTAssertEqual(verdict, .inactive(try XCTUnwrap(verdict.claims)))
        XCTAssertFalse(verdict.isActive)
    }

    // MARK: Forgeries

    func testTamperedPayloadIsRejected() throws {
        let real = try server.sign(server.claims(active: false, kind: nil))
        // Flip active to true and keep the old signature.
        let forgedBytes = try JSONSerialization.data(withJSONObject: server.claims(), options: [.sortedKeys])
        let forged = SignedEntitlement(payload: base64URL(forgedBytes), signature: real.signature, kid: real.kid)
        XCTAssertEqual(evaluate(forged), .rejected(.badSignature))
    }

    func testTamperedSignatureIsRejected() throws {
        var signed = try server.sign(server.claims())
        var signature = try XCTUnwrap(EntitlementVerifier.base64URLDecode(signed.signature))
        signature[0] ^= 0x01
        signed.signature = base64URL(signature)
        XCTAssertEqual(evaluate(signed), .rejected(.badSignature))
    }

    func testSignedByAnotherKeyIsRejected() throws {
        let impostor = TestServer(kid: "test-1")
        XCTAssertEqual(evaluate(try impostor.sign(impostor.claims())), .rejected(.badSignature))
    }

    func testUnsignedOrGarbageIsRejected() throws {
        let bytes = try JSONSerialization.data(withJSONObject: server.claims(), options: [.sortedKeys])
        XCTAssertEqual(evaluate(SignedEntitlement(payload: base64URL(bytes), signature: "", kid: "test-1")), .rejected(.malformed))
        XCTAssertEqual(evaluate(SignedEntitlement(payload: "not base64!", signature: "AAAA", kid: "test-1")), .rejected(.malformed))
        // Valid signature over bytes that aren't claims.
        let junk = Data("{}".utf8)
        let signed = SignedEntitlement(payload: base64URL(junk), signature: base64URL(try server.privateKey.signature(for: junk)), kid: "test-1")
        XCTAssertEqual(evaluate(signed), .rejected(.malformed))
    }

    func testWrongInstallIsRejected() throws {
        let other = "11111111-2222-3333-4444-555555555555"
        XCTAssertEqual(evaluate(try server.sign(server.claims(installId: other))), .rejected(.wrongInstall))
    }

    func testWrongProductIsRejected() throws {
        XCTAssertEqual(evaluate(try server.sign(server.claims(product: "onit"))), .rejected(.wrongProduct))
    }

    func testUnsupportedVersionIsRejected() throws {
        XCTAssertEqual(evaluate(try server.sign(server.claims(v: 2))), .rejected(.unsupportedVersion))
    }

    // MARK: Keys

    func testUnknownKidIsRejected() throws {
        let signed = try server.sign(server.claims())
        XCTAssertEqual(evaluate(signed, keys: [:]), .rejected(.unknownKey))
        XCTAssertEqual(evaluate(signed, keys: ["test-2": server.privateKey.publicKey]), .rejected(.unknownKey))
    }

    func testKidInsidePayloadMustMatch() throws {
        XCTAssertEqual(evaluate(try server.sign(server.claims(kid: "test-2"))), .rejected(.kidMismatch))
    }

    func testRotationKeepsOldKeysWorking() throws {
        let next = TestServer(kid: "test-2")
        let keys = server.keys.merging(next.keys) { a, _ in a }
        XCTAssertTrue(evaluate(try server.sign(server.claims(kind: "one_time", exp: nil)), keys: keys).isActive)
        XCTAssertTrue(evaluate(try next.sign(next.claims()), keys: keys).isActive)
    }

    func testKeyringDropsThePlaceholder() {
        let raw = server.privateKey.publicKey.rawRepresentation.base64EncodedString()
        let keys = EntitlementVerifier.keyring(["real": raw, "placeholder": "REPLACE_ME_WITH_BASE64_RAW_ED25519_PUBLIC_KEY", "short": "AAAA"])
        XCTAssertEqual(Array(keys.keys), ["real"])
    }

    // MARK: Expiry and offline grace

    func testSubscriptionWorksThroughTheOfflineGrace() throws {
        let exp = issued.addingTimeInterval(30 * day)
        let signed = try server.sign(server.claims(exp: exp))
        XCTAssertTrue(evaluate(signed, at: exp.addingTimeInterval(-1)).isActive)
        XCTAssertTrue(evaluate(signed, at: exp.addingTimeInterval(13 * day)).isActive)
        XCTAssertEqual(evaluate(signed, at: exp.addingTimeInterval(EntitlementVerifier.subscriptionGrace)), .rejected(.expired))
    }

    func testExpiredSubscriptionIsRejected() throws {
        let signed = try server.sign(server.claims(exp: issued.addingTimeInterval(30 * day)))
        XCTAssertEqual(evaluate(signed, at: issued.addingTimeInterval(60 * day)), .rejected(.expired))
    }

    func testCancelledSubscriptionStopsAfterPeriodEndPlusGrace() throws {
        let end = issued.addingTimeInterval(5 * day)
        let signed = try server.sign(server.claims(periodEnd: ISO8601DateFormatter().string(from: end)))
        XCTAssertTrue(evaluate(signed, at: end.addingTimeInterval(13 * day)).isActive)
        XCTAssertEqual(evaluate(signed, at: end.addingTimeInterval(15 * day)), .rejected(.expired))
    }

    func testSubscriptionWithoutExpiryIsRejected() throws {
        XCTAssertEqual(evaluate(try server.sign(server.claims(exp: nil))), .rejected(.expired))
    }

    func testOneTimeWithAnExpiryGetsTheGraceToo() throws {
        let exp = issued.addingTimeInterval(365 * day)
        let signed = try server.sign(server.claims(kind: "one_time", exp: exp))
        XCTAssertTrue(evaluate(signed, at: exp.addingTimeInterval(13 * day)).isActive)
        XCTAssertEqual(evaluate(signed, at: exp.addingTimeInterval(15 * day)), .rejected(.expired))
    }

    // MARK: Interop

    /// Signed by onit-server's `signEntitlement` (Node crypto) with a throwaway test key that only
    /// exists for this fixture. Catches format drift between the server and the app.
    func testVerifiesWhatTheNodeServerSigned() {
        let keys = EntitlementVerifier.keyring(["fixture-1": "F0OMfRhFLnI9PvpwCKiOJMfLeM0/7JJB0U+NRPmvXWI="])
        let signed = SignedEntitlement(
            payload: "eyJhY3RpdmUiOnRydWUsImNhbmNlbEF0UGVyaW9kRW5kIjpmYWxzZSwiY3VycmVudFBlcmlvZEVuZCI6bnVsbCwiZXhwIjpudWxsLCJpYXQiOjE3OTQyMjU2MDAsImluc3RhbGxJZCI6IjZmMWMxYzdlLTJhNDktNGQwZS05YTM5LTBkNmEwZjFiMmMzZCIsImtpZCI6ImZpeHR1cmUtMSIsImtpbmQiOiJvbmVfdGltZSIsInByb2R1Y3QiOiJsaWtlbHkiLCJzdGF0dXMiOiJwYWlkIiwidiI6MX0",
            signature: "VoUjmsMHD4xAg3BjBPqtULGlJaXsTXZyZXregyER4TYkizrB-o_4PhbpXyDZ3g1MdE5YaJSXIlBnn-caY0NrCw",
            kid: "fixture-1")
        let verdict = EntitlementVerifier.evaluate(signed, keys: keys, installId: install, now: issued.addingTimeInterval(3650 * day))
        XCTAssertTrue(verdict.isActive)
        XCTAssertEqual(verdict.claims?.kind, "one_time")
        XCTAssertNil(verdict.claims?.exp)
        XCTAssertEqual(verdict.claims?.iat, 1_794_225_600)
    }

    func testCachedBlobRoundTripsThroughCodable() throws {
        let signed = try server.sign(server.claims())
        let decoded = try JSONDecoder().decode(SignedEntitlement.self, from: JSONEncoder().encode(signed))
        XCTAssertEqual(decoded, signed)
        XCTAssertTrue(evaluate(decoded).isActive)
    }
}
