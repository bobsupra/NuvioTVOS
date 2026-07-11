import Combine
import Foundation

/// Providers with the Android TV-style QR/device-code sign-in flow.
enum DebridAccountProvider: String, CaseIterable, Identifiable {
    case torbox
    case premiumize

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .torbox: return "Torbox"
        case .premiumize: return "Premiumize"
        }
    }

    var debridKind: DebridProviderKind {
        switch self {
        case .torbox: return .torbox
        case .premiumize: return .premiumize
        }
    }
}

/// The short-lived approval information shown on the Apple TV.
struct DebridDeviceAuthorization: Equatable {
    let provider: DebridAccountProvider
    let deviceCode: String
    let userCode: String
    /// Full link, used as a fallback when the friendly link is not available.
    let verificationURL: String
    /// The link encoded into the QR code and displayed under it.
    let friendlyVerificationURL: String
    let pollingInterval: TimeInterval
    let expiresAt: Date?
}

enum DebridDeviceAuthorizationResult {
    case authorized(String)
    case pending
    case expired
    case failed(String?)
}

enum DebridCredentials {
    static func token(for kind: DebridProviderKind, store: UserDefaults) -> String {
        let providerKey: String?
        switch kind {
        case .torbox: providerKey = SettingsKey.torboxAccessToken
        case .premiumize: providerKey = SettingsKey.premiumizeAccessToken
        case .none, .realDebrid, .allDebrid, .debridLink: providerKey = nil
        }

        let providerValue = providerKey.flatMap { store.string(forKey: $0) }
        let providerToken = providerValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !providerToken.isEmpty { return providerToken }

        // Retain existing manual credentials after upgrading to the account UI.
        guard DebridProviderKind(settingsValue: store.string(forKey: SettingsKey.debridProvider)) == kind else {
            return ""
        }
        return (store.string(forKey: SettingsKey.debridApiKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func token(for provider: DebridAccountProvider, store: UserDefaults) -> String {
        token(for: provider.debridKind, store: store)
    }

    static func save(_ token: String, for provider: DebridAccountProvider, store: UserDefaults) {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let key: String
        switch provider {
        case .torbox: key = SettingsKey.torboxAccessToken
        case .premiumize: key = SettingsKey.premiumizeAccessToken
        }
        store.set(value, forKey: key)

        // Keep the legacy selected-provider value in step with a new device
        // connection. Existing stream and Cloud Library entry points therefore
        // work immediately, while provider-specific tokens keep both accounts.
        store.set(provider.debridKind.rawValue, forKey: SettingsKey.debridProvider)
        store.set(value, forKey: SettingsKey.debridApiKey)
    }

    static func remove(provider: DebridAccountProvider, store: UserDefaults) {
        let key = provider == .torbox ? SettingsKey.torboxAccessToken : SettingsKey.premiumizeAccessToken
        store.removeObject(forKey: key)

        let selected = DebridProviderKind(settingsValue: store.string(forKey: SettingsKey.debridProvider))
        guard selected == provider.debridKind else { return }
        store.removeObject(forKey: SettingsKey.debridApiKey)
        store.set(DebridProviderKind.none.rawValue, forKey: SettingsKey.debridProvider)
    }
}

private enum PremiumizeOAuthConfiguration {
    static var clientID: String {
        (Bundle.main.object(forInfoDictionaryKey: "PREMIUMIZE_CLIENT_ID") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum DebridDeviceAuthorizationError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        }
    }
}

/// Port of Android TV's Torbox/Premiumize device-authorization clients.
struct DebridDeviceAuthorizationService {
    private let session: URLSession
    private let decoder = JSONDecoder()

    init(session: URLSession = .shared) {
        self.session = session
    }

    func start(provider: DebridAccountProvider) async throws -> DebridDeviceAuthorization {
        switch provider {
        case .torbox: return try await startTorbox()
        case .premiumize: return try await startPremiumize()
        }
    }

    func redeem(_ authorization: DebridDeviceAuthorization) async -> DebridDeviceAuthorizationResult {
        do {
            switch authorization.provider {
            case .torbox: return try await redeemTorbox(deviceCode: authorization.deviceCode)
            case .premiumize: return try await redeemPremiumize(deviceCode: authorization.deviceCode)
            }
        } catch is CancellationError {
            return .pending
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func startTorbox() async throws -> DebridDeviceAuthorization {
        var components = URLComponents(string: "https://api.torbox.app/v1/api/user/auth/device/start")!
        components.queryItems = [URLQueryItem(name: "app", value: "Nuvio")]
        guard let url = components.url else { throw DebridDeviceAuthorizationError.message("Invalid Torbox sign-in URL.") }

        let (data, response) = try await data(for: URLRequest(url: url))
        let envelope = try decoder.decode(TorboxEnvelope<TorboxDeviceStart>.self, from: data)
        guard (200...299).contains(response.statusCode), envelope.success != false,
              let auth = envelope.data,
              let deviceCode = auth.deviceCode?.nonEmpty,
              let userCode = auth.code?.nonEmpty,
              let verificationURL = auth.verificationURL?.nonEmpty else {
            throw DebridDeviceAuthorizationError.message(envelope.detail ?? envelope.error ?? "Torbox could not start account linking.")
        }

        return DebridDeviceAuthorization(
            provider: .torbox,
            deviceCode: deviceCode,
            userCode: userCode,
            verificationURL: verificationURL,
            friendlyVerificationURL: auth.friendlyVerificationURL?.nonEmpty ?? verificationURL,
            pollingInterval: TimeInterval(max(auth.interval ?? 5, 1)),
            expiresAt: Self.date(from: auth.expiresAt)
        )
    }

    private func redeemTorbox(deviceCode: String) async throws -> DebridDeviceAuthorizationResult {
        let url = URL(string: "https://api.torbox.app/v1/api/user/auth/device/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(TorboxDeviceTokenRequest(deviceCode: deviceCode))

        let (data, response) = try await data(for: request)
        let envelope = try? decoder.decode(TorboxEnvelope<TorboxDeviceToken>.self, from: data)
        if (200...299).contains(response.statusCode), envelope?.success != false,
           let token = envelope?.data?.accessToken?.nonEmpty {
            return .authorized(token)
        }

        let message = [envelope?.error, envelope?.detail, String(data: data, encoding: .utf8)]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        if message.contains("pending") || message.contains("not authorized") ||
            message.contains("not been used") || message.contains("not used yet") ||
            message.contains("scan the code") || [404, 409, 425].contains(response.statusCode) {
            return .pending
        }
        if message.contains("expired") || response.statusCode == 410 { return .expired }
        return .failed(envelope?.detail ?? envelope?.error)
    }

    private func startPremiumize() async throws -> DebridDeviceAuthorization {
        let clientID = try premiumizeClientID()
        let (data, response) = try await formRequest(
            url: URL(string: "https://www.premiumize.me/token")!,
            fields: ["response_type": "device_code", "client_id": clientID]
        )
        let auth = try decoder.decode(PremiumizeDeviceStart.self, from: data)
        guard (200...299).contains(response.statusCode),
              let deviceCode = auth.deviceCode?.nonEmpty,
              let userCode = auth.userCode?.nonEmpty,
              let verificationURL = auth.verificationURI?.nonEmpty else {
            throw DebridDeviceAuthorizationError.message(auth.errorDescription ?? auth.error ?? "Premiumize could not start account linking.")
        }

        return DebridDeviceAuthorization(
            provider: .premiumize,
            deviceCode: deviceCode,
            userCode: userCode,
            verificationURL: verificationURL,
            friendlyVerificationURL: auth.verificationURIComplete?.nonEmpty ?? verificationURL,
            pollingInterval: TimeInterval(max(auth.interval ?? 5, 1)),
            expiresAt: auth.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
        )
    }

    private func redeemPremiumize(deviceCode: String) async throws -> DebridDeviceAuthorizationResult {
        let clientID = try premiumizeClientID()
        let (data, response) = try await formRequest(
            url: URL(string: "https://www.premiumize.me/token")!,
            fields: ["grant_type": "device_code", "code": deviceCode, "client_id": clientID]
        )
        let token = try? decoder.decode(PremiumizeDeviceToken.self, from: data)
        if (200...299).contains(response.statusCode), let accessToken = token?.accessToken?.nonEmpty {
            return .authorized(accessToken)
        }

        switch token?.error?.lowercased() {
        case "authorization_pending", "slow_down": return .pending
        case "invalid_grant", "expired_token": return .expired
        case "access_denied": return .failed(token?.errorDescription)
        default:
            return response.statusCode == 400 && token?.error?.isEmpty != false
                ? .pending
                : .failed(token?.errorDescription ?? token?.error ?? String(data: data, encoding: .utf8))
        }
    }

    private func premiumizeClientID() throws -> String {
        guard !PremiumizeOAuthConfiguration.clientID.isEmpty else {
            throw DebridDeviceAuthorizationError.message("Premiumize sign-in is not configured in this build.")
        }
        return PremiumizeOAuthConfiguration.clientID
    }

    private func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DebridDeviceAuthorizationError.message("Invalid account-link response.")
        }
        return (data, http)
    }

    private func formRequest(url: URL, fields: [String: String]) async throws -> (Data, HTTPURLResponse) {
        var components = URLComponents()
        components.queryItems = fields.map(URLQueryItem.init(name:value:))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        return try await data(for: request)
    }

    private static func date(from value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value)
    }
}

@MainActor
final class DebridAccountConnectionViewModel: ObservableObject {
    enum State: Equatable {
        case idle
        case starting
        case awaitingApproval
        case connected
        case failed
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var authorization: DebridDeviceAuthorization?
    @Published private(set) var statusMessage: String?
    @Published private(set) var isPolling = false

    private let service: DebridDeviceAuthorizationService
    private var flowTask: Task<Void, Never>?
    private var generation = 0

    init(service: DebridDeviceAuthorizationService = DebridDeviceAuthorizationService()) {
        self.service = service
    }

    deinit { flowTask?.cancel() }

    func connect(_ provider: DebridAccountProvider) {
        cancel()
        generation &+= 1
        let currentGeneration = generation
        state = .starting
        statusMessage = "Preparing account link…"

        flowTask = Task { [weak self, service] in
            do {
                let authorization = try await service.start(provider: provider)
                guard !Task.isCancelled else { return }
                self?.beginPolling(authorization, generation: currentGeneration)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self?.generation == currentGeneration else { return }
                self?.authorization = nil
                self?.state = .failed
                self?.statusMessage = error.localizedDescription
            }
        }
    }

    func cancel() {
        generation &+= 1
        flowTask?.cancel()
        flowTask = nil
        authorization = nil
        isPolling = false
        if state != .connected { state = .idle }
        if state != .connected { statusMessage = nil }
    }

    private func beginPolling(_ authorization: DebridDeviceAuthorization, generation: Int) {
        guard self.generation == generation else { return }
        self.authorization = authorization
        state = .awaitingApproval
        statusMessage = "Waiting for approval…"

        flowTask = Task { [weak self, service] in
            while !Task.isCancelled {
                if let expiresAt = authorization.expiresAt, Date() >= expiresAt {
                    self?.finish(.expired, authorization: authorization, generation: generation)
                    return
                }

                do {
                    try await Task.sleep(for: .seconds(authorization.pollingInterval))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }

                self?.isPolling = true
                let result = await service.redeem(authorization)
                self?.isPolling = false
                guard !Task.isCancelled else { return }
                if self?.finish(result, authorization: authorization, generation: generation) == true { return }
            }
        }
    }

    /// Returns true when polling should stop.
    @discardableResult
    private func finish(
        _ result: DebridDeviceAuthorizationResult,
        authorization: DebridDeviceAuthorization,
        generation: Int
    ) -> Bool {
        guard self.generation == generation else { return true }
        switch result {
        case .pending:
            statusMessage = "Waiting for approval…"
            return false
        case .authorized(let token):
            DebridCredentials.save(token, for: authorization.provider, store: ProfileSettings.current)
            state = .connected
            statusMessage = "\(authorization.provider.displayName) connected."
            return true
        case .expired:
            state = .failed
            statusMessage = "The approval code expired. Try again."
            return true
        case .failed(let message):
            state = .failed
            statusMessage = message?.nonEmpty ?? "Account linking failed. Try again."
            return true
        }
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct TorboxEnvelope<Value: Decodable>: Decodable {
    let success: Bool?
    let error: String?
    let detail: String?
    let data: Value?
}

private struct TorboxDeviceStart: Decodable {
    let deviceCode: String?
    let code: String?
    let verificationURL: String?
    let friendlyVerificationURL: String?
    let interval: Int?
    let expiresAt: String?

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case code
        case verificationURL = "verification_url"
        case friendlyVerificationURL = "friendly_verification_url"
        case interval
        case expiresAt = "expires_at"
    }
}

private struct TorboxDeviceTokenRequest: Encodable {
    let deviceCode: String
    enum CodingKeys: String, CodingKey { case deviceCode = "device_code" }
}

private struct TorboxDeviceToken: Decodable {
    let accessToken: String?
    enum CodingKeys: String, CodingKey { case accessToken = "access_token" }
}

private struct PremiumizeDeviceStart: Decodable {
    let deviceCode: String?
    let userCode: String?
    let verificationURI: String?
    let verificationURIComplete: String?
    let expiresIn: Int?
    let interval: Int?
    let error: String?
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURI = "verification_uri"
        case verificationURIComplete = "verification_uri_complete"
        case expiresIn = "expires_in"
        case interval
        case error
        case errorDescription = "error_description"
    }
}

private struct PremiumizeDeviceToken: Decodable {
    let accessToken: String?
    let error: String?
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case error
        case errorDescription = "error_description"
    }
}
