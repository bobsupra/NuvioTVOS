import Foundation
import Security

/// OAuth client credentials are supplied by the application at runtime. Do not
/// embed a Google OAuth client secret in source or reuse another integration's credentials.
struct IPTVGoogleDriveConfiguration {
    let clientID: String
    let clientSecret: String

    var isConfigured: Bool {
        !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !clientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Information to present while the viewer approves Google device authorization.
struct IPTVGoogleDriveDeviceCode: Equatable {
    let deviceCode: String
    let userCode: String
    let verificationURL: URL
    let expiresAt: Date
    let pollingInterval: TimeInterval
}

enum IPTVGoogleDriveError: LocalizedError {
    case notConfigured
    case invalidProfile
    case malformedResponse
    case authorizationExpired
    case authorizationRequired
    case credentialsChanged
    case missingRefreshToken
    case invalidFileID
    case oauth(code: String, description: String?)
    case driveHTTPStatus(Int, String?)
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Google Drive OAuth is not configured."
        case .invalidProfile:
            return "A profile is required to store Google credentials."
        case .malformedResponse:
            return "Google returned an invalid response."
        case .authorizationExpired:
            return "Google device authorization expired. Request a new code."
        case .authorizationRequired:
            return "Google Drive authorization is required."
        case .credentialsChanged:
            return "Google credentials changed while the request was in progress. Retry the operation."
        case .missingRefreshToken:
            return "Google did not provide a refresh token. Revoke this app's access in Google settings and try again."
        case .invalidFileID:
            return "A Drive file ID is required."
        case .oauth(let code, let description):
            return description.map { "Google authorization failed: \(code): \($0)" }
                ?? "Google authorization failed: \(code)."
        case .driveHTTPStatus(let status, let message):
            return message.map { "Google Drive request failed (HTTP \(status)): \($0)" }
                ?? "Google Drive request failed (HTTP \(status))."
        case .keychain(let status):
            return "Google credentials could not be stored securely (Keychain \(status))."
        }
    }
}

/// The small storage interface keeps credentials replaceable in tests while
/// keeping the production refresh token in Keychain.
protocol IPTVGoogleDriveCredentialStorage {
    func refreshToken(for profileID: String) throws -> String?
    func setRefreshToken(_ token: String?, for profileID: String) throws
}

/// Coordinates credential generations across service actor instances in this process.
private final class IPTVGoogleDriveGenerationCoordinator: @unchecked Sendable {
    static let shared = IPTVGoogleDriveGenerationCoordinator()

    private let lock = NSLock()
    private var generations: [String: UInt64] = [:]

    func snapshot<Value>(for scope: String, _ read: (UInt64) throws -> Value) rethrows -> Value {
        lock.lock()
        defer { lock.unlock() }
        return try read(generations[scope, default: 0])
    }

    func isCurrent(_ generation: UInt64, for scope: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generations[scope, default: 0] == generation
    }

    @discardableResult
    func advance(for scope: String) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let next = generations[scope, default: 0] &+ 1
        generations[scope] = next
        return next
    }

    @discardableResult
    func advance(for scope: String, mutation: () throws -> Void) rethrows -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let next = generations[scope, default: 0] &+ 1
        generations[scope] = next
        try mutation()
        return next
    }

    func commitIfCurrent(
        _ expected: UInt64,
        for scope: String,
        mutation: () throws -> Void
    ) rethrows -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard generations[scope, default: 0] == expected else { return nil }
        try mutation()
        let next = expected &+ 1
        generations[scope] = next
        return next
    }

    func advanceIfCurrent(
        _ expected: UInt64,
        for scope: String,
        mutation: () throws -> Void
    ) rethrows -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard generations[scope, default: 0] == expected else { return nil }
        let next = expected &+ 1
        generations[scope] = next
        try mutation()
        return next
    }

    func performIfCurrent<Value>(
        _ expected: UInt64,
        for scope: String,
        _ body: () throws -> Value
    ) rethrows -> Value? {
        lock.lock()
        defer { lock.unlock() }
        guard generations[scope, default: 0] == expected else { return nil }
        return try body()
    }
}

