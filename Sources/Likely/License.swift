import Foundation

/// Paid license state. Likely is open source: builds made with `LIKELY_FREE=1 ./build.sh` skip the
/// license page entirely and never talk to the server.
///
/// Paid builds buy through Stripe Checkout on the shared Onit server (see `LicenseClient`) and cache
/// the resulting entitlement locally, so Likely keeps working offline for a while (`Cached.trusted`).
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
        /// Renews every `priceUnit` until cancelled; gets the renewal disclosure beside the offer.
        let autoRenews: Bool
        /// What the server sells for this plan; nil for "build it yourself".
        let serverPlan: LicenseClient.Plan?
        let buttonTitle: String

        /// Legal copy beside a subscription offer, e.g. "$3/month, renews automatically until you cancel. …".
        var disclosure: String? {
            guard autoRenews else { return nil }
            let unit = priceUnit.replacingOccurrences(of: " ", with: "")   // "/ month" -> "/month"
            return "\(price)\(unit), renews automatically until you cancel. Cancel anytime in Settings → General → License, or email contact@cloudless.so."
        }
    }

    static let sourceURL = URL(string: "https://github.com/synth-inc/likely")!
    static let termsURL = URL(string: "https://synth-inc.github.io/likely/terms.html")!
    static let privacyURL = URL(string: "https://synth-inc.github.io/likely/privacy.html")!

    /// Whether Likely may talk to the license server (`LicenseClient`): only once the user has seen
    /// the welcome screen's install-ID notice (`Settings.sawServerNotice`). Covers the license server
    /// only, not Sparkle's update checks.
    static var mayContactServer: Bool { !isFreeBuild && Settings.sawServerNotice }

    static let plans: [Plan] = [
        Plan(kind: .subscription,
             headline: "I want Likely to keep getting better",
             price: "$3", priceUnit: "/ month",                                                          // TODO: confirm price
             detail: "New features and improvements as they ship.",
             autoRenews: true,
             serverPlan: .monthly,
             buttonTitle: "Subscribe"),
        Plan(kind: .oneTime,
             headline: "Just the app, please",
             price: "$29", priceUnit: "once",
             detail: "One payment, and you can use the app for as long as you like.",
             autoRenews: false,
             serverPlan: .lifetime,
             buttonTitle: "Buy Once"),
        Plan(kind: .free,
             headline: "I'm allergic to paying",
             price: "Free", priceUnit: "",
             detail: "You can use Likely for free, but we're not going to make it easy for you.",
             autoRenews: false,
             serverPlan: nil,
             buttonTitle: "Open GitHub"),
    ]

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

    /// Whether Likely may search (and run tests): the one place that decides it, for the app's pickers
    /// and `Likely --eval`. Today the cached entitlement (no network, no UI); a server-signed license
    /// can replace it here.
    static func permitsSearches() -> Bool { isActive }

    /// Readable from any thread (AppDelegate at launch, onboarding). `LicenseStore` keeps the cache fresh.
    static var isActive: Bool { isFreeBuild || devOverride != nil || Cached.load()?.trusted() == true }

    /// How long a cached active subscription keeps working without reaching the server, and how long
    /// past `currentPeriodEnd` we wait for a renewal to show up before turning it off.
    static let offlineGrace: TimeInterval = 14 * 24 * 3600
    /// Re-check this often while running (plus at launch and after checkout).
    static let recheckInterval: TimeInterval = 12 * 3600

    /// The last entitlement the server gave us, with when we got it.
    struct Cached: Codable, Equatable {
        var entitlement: LicenseClient.Entitlement
        var checkedAt: Date

        private static let key = "licenseEntitlement"

        static func load() -> Cached? {
            UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(Cached.self, from: $0) }
        }

        func save() {
            if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
        }

        var kind: Kind? {
            guard entitlement.active else { return nil }
            return entitlement.kind == "one_time" ? .oneTime : .subscription
        }

        /// Lifetime purchases are trusted indefinitely once confirmed. Subscriptions and promos are
        /// trusted for `offlineGrace` since the last successful check, and stop `offlineGrace` after
        /// their period ends if no renewal has been seen.
        func trusted(at now: Date = Date()) -> Bool {
            guard entitlement.active else { return false }
            if entitlement.kind == "one_time" { return true }
            guard now.timeIntervalSince(checkedAt) < License.offlineGrace else { return false }
            if let end = entitlement.periodEnd, now > end.addingTimeInterval(License.offlineGrace) { return false }
            return true
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
    }

    var isActive: Bool { License.isFreeBuild || License.devOverride != nil || cached?.trusted() == true }

    /// Plan the user owns, for "Active" badges.
    var activeKind: License.Kind? { License.devOverride ?? (isActive ? cached?.kind : nil) }

    /// One line for Settings.
    var statusText: String {
        if License.isFreeBuild { return "Free build" }
        if let kind = License.devOverride {
            return "Developer license override (\(kind == .oneTime ? "one-time" : "subscription"))"
        }
        guard isActive, let entitlement = cached?.entitlement else { return "Not active" }
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
        return isActive && cached?.entitlement.kind == "subscription"
    }

    /// Asks the server for the current entitlement. On failure the cache is kept (offline grace) and
    /// `lastError` explains why. Returns whether Likely is licensed afterwards.
    @discardableResult
    func refresh() async -> Bool {
        if License.isFreeBuild { return true }
        // Not past the welcome notice yet: no device login, keep whatever is cached.
        guard License.mayContactServer else { return isActive }
        isChecking = true
        defer {
            isChecking = false
            notifyIfChanged()
        }
        do {
            let entitlement = try await LicenseClient.shared.entitlement()
            let fresh = License.Cached(entitlement: entitlement, checkedAt: Date())
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
    /// Does nothing until `License.mayContactServer`; onboarding calls it again once the user
    /// continues past the welcome screen.
    func startPeriodicChecks() {
        guard !License.isFreeBuild, License.mayContactServer, timer == nil else { return }
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
