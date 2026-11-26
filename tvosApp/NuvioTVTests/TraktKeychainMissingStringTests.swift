import XCTest
@testable import NuvioTV

final class InMemoryProviderCredentialKeychain: ProviderCredentialKeychain {
    var values: [String: String] = [:]
    var readResponses: [ProviderCredentialKeychainRead] = []
    var reads = 0
    var writeSucceeds = true
    var deleteSucceeds = true

    private func key(_ service: String, _ account: String) -> String {
        "\(service)|\(account)"
    }

    func read(service: String, account: String) -> ProviderCredentialKeychainRead {
        reads += 1
        if !readResponses.isEmpty { return readResponses.removeFirst() }
        guard let value = values[key(service, account)] else { return .missing }
        return .value(value)
    }

    func write(_ value: String, service: String, account: String) -> Bool {
        guard writeSucceeds else { return false }
        values[key(service, account)] = value
        return true
    }

    func delete(service: String, account: String) -> Bool {
        guard deleteSucceeds else { return false }
        values.removeValue(forKey: key(service, account))
        return true
    }
}

/// The Trakt Keychain storage remembers confirmed misses and retries transient failures.
final class TraktKeychainMissingStringTests: XCTestCase {
    private var scope = ""

    override func setUp() {
        super.setUp()
        scope = "test-keychain-\(UUID().uuidString)"
    }

    private func storedSession(_ accessToken: String) -> TraktStoredSession {
        TraktStoredSession(
            accessToken: accessToken,
            refreshToken: nil,
            tokenType: nil,
            createdAt: nil,
            expiresIn: nil,
            username: nil,
            displayName: nil,
            userSlug: nil,
            credentialClientID: nil,
            accountBindingID: nil
        )
    }

    private func storedTokens(_ accessToken: String) -> MdbListStoredTokens {
        MdbListStoredTokens(accessToken: accessToken, refreshToken: "refresh", expiresAtMillis: 42)
    }

    func testMissingValueIsNotLookedForAgain() {
        let keychain = InMemoryProviderCredentialKeychain()
        let storage = TraktKeychainStorage(keychain: keychain)

        XCTAssertNil(storage.clientID(for: scope))
        XCTAssertNil(storage.clientID(for: scope))
        XCTAssertNil(storage.clientID(for: scope))

        XCTAssertEqual(keychain.reads, 1)
    }

    func testMissingTraktSessionIsNotLookedForAgainAndSuccessfulSaveClearsMiss() {
        let keychain = InMemoryProviderCredentialKeychain()
        let storage = TraktKeychainStorage(keychain: keychain)

        XCTAssertNil(storage.session(for: scope))
        XCTAssertNil(storage.session(for: scope))
        XCTAssertEqual(keychain.reads, 1)

        let session = storedSession("access")
        XCTAssertTrue(storage.saveSession(session, for: scope))
        XCTAssertEqual(storage.session(for: scope), session)
        XCTAssertEqual(keychain.reads, 1)
    }

    func testFailedReadIsRetriedAndCanRecover() {
        let keychain = InMemoryProviderCredentialKeychain()
        keychain.readResponses = [.failed, .value("client-id")]
        let storage = TraktKeychainStorage(keychain: keychain)

        XCTAssertNil(storage.clientID(for: scope))
        XCTAssertEqual(storage.clientID(for: scope), "client-id")

        XCTAssertEqual(keychain.reads, 2)
    }

    func testInvalidTraktSessionPayloadIsRetriedAndCanRecover() throws {
        let keychain = InMemoryProviderCredentialKeychain()
        let validData = try JSONEncoder().encode(storedSession("recovered"))
        let validJSON = try XCTUnwrap(String(data: validData, encoding: .utf8))
        keychain.readResponses = [.value("invalid-json"), .value(validJSON)]
        let storage = TraktKeychainStorage(keychain: keychain)

        XCTAssertNil(storage.session(for: scope))
        XCTAssertEqual(storage.session(for: scope), storedSession("recovered"))
        XCTAssertEqual(keychain.reads, 2)
    }

    func testWrittenValueReplacesRememberedMiss() {
        let keychain = InMemoryProviderCredentialKeychain()
        let storage = TraktKeychainStorage(keychain: keychain)
        XCTAssertNil(storage.clientID(for: scope))

        XCTAssertTrue(storage.setClientID("client-id", for: scope))
        XCTAssertEqual(storage.clientID(for: scope), "client-id")

        XCTAssertTrue(storage.setClientID(nil, for: scope))
        XCTAssertNil(storage.clientID(for: scope))
        XCTAssertEqual(keychain.reads, 1)
    }

