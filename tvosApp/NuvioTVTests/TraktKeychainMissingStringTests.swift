import Security
import XCTest
@testable import NuvioTV

/// The Trakt Keychain storage remembers a string the Keychain doesn't have, until one is written.
final class TraktKeychainMissingStringTests: XCTestCase {
    private var scope = ""
    private var lookups = 0

    override func setUp() {
        super.setUp()
        scope = "test-missing-\(UUID().uuidString)"
        lookups = 0
    }

    override func tearDown() {
        TraktKeychainStorage.shared.setClientID(nil, for: scope)
        super.tearDown()
    }

    /// A storage whose Keychain answers every lookup with `status`, counting them.
    private func storage(answering status: OSStatus) -> TraktKeychainStorage {
        TraktKeychainStorage(copyMatching: { [unowned self] _, _ in
            self.lookups += 1
            return status
        })
    }

    func testMissingValueIsNotLookedForAgain() {
        let storage = storage(answering: errSecItemNotFound)

        XCTAssertNil(storage.clientID(for: scope))
        XCTAssertNil(storage.clientID(for: scope))
        XCTAssertNil(storage.clientID(for: scope))

        XCTAssertEqual(lookups, 1)
    }

    func testKeychainThatCannotBeReadIsAskedAgain() {
        let storage = storage(answering: errSecInteractionNotAllowed)

        XCTAssertNil(storage.clientID(for: scope))
        XCTAssertNil(storage.clientID(for: scope))

        XCTAssertEqual(lookups, 2)
    }

    func testWrittenValueReplacesRememberedMiss() {
        let storage = storage(answering: errSecItemNotFound)
        XCTAssertNil(storage.clientID(for: scope))

        storage.setClientID("client-id", for: scope)
        XCTAssertEqual(storage.clientID(for: scope), "client-id")

        storage.setClientID(nil, for: scope)
        XCTAssertNil(storage.clientID(for: scope))
        XCTAssertEqual(lookups, 1)
    }
}
