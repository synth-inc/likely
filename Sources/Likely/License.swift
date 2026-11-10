import Foundation
import LicenseCore

/// Paid license state. Likely is open source: builds made with `LIKELY_FREE=1 ./build.sh` skip the
/// license page entirely and never talk to the server.
///
/// Paid builds buy through Stripe Checkout on the shared Onit server (see `LicenseClient`). The server
/// signs each entitlement for this install with Ed25519; Likely caches that signed blob (never a bare
/// "active" flag) and verifies it every time it reads it (`LicenseCore.EntitlementVerifier`), so a
/// forged or edited cache in UserDefaults unlocks nothing.
///
/// Offline: a one-time purchase never expires, so it keeps working if the server is unreachable or
/// shut down. A subscription's blob expires 30 days after the server issued it (re-fetched every 12
/// hours while online) and keeps working `EntitlementVerifier.subscriptionGrace` (14 days) past that,
/// and past its billing period's end, while Likely can't reach the server.
enum License {
    enum Kind: String {
        case subscription, oneTime
        /// Not a license: points people at the source to build it themselves.
        case free
    }

    struct Plan {
        let kind: Kind
        let headline: String
        let price: String
        /// Shown smaller beside the price ("/ month", "once").
        let priceUnit: String
        let detail: String
        /// What the server sells for this plan; nil for "build it yourself".
        let serverPlan: LicenseClient.Plan?
        let buttonTitle: String
    }

    static let sourceURL = URL(string: "https://github.com/synth-inc/likely")!

    static let plans: [Plan] = [
        Plan(kind: .subscription,
             headline: "I want Likely to keep getting better",
             price: "$3", priceUnit: "/ month",                                                          // TODO: confirm price
             detail: "New agents, Photos search and smarter suggestions as they ship. Cancel anytime.",
             serverPlan: .monthly,
             buttonTitle: "Subscribe"),
        Plan(kind: .oneTime,
             headline: "No updates please",
             price: "$29", priceUnit: "once",
             detail: "One payment, and you can use the app, forever.",
             serverPlan: .lifetime,
             buttonTitle: "Buy Once"),
        Plan(kind: .free,
             headline: "I'm allergic to paying",
             price: "Free", priceUnit: "",
             detail: "You can use Likely for free, but we're not going to make it easy for you.",
             serverPlan: nil,
             buttonTitle: "Open GitHub"),
    ]

    /// Public keys that verify the server's signed entitlements, by key id (`kid`): base64 of the raw
    /// 32-byte Ed25519 public key. Keep old kids when rotating: one-time purchases signed with them
    /// never expire. Generate the pair and get this value with (OpenSSL 3, not macOS's LibreSSL):
    ///   openssl genpkey -algorithm ed25519 -out likely-entitlement-signing.pem
    ///   openssl pkey -in likely-entitlement-signing.pem -pubout -outform DER | tail -c 32 | base64
    /// The private key goes on the server as LIKELY_ENTITLEMENT_SIGNING_KEY (onit-server .env.example).
    // PLACEHOLDER: no key is configured, so no paid license verifies. Replace the value below with
    // the real public key before shipping a paid build (build.sh refuses a release with the placeholder).
    static let entitlementPublicKeys: [String: String] = [
        "likely-1": "REPLACE_ME_WITH_BASE64_RAW_ED25519_PUBLIC_KEY",
    ]

    static let entitlementKeys = EntitlementVerifier.keyring(entitlementPublicKeys)

    static var isFreeBuild: Bool {
        #if LIKELY_FREE
        return true
        #else
        return false
        #endif
    }

    /// Dev builds only (`./build.sh` compiles with LIKELY_DEV; release builds never do): pretend to hold
    /// a license without the server, for testing the paid state.
    /// `defaults write inc.synth.likely devLicenseOverride -string subscription` (or `one_time`);
    /// `defaults delete inc.synth.likely devLicenseOverride` to turn it off.
    static var devOverride: Kind? {
        #if LIKELY_DEV
        switch UserDefaults.standard.string(forKey: "devLicenseOverride") {
        case "subscription": return .subscription
        case "one_time": return .oneTime
        default: return nil
        }
        #else
        return nil
        #endif
    }

    /// Readable from any thread (AppDelegate at launch, onboarding). `LicenseStore` keeps the cache fresh.
    static var isActive: Bool { isFreeBuild || devOverride != nil || Cached.load()?.verdict().isActive == true }

    /// Re-check this often while running (plus at launch and after checkout).
    static let recheckInterval: TimeInterval = 12 * 3600

    /// The last signed entitlement the server gave us, with when we got it. Only the signed blob is
    /// stored; what it says is re-verified on every read.
    struct Cached: Codable, Equatable {
        var signed: SignedEntitlement
        var checkedAt: Date

        private static let key = "licenseSignedEntitlement"
        /// Unsigned cache from Likely 0.1.0; never trusted, deleted on launch.
        static let legacyKey = "licenseEntitlement"

        static func load() -> Cached? {
            UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(Cached.self, from: $0) }
        }

        func save() {
            if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
        }

        /// Signature, key id, this install, and expiry (with the offline grace) at `now`.
        func verdict(at now: Date = Date()) -> EntitlementVerifier.Verdict {
            EntitlementVerifier.evaluate(signed, keys: License.entitlementKeys, installId: LicenseClient.installId, now: now)
        }