struct IPTVGoogleDriveKeychainCredentialStorage: IPTVGoogleDriveCredentialStorage {
    private static let service = "com.nuvio.tv.iptv.google-drive"

    func refreshToken(for profileID: String) throws -> String? {
        var query = baseQuery(profileID: profileID)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw IPTVGoogleDriveError.keychain(status) }
        guard let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
            throw IPTVGoogleDriveError.keychain(errSecDecode)
        }
        return token.isEmpty ? nil : token
    }

    func setRefreshToken(_ token: String?, for profileID: String) throws {
        let query = baseQuery(profileID: profileID)
        guard let token, !token.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw IPTVGoogleDriveError.keychain(status)
            }
            return
        }

        var item = query
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecValueData as String] = Data(token.utf8)
        var status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: Data(token.utf8)] as CFDictionary)
        }
        guard status == errSecSuccess else { throw IPTVGoogleDriveError.keychain(status) }
    }

    private func baseQuery(profileID: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: profileID]
    }
}

/// Google TV device authorization and data transport for one explicitly selected
/// Drive file. This does not discover files, select one, or synchronize data.
actor IPTVGoogleDriveService {
    static let driveFileScope = "https://www.googleapis.com/auth/drive.file"

    private static let deviceCodeURL = URL(string: "https://oauth2.googleapis.com/device/code")!
    private static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    private static let filesURL = URL(string: "https://www.googleapis.com/drive/v3/files")!
    private static let uploadURL = URL(string: "https://www.googleapis.com/upload/drive/v3/files")!
    private static let deviceGrant = "urn:ietf:params:oauth:grant-type:device_code"

    private let configuration: IPTVGoogleDriveConfiguration
    private let profileID: String
    private let credentialStorage: any IPTVGoogleDriveCredentialStorage
    private let session: URLSession
    private var accessToken: String?
    private var accessTokenExpiresAt = Date.distantPast
    private var accessTokenGeneration: UInt64?

    init(
        configuration: IPTVGoogleDriveConfiguration,
        profileID: String,
        credentialStorage: any IPTVGoogleDriveCredentialStorage = IPTVGoogleDriveKeychainCredentialStorage(),
        session: URLSession = IPTVGoogleDriveSession.shared
    ) {
        self.configuration = configuration
        self.profileID = profileID
        self.credentialStorage = credentialStorage
        self.session = session
    }

    /// Starts Google's device flow. Present `userCode` and `verificationURL` to
    /// the viewer, then pass the returned value to `completeDeviceAuthorization`.
    func requestDeviceCode() async throws -> IPTVGoogleDriveDeviceCode {
        try requireConfiguration()
        let response = try await oauthRequest(
            url: Self.deviceCodeURL,
            fields: [
                ("client_id", configuration.clientID),
                ("scope", Self.driveFileScope)
            ]
        )
        guard let deviceCode = response["device_code"] as? String,
              let userCode = response["user_code"] as? String,
              let expiresIn = Self.number(response["expires_in"]),
              let interval = Self.number(response["interval"]) else {
            throw IPTVGoogleDriveError.malformedResponse
        }
        let verificationString = response["verification_url"] as? String
            ?? response["verification_uri"] as? String
            ?? "https://www.google.com/device"
        guard let verificationURL = URL(string: verificationString),
              ["https", "http"].contains(verificationURL.scheme?.lowercased() ?? "") else {
            throw IPTVGoogleDriveError.malformedResponse
        }
        return IPTVGoogleDriveDeviceCode(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationURL: verificationURL,
            expiresAt: Date().addingTimeInterval(expiresIn),
            pollingInterval: max(1, interval)
        )
    }

    /// Polls until the viewer approves or the code expires. Cancelling the task
    /// stops polling. The refresh token is stored in Keychain for this profile.
    func completeDeviceAuthorization(using code: IPTVGoogleDriveDeviceCode) async throws {
        try requireConfiguration()
        let scopedProfileID = try validatedProfileID()
        let credentialScope = Self.credentialScope(profileID: scopedProfileID)
        let authorizationGeneration = IPTVGoogleDriveGenerationCoordinator.shared.advance(for: credentialScope)
        accessToken = nil
        accessTokenExpiresAt = .distantPast
        accessTokenGeneration = nil
        var interval = code.pollingInterval

        while Date() < code.expiresAt {
            guard IPTVGoogleDriveGenerationCoordinator.shared.isCurrent(authorizationGeneration, for: credentialScope) else {
                throw IPTVGoogleDriveError.credentialsChanged
            }
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            try Task.checkCancellation()
            guard IPTVGoogleDriveGenerationCoordinator.shared.isCurrent(authorizationGeneration, for: credentialScope) else {
                throw IPTVGoogleDriveError.credentialsChanged
            }

            let response: [String: Any]
            do {
                response = try await oauthRequest(
                    url: Self.tokenURL,
                    fields: [
                        ("client_id", configuration.clientID),
                        ("client_secret", configuration.clientSecret),
                        ("device_code", code.deviceCode),
                        ("grant_type", Self.deviceGrant)
                    ]
                )
            } catch let error as IPTVGoogleDriveError {
                guard IPTVGoogleDriveGenerationCoordinator.shared.isCurrent(authorizationGeneration, for: credentialScope) else {
                    throw IPTVGoogleDriveError.credentialsChanged
                }
                switch error {
                case .oauth("authorization_pending", _):
                    continue
                case .oauth("slow_down", _):
                    interval += 5
                    continue
                case .driveHTTPStatus(let status, _) where status >= 500:
                    continue
                default:
                    throw error
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code != .cancelled {
                guard IPTVGoogleDriveGenerationCoordinator.shared.isCurrent(authorizationGeneration, for: credentialScope) else {
                    throw IPTVGoogleDriveError.credentialsChanged
                }
                continue
            }
            guard IPTVGoogleDriveGenerationCoordinator.shared.isCurrent(authorizationGeneration, for: credentialScope) else {
                throw IPTVGoogleDriveError.credentialsChanged
            }

            if let returnedScope = response["scope"] as? String,
               !returnedScope.isEmpty,
               !returnedScope.split(separator: " ").contains(Substring(Self.driveFileScope)) {
                throw IPTVGoogleDriveError.oauth(code: "access_denied", description: "Drive file access was not granted.")
            }
            guard let token = response["access_token"] as? String, !token.isEmpty else {
                throw IPTVGoogleDriveError.malformedResponse
            }

            guard let refreshToken = response["refresh_token"] as? String, !refreshToken.isEmpty else {
                throw IPTVGoogleDriveError.missingRefreshToken
            }
            guard let committedGeneration = try IPTVGoogleDriveGenerationCoordinator.shared.commitIfCurrent(
                authorizationGeneration,
                for: credentialScope,
                mutation: { try credentialStorage.setRefreshToken(refreshToken, for: scopedProfileID) }
            ) else {
                throw IPTVGoogleDriveError.credentialsChanged
            }
            accessToken = token
            accessTokenExpiresAt = Date().addingTimeInterval(Self.number(response["expires_in"]) ?? 3600)
            accessTokenGeneration = committedGeneration
            return
        }
        throw IPTVGoogleDriveError.authorizationExpired
    }

    /// Downloads bytes from the Drive file identified by `fileID`.
    func readFile(fileID: String) async throws -> Data {
        let url = try Self.fileURL(base: Self.filesURL, fileID: fileID, queryItems: [URLQueryItem(name: "alt", value: "media")])
        return try await performDriveRequest { token in
            var request = URLRequest(url: url, timeoutInterval: 60)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return request
        }
    }

    /// Replaces the contents of the Drive file identified by `fileID`.
    /// This never creates or deletes files.
    func writeFile(fileID: String, data: Data, contentType: String = "application/json") async throws {
        let url = try Self.fileURL(
            base: Self.uploadURL,
            fileID: fileID,
            queryItems: [URLQueryItem(name: "uploadType", value: "media")]
        )
        _ = try await performDriveRequest { token in
            var request = URLRequest(url: url, timeoutInterval: 60)
            request.httpMethod = "PATCH"
            request.httpBody = data
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            return request
        }
    }

    /// Clears this profile's locally stored credential. It does not revoke the
    /// Google grant or change anything in Drive.
    func clearLocalCredentials() throws {
        let scopedProfileID = try validatedProfileID()
        let credentialScope = Self.credentialScope(profileID: scopedProfileID)
        accessToken = nil
        accessTokenExpiresAt = .distantPast
        accessTokenGeneration = nil
        try IPTVGoogleDriveGenerationCoordinator.shared.advance(for: credentialScope) {
            try credentialStorage.setRefreshToken(nil, for: scopedProfileID)
        }
    }

    private func validAccessToken(forceRefresh: Bool = false) async throws -> String {
        try requireConfiguration()
        let scopedProfileID = try validatedProfileID()
        let credentialScope = Self.credentialScope(profileID: scopedProfileID)
        let (requestGeneration, refreshToken) = try IPTVGoogleDriveGenerationCoordinator.shared.snapshot(for: credentialScope) { generation in
            (generation, try credentialStorage.refreshToken(for: scopedProfileID))
        }
        if !forceRefresh,
           let accessToken,
           accessTokenGeneration == requestGeneration,
           Date() < accessTokenExpiresAt.addingTimeInterval(-60) {
            return accessToken
        }
        guard let refreshToken, !refreshToken.isEmpty else {
            throw IPTVGoogleDriveError.authorizationRequired
        }

        let response: [String: Any]
        do {
            response = try await oauthRequest(
                url: Self.tokenURL,
                fields: [
                    ("client_id", configuration.clientID),
                    ("client_secret", configuration.clientSecret),
                    ("refresh_token", refreshToken),
                    ("grant_type", "refresh_token")
                ]
            )
        } catch {
            guard IPTVGoogleDriveGenerationCoordinator.shared.isCurrent(requestGeneration, for: credentialScope) else {
                throw IPTVGoogleDriveError.credentialsChanged
            }
            if let authError = error as? IPTVGoogleDriveError,
               case .oauth("invalid_grant", _) = authError {
                let cleared = try IPTVGoogleDriveGenerationCoordinator.shared.advanceIfCurrent(
                    requestGeneration,
                    for: credentialScope,
                    mutation: { try credentialStorage.setRefreshToken(nil, for: scopedProfileID) }
                )
                guard cleared != nil else { throw IPTVGoogleDriveError.credentialsChanged }
                accessToken = nil
                accessTokenExpiresAt = .distantPast
                accessTokenGeneration = nil
                throw IPTVGoogleDriveError.authorizationRequired
            }
            throw error
        }
        guard let token = response["access_token"] as? String, !token.isEmpty else {
            throw IPTVGoogleDriveError.malformedResponse
        }
        guard let committedToken = IPTVGoogleDriveGenerationCoordinator.shared.performIfCurrent(requestGeneration, for: credentialScope, {
            accessToken = token
            accessTokenExpiresAt = Date().addingTimeInterval(Self.number(response["expires_in"]) ?? 3600)
            accessTokenGeneration = requestGeneration
            return token
        }) else {
            throw IPTVGoogleDriveError.credentialsChanged
        }
        return committedToken
    }

    private func performDriveRequest(build: (String) -> URLRequest) async throws -> Data {
        let scopedProfileID = try validatedProfileID()
        let credentialScope = Self.credentialScope(profileID: scopedProfileID)
        let requestGeneration = IPTVGoogleDriveGenerationCoordinator.shared.snapshot(for: credentialScope) { $0 }
        for attempt in 0..<2 {
            guard IPTVGoogleDriveGenerationCoordinator.shared.isCurrent(requestGeneration, for: credentialScope) else {
                throw IPTVGoogleDriveError.credentialsChanged
            }
            let token = try await validAccessToken(forceRefresh: attempt > 0)
            guard IPTVGoogleDriveGenerationCoordinator.shared.isCurrent(requestGeneration, for: credentialScope) else {
                throw IPTVGoogleDriveError.credentialsChanged
            }
            let request = build(token)
            let (data, response) = try await session.data(for: request)
            guard IPTVGoogleDriveGenerationCoordinator.shared.isCurrent(requestGeneration, for: credentialScope) else {
                throw IPTVGoogleDriveError.credentialsChanged
            }
            guard let http = response as? HTTPURLResponse else { throw IPTVGoogleDriveError.malformedResponse }
            if http.statusCode == 401, attempt == 0 { continue }
            guard (200..<300).contains(http.statusCode) else {
                throw IPTVGoogleDriveError.driveHTTPStatus(http.statusCode, Self.driveErrorMessage(from: data))
            }
            return data
        }
        throw IPTVGoogleDriveError.authorizationRequired
    }

    private func oauthRequest(url: URL, fields: [(String, String)]) async throws -> [String: Any] {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.httpBody = Self.formEncoded(fields)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw IPTVGoogleDriveError.malformedResponse
        }
        if let code = json["error"] as? String {
            throw IPTVGoogleDriveError.oauth(code: code, description: json["error_description"] as? String)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw IPTVGoogleDriveError.driveHTTPStatus(http.statusCode, Self.driveErrorMessage(from: data))
        }
        return json
    }

    private func requireConfiguration() throws {
        guard configuration.isConfigured else { throw IPTVGoogleDriveError.notConfigured }
    }

    private func validatedProfileID() throws -> String {
        let value = profileID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw IPTVGoogleDriveError.invalidProfile }
        return value
    }

    private static func credentialScope(profileID: String) -> String {
        profileID
    }

    private static func fileURL(base: URL, fileID: String, queryItems: [URLQueryItem]) throws -> URL {
        let identifier = fileID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty,
              let encodedID = identifier.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%"))) else {
            throw IPTVGoogleDriveError.invalidFileID
        }
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw IPTVGoogleDriveError.malformedResponse
        }
        components.percentEncodedPath += "/\(encodedID)"
        components.queryItems = queryItems
        guard let url = components.url else { throw IPTVGoogleDriveError.malformedResponse }
        return url
    }

    private static func formEncoded(_ fields: [(String, String)]) -> Data {
        var components = URLComponents()
        components.queryItems = fields.map { URLQueryItem(name: $0.0, value: $0.1) }
        // URLComponents leaves literal `+` characters in query values, while
        // application/x-www-form-urlencoded decoders interpret them as spaces.
        let query = (components.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
        return Data(query.utf8)
    }

    private static func number(_ value: Any?) -> TimeInterval? {
        (value as? NSNumber)?.doubleValue
    }

    private static func driveErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any] else { return nil }
        return error["message"] as? String
    }
}