    func testFailedTraktCredentialReplacementPreservesCachedAndDurableValue() {
        let keychain = InMemoryProviderCredentialKeychain()
        let storage = TraktKeychainStorage(keychain: keychain)
        XCTAssertTrue(storage.setClientID("old-client-id", for: scope))

        keychain.writeSucceeds = false
        XCTAssertFalse(storage.setClientID("new-client-id", for: scope))

        XCTAssertEqual(storage.clientID(for: scope), "old-client-id")
        XCTAssertEqual(keychain.values["com.nuvio.tv.trakt.auth|clientID.\(scope)"], "old-client-id")
    }

    func testFailedTraktSessionReplacementPreservesCachedAndDurableValue() throws {
        let keychain = InMemoryProviderCredentialKeychain()
        let storage = TraktKeychainStorage(keychain: keychain)
        let oldSession = storedSession("old-token")
        XCTAssertTrue(storage.saveSession(oldSession, for: scope))

        keychain.writeSucceeds = false
        XCTAssertFalse(storage.saveSession(storedSession("new-token"), for: scope))

        XCTAssertEqual(storage.session(for: scope), oldSession)
        let durableJSON = try XCTUnwrap(keychain.values["com.nuvio.tv.trakt.auth|tokens.\(scope)"])
        let durableData = try XCTUnwrap(durableJSON.data(using: .utf8))
        XCTAssertEqual(try JSONDecoder().decode(TraktStoredSession.self, from: durableData), oldSession)
    }

    func testMdbListMissingValueIsNotLookedForAgainAndSuccessfulWriteClearsMiss() {
        let keychain = InMemoryProviderCredentialKeychain()
        let storage = MdbListKeychainTokenStorage(keychain: keychain)

        XCTAssertNil(storage.tokens(for: scope))
        XCTAssertNil(storage.tokens(for: scope))
        XCTAssertEqual(keychain.reads, 1)

        let tokens = storedTokens("access")
        XCTAssertTrue(storage.save(tokens, for: scope))
        XCTAssertEqual(storage.tokens(for: scope), tokens)
        XCTAssertEqual(keychain.reads, 1)
    }

    func testMdbListFailedReadIsRetriedAndCanRecover() throws {
        let keychain = InMemoryProviderCredentialKeychain()
        let validData = try JSONEncoder().encode(storedTokens("recovered"))
        let validJSON = try XCTUnwrap(String(data: validData, encoding: .utf8))
        keychain.readResponses = [.failed, .value(validJSON)]
        let storage = MdbListKeychainTokenStorage(keychain: keychain)

        XCTAssertNil(storage.tokens(for: scope))
        XCTAssertEqual(storage.tokens(for: scope), storedTokens("recovered"))
        XCTAssertEqual(keychain.reads, 2)
    }

    func testInvalidMdbListTokenPayloadIsRetriedAndCanRecover() throws {
        let keychain = InMemoryProviderCredentialKeychain()
        let validData = try JSONEncoder().encode(storedTokens("recovered"))
        let validJSON = try XCTUnwrap(String(data: validData, encoding: .utf8))
        keychain.readResponses = [.value("invalid-json"), .value(validJSON)]
        let storage = MdbListKeychainTokenStorage(keychain: keychain)

        XCTAssertNil(storage.tokens(for: scope))
        XCTAssertEqual(storage.tokens(for: scope), storedTokens("recovered"))
        XCTAssertEqual(keychain.reads, 2)
    }

    func testFailedMdbListReplacementPreservesCachedAndDurableTokens() throws {
        let keychain = InMemoryProviderCredentialKeychain()
        let storage = MdbListKeychainTokenStorage(keychain: keychain)
        let oldTokens = storedTokens("old-access")
        XCTAssertTrue(storage.save(oldTokens, for: scope))

        keychain.writeSucceeds = false
        XCTAssertFalse(storage.save(storedTokens("new-access"), for: scope))

        XCTAssertEqual(storage.tokens(for: scope), oldTokens)
        let durableJSON = try XCTUnwrap(keychain.values["com.nuvio.tv.mdblist.auth|tokens.\(scope)"])
        let durableData = try XCTUnwrap(durableJSON.data(using: .utf8))
        XCTAssertEqual(try JSONDecoder().decode(MdbListStoredTokens.self, from: durableData), oldTokens)
    }
}
