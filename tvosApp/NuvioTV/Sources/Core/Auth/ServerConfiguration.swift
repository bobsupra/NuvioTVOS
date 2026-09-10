import Foundation

struct ServerCapabilities: Codable, Equatable {
    var emailPasswordAuth: Bool
    var tvLogin: Bool

    init(emailPasswordAuth: Bool = false, tvLogin: Bool = false) {
        self.emailPasswordAuth = emailPasswordAuth
        self.tvLogin = tvLogin
    }

    var supportsAnyAuth: Bool { emailPasswordAuth || tvLogin }

    enum CodingKeys: String, CodingKey {
        case emailPasswordAuth = "email_password_auth"
        case tvLogin = "tv_login"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        emailPasswordAuth = (try? container.decode(Bool.self, forKey: .emailPasswordAuth)) ?? false
        tvLogin = (try? container.decode(Bool.self, forKey: .tvLogin)) ?? false
    }
}

struct ServerConfiguration: Codable, Equatable {
    var backendURL: String
    var publishableKey: String
    var capabilities: ServerCapabilities
    var discoveryURL: String?

    var normalizedBackendURL: String {
        var value = backendURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    var backendIdentity: String { normalizedBackendURL }
}

struct ServerConfigurationStore {
    private let key = "nuvio.auth.serverConfiguration"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var configuration: ServerConfiguration? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ServerConfiguration.self, from: data)
    }

    @discardableResult
    func save(_ configuration: ServerConfiguration) -> Bool {
        guard let data = try? JSONEncoder().encode(configuration) else { return false }
        defaults.set(data, forKey: key)
        return defaults.data(forKey: key) == data
    }

    func clear() { defaults.removeObject(forKey: key) }
}

enum ServerDiscoveryError: LocalizedError, Equatable {
    case invalidURL(String)
    case invalidDocument(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let message), .invalidDocument(let message), .network(let message): return message
        }
    }
}

struct DiscoveredServer: Equatable {
    let configuration: ServerConfiguration
    let securityWarnings: [String]
}

enum ServerDiscoveryPolicy {
    static let officialBackend = "https://api.nuvio.tv"
    static let maxResponseBytes = 64 * 1024

