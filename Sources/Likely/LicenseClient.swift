import Foundation
import Security

/// Talks to the shared Onit server for licensing: device login, Stripe checkout / billing portal, and
/// entitlements. Self-contained (URLSession + Codable) so Likely keeps zero package dependencies.
///
/// Auth: `POST /v1/auth/login/device` with a per-install UUID returns a 30-day JWT, kept in the
/// Keychain. Every other call sends it as a bearer token; on a 401 we log in again and retry once.
actor LicenseClient {
    static let shared = LicenseClient()

    /// Production server. Override with `defaults write inc.synth.likely serverBaseURL http://localhost:3000`.
    static var baseURL: URL {
        if let override = UserDefaults.standard.string(forKey: "serverBaseURL"), let url = URL(string: override) {
            return url
        }
        return URL(string: "https://onit-server-v2-a93590258ea2.herokuapp.com")!
    }

    /// Stable per-install id. Device-login accounts are keyed on it, so it must never change.
    static var installId: String {
        if let id = UserDefaults.standard.string(forKey: "installId"), UUID(uuidString: id) != nil { return id }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: "installId")
        return id
    }

    enum Plan: String {
        case monthly = "likely_monthly"
        case lifetime = "likely_lifetime"
    }

    /// `GET /v1/entitlements?product=likely`.
    struct Entitlement: Codable, Equatable {
        var product: String?
        var active: Bool
        /// "subscription", "one_time" or "promo".
        var kind: String?
        var status: String?
        /// ISO 8601.
        var currentPeriodEnd: String?
        var cancelAtPeriodEnd: Bool?

        var periodEnd: Date? { currentPeriodEnd.flatMap(Self.parseDate) }

        static func parseDate(_ string: String) -> Date? {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
        }
    }

    enum ClientError: LocalizedError {
        case offline(String)
        /// 404: the server doesn't have this endpoint yet (or it's down for maintenance).
        case unavailable
        case server(status: Int, message: String?)
        case badResponse

        var errorDescription: String? {
            switch self {
            case .offline: return "Couldn't reach the Likely server. Check your connection and try again."
            case .unavailable: return "Licensing isn't available on the server yet. Try again later."
            // Server messages are developer-facing (zod validation etc.), so they only go to the log.
            case .server(let status, _): return "The Likely server returned an error (\(status)). Try again later."
            case .badResponse: return "The Likely server sent a response Likely didn't understand."
            }
        }
    }

    // MARK: Endpoints

    func entitlement() async throws -> Entitlement {
        try await send("GET", "/v1/entitlements", query: ["product": "likely"])
    }

    /// Returns the Stripe Checkout page to open in the browser.
    func checkoutURL(plan: Plan) async throws -> URL {
        struct Body: Encodable { let plan: String }
        let response: SessionResponse = try await send("POST", "/v1/subscription/stripe/checkout", body: Body(plan: plan.rawValue))
        return try Self.stripePage(response.sessionUrl, host: "checkout.stripe.com")
    }

    /// Stripe's customer portal (cancel, change card, invoices).
    func billingPortalURL() async throws -> URL {
        let response: SessionResponse = try await send("POST", "/v1/subscription/stripe/billing-portal?product=likely")
        return try Self.stripePage(response.sessionUrl, host: "billing.stripe.com")
    }

    /// Only ever hand the browser Stripe's own https page: never file:, javascript:, custom schemes,
    /// or another site (a compromised or misconfigured server can't send the user elsewhere).
    private static func stripePage(_ string: String, host: String) throws -> URL {
        guard let url = URL(string: string), url.scheme?.lowercased() == "https", url.host?.lowercased() == host,
              url.user == nil, url.password == nil, url.port == nil || url.port == 443 else {
            Log.write("license", "refused session URL host=\(URL(string: string)?.host ?? "?")")
            throw ClientError.badResponse
        }
        return url
    }

    // MARK: Auth

    private struct SessionResponse: Decodable { let sessionUrl: String }
    private struct LoginResponse: Decodable { let token: String }
    private struct ServerError: Decodable { let message: String? }

    private static let keychainAccount = "deviceToken"
    private var token: String? = Keychain.read(account: LicenseClient.keychainAccount)
    /// Shared so simultaneous calls (launch check + Settings) don't log in twice.
    private var loginTask: Task<String, Error>?

    private func validToken() async throws -> String {
        if let token { return token }
        return try await login()
    }

    private func login() async throws -> String {
        if let loginTask { return try await loginTask.value }
        let task = Task { () throws -> String in
            struct Body: Encodable { let app: String; let installId: String }
            let request = try Self.request("POST", "/v1/auth/login/device", query: [:],
                                           body: Body(app: "likely", installId: Self.installId), token: nil)
            do {
                let response: LoginResponse = try await Self.perform(request)
                return response.token
            } catch ClientError.server(let status, _) where status == 400 {
                // Servers without Likely support reject `app: "likely"` in validation.
                throw ClientError.unavailable
            }
        }
        loginTask = task
        defer { loginTask = nil }
        let newToken = try await task.value
        token = newToken
        Keychain.write(newToken, account: Self.keychainAccount)
        Log.write("license", "device login ok")
        return newToken
    }

    private func send<Response: Decodable>(_ method: String, _ path: String, query: [String: String] = [:]) async throws -> Response {
        try await send(method, path, query: query, body: Optional<String>.none)
    }

    private func send<Body: Encodable, Response: Decodable>(_ method: String, _ path: String, query: [String: String] = [:],
                                                            body: Body?) async throws -> Response {
        let first = try await validToken()
        do {
            return try await Self.perform(Self.request(method, path, query: query, body: body, token: first))
        } catch ClientError.server(let status, _) where status == 401 {
            // Expired (30-day TTL) or revoked: log in again with the same installId and retry once.
            Log.write("license", "\(path) got 401, logging in again")
            token = nil
            Keychain.delete(account: Self.keychainAccount)
            let fresh = try await login()
            return try await Self.perform(Self.request(method, path, query: query, body: body, token: fresh))
        }
    }

    // MARK: HTTP

    static func request<Body: Encodable>(_ method: String, _ path: String, query: [String: String],
                                         body: Body?, token: String?) throws -> URLRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = components.url else { throw ClientError.badResponse }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        return request
    }

    /// Runs a request and decodes a 2xx body; maps everything else to `ClientError`. Never logs tokens.
    static func perform<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            Log.write("license", "\(request.url?.path ?? "?") failed: \(error.localizedDescription)")
            throw ClientError.offline(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode(ServerError.self, from: data))?.message
            Log.write("license", "\(request.httpMethod ?? "") \(request.url?.path ?? "?") -> \(status) \(message ?? "")")
            if status == 404 { throw ClientError.unavailable }
            throw ClientError.server(status: status, message: message)
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            Log.write("license", "\(request.url?.path ?? "?") undecodable: \(error)")
            throw ClientError.badResponse
        }
    }
}

/// Minimal generic-password Keychain wrapper for the device token. Failures (e.g. a locked keychain)
/// just mean we log in again next launch, which is harmless: device login is idempotent per installId.
enum Keychain {
    private static let service = "inc.synth.likely.server"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read(account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, account: String) {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(account)
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let added = SecItemAdd(q as CFDictionary, nil)
            if added != errSecSuccess { Log.write("license", "keychain add failed: \(added)") }
        } else if status != errSecSuccess {
            Log.write("license", "keychain update failed: \(status)")
        }
    }

    static func delete(account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}
