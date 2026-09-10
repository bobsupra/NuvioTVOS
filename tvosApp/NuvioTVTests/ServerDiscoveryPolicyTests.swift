import XCTest
@testable import NuvioTV

final class ServerDiscoveryPolicyTests: XCTestCase {
    func testNormalizesHostAndPath() throws {
        XCTAssertEqual(try ServerDiscoveryPolicy.normalizeInput("  example.com/app/  ").absoluteString, "https://example.com/app")
        let discoveryInput = try ServerDiscoveryPolicy.normalizeInput("example.com/app/.well-known/nuvio")
        XCTAssertEqual(
            ServerDiscoveryPolicy.discoveryURL(for: discoveryInput)?.absoluteString,
            "https://example.com/app/.well-known/nuvio"
        )
    }

    func testParsesValidDocumentAndCapabilities() throws {
        let data = #"{"version":1,"service":"nuvio","self_hosted":true,"backend_url":"https://media.example.com/","publishable_key":"sb_publishable_test","capabilities":{"email_password_auth":true,"tv_login":false}}"#.data(using: .utf8)!
        let result = try ServerDiscoveryPolicy.parse(document: data, inputURL: URL(string: "https://media.example.com")!)
        XCTAssertEqual(result.configuration.backendURL, "https://media.example.com")
        XCTAssertTrue(result.configuration.capabilities.emailPasswordAuth)
        XCTAssertFalse(result.configuration.capabilities.tvLogin)
    }

    func testRejectsOfficialAndUnsupportedDocuments() throws {
        XCTAssertThrowsError(try ServerDiscoveryPolicy.normalizeInput("https://api.nuvio.tv"))
        let data = #"{"version":2,"service":"nuvio","self_hosted":true,"backend_url":"https://media.example.com","publishable_key":"key","capabilities":{"tv_login":true}}"#.data(using: .utf8)!
        XCTAssertThrowsError(try ServerDiscoveryPolicy.parse(document: data, inputURL: URL(string: "https://media.example.com")!))
    }

    func testRejectsCredentialsQueriesDowngradesAndSecretKeys() throws {
        XCTAssertThrowsError(try ServerDiscoveryPolicy.normalizeInput("https://user:pass@example.com"))
        XCTAssertThrowsError(try ServerDiscoveryPolicy.normalizeInput("https://example.com?redirect=elsewhere"))

        let downgrade = #"{"version":1,"service":"nuvio","self_hosted":true,"backend_url":"http://media.example.com","publishable_key":"sb_publishable_test","capabilities":{"tv_login":true}}"#.data(using: .utf8)!
        XCTAssertThrowsError(
            try ServerDiscoveryPolicy.parse(
                document: downgrade,
                inputURL: URL(string: "https://media.example.com")!
            )
        )

        let secret = #"{"version":1,"service":"nuvio","self_hosted":true,"backend_url":"https://media.example.com","publishable_key":"service_role_test","capabilities":{"tv_login":true}}"#.data(using: .utf8)!
        XCTAssertThrowsError(
            try ServerDiscoveryPolicy.parse(
                document: secret,
                inputURL: URL(string: "https://media.example.com")!
            )
        )
    }

    func testAllowsSameHostHTTPSUpgradeOnDefaultPortOnly() throws {
        let source = URL(string: "http://media.example.com")!
        XCTAssertTrue(
            ServerDiscoveryPolicy.redirectKeepsPort(
                from: source,
                to: URL(string: "https://media.example.com")!
            )
        )
        XCTAssertTrue(
            ServerDiscoveryPolicy.redirectKeepsPort(
                from: source,
                to: URL(string: "https://media.example.com:443")!
            )
        )
        XCTAssertFalse(
            ServerDiscoveryPolicy.redirectKeepsPort(
                from: source,
                to: URL(string: "https://media.example.com:8443")!
            )
        )
    }

    func testCapabilityMatrixExposesOnlySupportedAuthMethods() {
        let emailOnly = ServerCapabilities(emailPasswordAuth: true, tvLogin: false)
        let qrOnly = ServerCapabilities(emailPasswordAuth: false, tvLogin: true)

        XCTAssertTrue(emailOnly.supportsAnyAuth)
        XCTAssertFalse(emailOnly.tvLogin)
        XCTAssertTrue(qrOnly.supportsAnyAuth)
        XCTAssertFalse(qrOnly.emailPasswordAuth)
    }
}