    static func normalizeInput(_ input: String) throws -> URL {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let withScheme = value.contains("://") ? value : "https://" + value
        guard !value.isEmpty, let url = URL(string: withScheme),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              let host = url.host, !host.isEmpty else {
            throw ServerDiscoveryError.invalidURL("Enter an HTTP(S) backend URL without credentials or a query.")
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = scheme
        components?.host = host.lowercased()
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components?.path = path.isEmpty ? "" : "/" + path
        guard let normalized = components?.url else { throw ServerDiscoveryError.invalidURL("Invalid backend URL.") }
        let result = normalized.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard normalizedHost(url) != "api.nuvio.tv" else { throw ServerDiscoveryError.invalidURL("Use Official Server for the Nuvio backend.") }
        return URL(string: result)!
    }

    private static func normalizedHost(_ url: URL) -> String { url.host?.lowercased() ?? "" }

    static func discoveryURL(for normalized: URL) -> URL? {
        let suffix = "/.well-known/nuvio"
        var components = URLComponents(url: normalized, resolvingAgainstBaseURL: false)
        let path = normalized.path
        let basePath = path.hasSuffix(suffix)
            ? String(path.dropLast(suffix.count))
            : path
        components?.path = basePath.isEmpty ? suffix : basePath + suffix
        return components?.url
    }

    static func parse(document data: Data, inputURL: URL) throws -> DiscoveredServer {
        guard data.count <= maxResponseBytes else { throw ServerDiscoveryError.invalidDocument("Server information is too large.") }
        let object: DiscoveryDocument
        do { object = try JSONDecoder().decode(DiscoveryDocument.self, from: data) }
        catch { throw ServerDiscoveryError.invalidDocument("The server returned an invalid discovery document.") }
        guard object.version == 1, object.service.lowercased() == "nuvio", object.selfHosted else {
            throw ServerDiscoveryError.invalidDocument("This is not a supported self-hosted Nuvio server.")
        }
        let backend = try normalizeInput(object.backendURL)
        guard backend.host?.lowercased() != "api.nuvio.tv" else { throw ServerDiscoveryError.invalidDocument("The official backend cannot be selected as self-hosted.") }
        guard let key = object.publishableKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty,
              key.utf8.count <= 1024,
              key.rangeOfCharacter(from: .controlCharacters) == nil,
              !key.lowercased().contains("service_role"),
              !key.lowercased().contains("secret") else {
            throw ServerDiscoveryError.invalidDocument("The server did not provide a publishable client key.")
        }
        let capabilities = object.capabilities
        guard capabilities.supportsAnyAuth else { throw ServerDiscoveryError.invalidDocument("The server has no supported sign-in method enabled.") }
        guard inputURL.scheme?.lowercased() != "https" || backend.scheme?.lowercased() == "https" else {
            throw ServerDiscoveryError.invalidDocument("Discovery cannot downgrade from HTTPS to HTTP.")
        }
        let configuration = ServerConfiguration(backendURL: backend.absoluteString, publishableKey: key, capabilities: capabilities, discoveryURL: inputURL.absoluteString)
        return DiscoveredServer(configuration: configuration, securityWarnings: warnings(for: backend))
    }

    static func warnings(for url: URL) -> [String] {
        var result: [String] = []
        if url.scheme?.lowercased() == "http" { result.append("HTTP is not encrypted; use HTTPS when possible.") }
        let host = url.host?.lowercased() ?? ""
        let isPrivate = host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasPrefix("10.") || host.hasPrefix("192.168.") || host.hasPrefix("172.16.")
        if !isPrivate && !host.hasSuffix(".nuvio.tv") { result.append("This host is public and has not been verified by Nuvio.") }
        return result
    }

    static func redirectKeepsPort(from source: URL, to destination: URL) -> Bool {
        let sourcePort = source.port ?? defaultPort(for: source.scheme)
        let destinationPort = destination.port ?? defaultPort(for: destination.scheme)
        if sourcePort == destinationPort { return true }

        // An HTTP endpoint may legitimately redirect to HTTPS on the same
        // host. Treat the implicit HTTP/HTTPS default-port change as safe, but
        // do not allow a redirect to an arbitrary service port.
        return source.scheme?.lowercased() == "http" &&
            destination.scheme?.lowercased() == "https" &&
            source.port == nil &&
            destinationPort == 443
    }

    private static func defaultPort(for scheme: String?) -> Int? {
        switch scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }
}

private struct DiscoveryDocument: Decodable {
    let version: Int
    let service: String
    let selfHosted: Bool
    let backendURL: String
    let publishableKey: String?
    let capabilities: ServerCapabilities

    enum CodingKeys: String, CodingKey { case version, service, selfHosted = "self_hosted", backendURL = "backend_url", publishableKey = "publishable_key", capabilities }
}

final class ServerDiscoveryService {
    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    func discover(input: String) async throws -> DiscoveredServer {
        let normalized = try ServerDiscoveryPolicy.normalizeInput(input)
        guard let url = ServerDiscoveryPolicy.discoveryURL(for: normalized) else { throw ServerDiscoveryError.invalidURL("Invalid discovery URL.") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw ServerDiscoveryError.network("Could not read server information.") }
            guard let finalURL = http.url,
                  let finalScheme = finalURL.scheme?.lowercased(),
                  (finalScheme == "http" || finalScheme == "https"),
                  finalURL.host?.lowercased() == normalized.host?.lowercased(),
                  ServerDiscoveryPolicy.redirectKeepsPort(from: normalized, to: finalURL),
                  !(normalized.scheme?.lowercased() == "https" && finalURL.scheme?.lowercased() != "https") else {
                throw ServerDiscoveryError.invalidDocument("The server redirected to an unsafe address.")
            }
            return try ServerDiscoveryPolicy.parse(document: data, inputURL: normalized)
        } catch let error as ServerDiscoveryError { throw error }
        catch { throw ServerDiscoveryError.network("Could not reach that server.") }
    }
}