/// Google Drive media downloads can redirect to a signed Google content URL.
/// Follow only HTTPS Google content redirects and strip the bearer token first.
private enum IPTVGoogleDriveSession {
    static let shared = URLSession(
        configuration: .ephemeral,
        delegate: RedirectGuard(),
        delegateQueue: nil
    )

    private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            guard let original = task.originalRequest?.url,
                  let destination = request.url else {
                completionHandler(nil)
                return
            }
            if Self.sameOrigin(original, destination) {
                completionHandler(request)
                return
            }

            let destinationHost = destination.host?.lowercased() ?? ""
            let isGoogleContentHost = destinationHost == "googleusercontent.com"
                || destinationHost.hasSuffix(".googleusercontent.com")
                || destinationHost == "googleapis.com"
                || destinationHost.hasSuffix(".googleapis.com")
            guard task.originalRequest?.httpMethod?.uppercased() == "GET",
                  original.host?.lowercased() == "www.googleapis.com",
                  destination.scheme?.lowercased() == "https",
                  isGoogleContentHost else {
                completionHandler(nil)
                return
            }

            var safeRequest = request
            safeRequest.setValue(nil, forHTTPHeaderField: "Authorization")
            safeRequest.setValue(nil, forHTTPHeaderField: "Cookie")
            completionHandler(safeRequest)
        }

        private static func sameOrigin(_ first: URL, _ second: URL) -> Bool {
            func port(_ url: URL) -> Int? {
                if let explicit = url.port { return explicit }
                switch url.scheme?.lowercased() {
                case "https": return 443
                case "http": return 80
                default: return nil
                }
            }
            return first.scheme?.lowercased() == second.scheme?.lowercased()
                && first.host?.lowercased() == second.host?.lowercased()
                && port(first) == port(second)
        }
    }
}