        /// Verified and active.
        var activeClaims: EntitlementClaims? {
            if case .active(let claims) = verdict() { return claims }
            return nil
        }

        var kind: Kind? {
            guard let claims = activeClaims else { return nil }
            return claims.isOneTime ? .oneTime : .subscription
        }
    }
}

/// Observable license state for the UI and AppDelegate. All server calls go through `refresh()`.
@MainActor
final class LicenseStore: ObservableObject {
    static let shared = LicenseStore()

    @Published private(set) var cached = License.Cached.load()
    @Published private(set) var isChecking = false
    /// Readable reason the last check failed (offline, endpoint missing...). Cleared on success.
    @Published private(set) var lastError: String?

    /// Called when `isActive` flips, after a check or when the offline grace runs out.
    var onActiveChange: ((Bool) -> Void)?

    private var timer: Timer?
    private var lastActive = License.isActive

    private init() {
        // Placeholder-era keys ("any 8+ character key"); a real purchase replaces them.
        UserDefaults.standard.removeObject(forKey: "licenseKey")
        UserDefaults.standard.removeObject(forKey: "licenseKind")
        UserDefaults.standard.removeObject(forKey: License.Cached.legacyKey)
        guard !License.isFreeBuild else { return }
        if License.entitlementKeys.isEmpty { Log.write("license", "no entitlement public key configured") }
        if let cached, case .rejected(let failure) = cached.verdict() {
            Log.write("license", "cached entitlement not trusted: \(public: failure.logReason)")
        }
    }

    var isActive: Bool { License.isFreeBuild || License.devOverride != nil || cached?.verdict().isActive == true }

    /// Plan the user owns, for "Active" badges.
    var activeKind: License.Kind? { License.devOverride ?? (isActive ? cached?.kind : nil) }

    /// One line for Settings.
    var statusText: String {
        if License.isFreeBuild { return "Free build" }
        if let kind = License.devOverride {
            return "Developer license override (\(kind == .oneTime ? "one-time" : "subscription"))"
        }
        guard isActive, let entitlement = cached?.activeClaims else { return "Not active" }
        let end = entitlement.periodEnd.map { $0.formatted(date: .abbreviated, time: .omitted) }
        switch entitlement.kind {
        case "one_time":
            return "Lifetime license"
        case "promo":
            return end.map { "Active (promo) until \($0)" } ?? "Active (promo)"
        default:
            guard let end else { return "Subscription active" }
            return entitlement.cancelAtPeriodEnd == true ? "Subscription ends \(end)" : "Subscription active, renews \(end)"
        }
    }

    var isSubscriber: Bool {
        if let kind = License.devOverride { return kind == .subscription }
        return isActive && cached?.activeClaims?.kind == "subscription"
    }

    /// Asks the server for the current entitlement. Only a signed one that verifies for this install
    /// replaces the cache (active or not: the server's answer wins). On failure the cache is kept
    /// (offline grace) and `lastError` explains why. Returns whether Likely is licensed afterwards.
    @discardableResult
    func refresh() async -> Bool {
        if License.isFreeBuild { return true }
        isChecking = true
        defer {
            isChecking = false
            notifyIfChanged()
        }
        do {
            let response = try await LicenseClient.shared.entitlement()
            guard let signed = response.signed else {
                Log.write("license", "server sent no signed entitlement")
                throw LicenseClient.ClientError.unsigned
            }
            let entitlement: EntitlementClaims
            switch EntitlementVerifier.verifiedClaims(signed, keys: License.entitlementKeys, installId: LicenseClient.installId) {
            case .success(let claims):
                entitlement = claims
            case .failure(let failure):
                Log.write("license", "server entitlement not trusted: \(public: failure.logReason)")
                throw LicenseClient.ClientError.untrusted
            }
            let fresh = License.Cached(signed: signed, checkedAt: Date())
            fresh.save()
            cached = fresh
            lastError = nil
            Log.write("license", "entitlement active=\(entitlement.active) kind=\(meta: entitlement.kind) status=\(meta: entitlement.status)")
        } catch {
            lastError = error.localizedDescription
            Log.write("license", "entitlement check failed: \(error: error)")
        }
        return isActive
    }

    /// Checks now and then every `recheckInterval`. Also notices the offline grace running out.
    func startPeriodicChecks() {
        guard !License.isFreeBuild, timer == nil else { return }
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: License.recheckInterval, repeats: true) { _ in
            Task { @MainActor in await LicenseStore.shared.refresh() }
        }
    }

    private func notifyIfChanged() {
        let active = isActive
        guard active != lastActive else { return }
        lastActive = active
        Log.write("license", "license is now \(public: active ? "active" : "inactive")")
        onActiveChange?(active)
    }

    // MARK: Checkout

    func checkoutURL(for plan: License.Plan) async throws -> URL {
        guard let serverPlan = plan.serverPlan else { return License.sourceURL }
        return try await LicenseClient.shared.checkoutURL(plan: serverPlan)
    }

    func billingPortalURL() async throws -> URL {
        try await LicenseClient.shared.billingPortalURL()
    }
}
