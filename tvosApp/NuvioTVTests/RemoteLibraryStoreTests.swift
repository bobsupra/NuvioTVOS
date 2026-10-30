import XCTest
@testable import NuvioTV

final class RemoteLibraryStoreTests: XCTestCase {
    private var testProfileA = ""
    private var testProfileB = ""
    private var previousSettingsProfileID: String?
    private var previousSettingsProfileIsPrimary = false
    private var previousLibraryProfileID: String?

    override func setUp() {
        super.setUp()
        previousSettingsProfileID = ProfileSettings.activeProfileID
        previousSettingsProfileIsPrimary = ProfileSettings.isPrimaryProfileStore(ProfileSettings.current)
        previousLibraryProfileID = LibraryStore.activeProfileId

        testProfileA = "remote-store-a-\(UUID().uuidString)"
        testProfileB = "remote-store-b-\(UUID().uuidString)"

        RemoteLibraryStore.clearAll(for: testProfileA)
        RemoteLibraryStore.clearAll(for: testProfileB)
    }

    override func tearDown() {
        RemoteLibraryStore.clearAll(for: testProfileA)
        RemoteLibraryStore.clearAll(for: testProfileB)

        LibraryStore.setActiveProfile(previousLibraryProfileID)
        if let previousSettingsProfileID {
            ProfileSettings.setActiveProfile(previousSettingsProfileID, isPrimary: previousSettingsProfileIsPrimary)
        } else {
            ProfileSettings.clearActiveProfile()
        }

        UserDefaults.standard.removePersistentDomain(forName: "nuvio.tv.profile.settings.\(testProfileA)")
        UserDefaults.standard.removePersistentDomain(forName: "nuvio.tv.profile.settings.\(testProfileB)")
        super.tearDown()
    }

    private func makeItem(id: String, name: String, type: String) -> LibraryStoreItem {
        LibraryStoreItem(meta: NuvioMeta(id: id, name: name, type: type), addedAt: Date())
    }

    func testSaveAndLoadRoundTrip() {
        let items = [
            makeItem(id: "tt0001", name: "Movie 1", type: "movie"),
            makeItem(id: "tt0002", name: "Show 1", type: "series")
        ]

        RemoteLibraryStore.save(items: items, source: .trakt, profileId: testProfileA, accountBindingId: "acc-1")
        let loaded = RemoteLibraryStore.load(source: .trakt, profileId: testProfileA, accountBindingId: "acc-1")

        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.count, 2)
        XCTAssertEqual(loaded?.map { $0.meta.id }, ["tt0001", "tt0002"])
        XCTAssertEqual(loaded?.map { $0.meta.name }, ["Movie 1", "Show 1"])
    }

    func testStoreIsolationAcrossProfilesAndAccounts() {
        let itemA = [makeItem(id: "ttA", name: "Item A", type: "movie")]
        let itemB = [makeItem(id: "ttB", name: "Item B", type: "movie")]
        let itemC = [makeItem(id: "ttC", name: "Item C", type: "movie")]
        let itemD = [makeItem(id: "ttD", name: "Item D", type: "movie")]

        // Profile A, Account 1
        RemoteLibraryStore.save(items: itemA, source: .trakt, profileId: testProfileA, accountBindingId: "acc-1")
        // Profile B, Account 1
        RemoteLibraryStore.save(items: itemB, source: .trakt, profileId: testProfileB, accountBindingId: "acc-1")
        // Profile A, Account 2
        RemoteLibraryStore.save(items: itemC, source: .trakt, profileId: testProfileA, accountBindingId: "acc-2")
        // Profile A, Account 1 under Simkl
        RemoteLibraryStore.save(items: itemD, source: .simkl, profileId: testProfileA, accountBindingId: "acc-1")

        XCTAssertEqual(RemoteLibraryStore.load(source: .trakt, profileId: testProfileA, accountBindingId: "acc-1")?.map { $0.meta.id }, ["ttA"])
        XCTAssertEqual(RemoteLibraryStore.load(source: .trakt, profileId: testProfileB, accountBindingId: "acc-1")?.map { $0.meta.id }, ["ttB"])
        XCTAssertEqual(RemoteLibraryStore.load(source: .trakt, profileId: testProfileA, accountBindingId: "acc-2")?.map { $0.meta.id }, ["ttC"])
        XCTAssertEqual(RemoteLibraryStore.load(source: .simkl, profileId: testProfileA, accountBindingId: "acc-1")?.map { $0.meta.id }, ["ttD"])
    }

    func testApplyMutationAddsAndRemoves() {
        let item1 = makeItem(id: "tt1", name: "One", type: "movie")
        let item2 = makeItem(id: "tt2", name: "Two", type: "series")
        RemoteLibraryStore.save(items: [item1, item2], source: .trakt, profileId: testProfileA, accountBindingId: "acc-1")

        // Add item3
        let meta3 = NuvioMeta(id: "tt3", name: "Three", type: "movie")
        RemoteLibraryStore.applyMutation(
            meta: meta3,
            isInWatchlist: true,
            source: .trakt,
            profileId: testProfileA,
            accountBindingId: "acc-1"
        )

        var loaded = RemoteLibraryStore.load(source: .trakt, profileId: testProfileA, accountBindingId: "acc-1")
        XCTAssertEqual(loaded?.map { $0.meta.id }, ["tt3", "tt1", "tt2"])

        // Remove item1
        RemoteLibraryStore.applyMutation(
            meta: item1.meta,
            isInWatchlist: false,
            source: .trakt,
            profileId: testProfileA,
            accountBindingId: "acc-1"
        )

        loaded = RemoteLibraryStore.load(source: .trakt, profileId: testProfileA, accountBindingId: "acc-1")
        XCTAssertEqual(loaded?.map { $0.meta.id }, ["tt3", "tt2"])
    }

    func testClearSpecificAccountBinding() {
        let item1 = [makeItem(id: "tt1", name: "One", type: "movie")]
        let item2 = [makeItem(id: "tt2", name: "Two", type: "movie")]

        RemoteLibraryStore.save(items: item1, source: .trakt, profileId: testProfileA, accountBindingId: "acc-1")
        RemoteLibraryStore.save(items: item2, source: .trakt, profileId: testProfileA, accountBindingId: "acc-2")

        RemoteLibraryStore.clear(source: .trakt, profileId: testProfileA, accountBindingId: "acc-1")

        let loadedAcc1 = RemoteLibraryStore.load(source: .trakt, profileId: testProfileA, accountBindingId: "acc-1")
        XCTAssertTrue(loadedAcc1 == nil || loadedAcc1!.isEmpty)
        XCTAssertEqual(RemoteLibraryStore.load(source: .trakt, profileId: testProfileA, accountBindingId: "acc-2")?.map { $0.meta.id }, ["tt2"])
    }

    func testClearSourceForProfile() {
        let itemTrakt1 = [makeItem(id: "tt1", name: "One", type: "movie")]
        let itemTrakt2 = [makeItem(id: "tt2", name: "Two", type: "movie")]
        let itemSimkl = [makeItem(id: "tt3", name: "Three", type: "movie")]

        RemoteLibraryStore.save(items: itemTrakt1, source: .trakt, profileId: testProfileA, accountBindingId: "acc-1")
        RemoteLibraryStore.save(items: itemTrakt2, source: .trakt, profileId: testProfileA, accountBindingId: "acc-2")
        RemoteLibraryStore.save(items: itemSimkl, source: .simkl, profileId: testProfileA, accountBindingId: "acc-1")

        RemoteLibraryStore.clear(source: .trakt, profileId: testProfileA)

        let loadedTrakt1 = RemoteLibraryStore.load(source: .trakt, profileId: testProfileA, accountBindingId: "acc-1")
        let loadedTrakt2 = RemoteLibraryStore.load(source: .trakt, profileId: testProfileA, accountBindingId: "acc-2")
        XCTAssertTrue(loadedTrakt1 == nil || loadedTrakt1!.isEmpty)
        XCTAssertTrue(loadedTrakt2 == nil || loadedTrakt2!.isEmpty)
        XCTAssertEqual(RemoteLibraryStore.load(source: .simkl, profileId: testProfileA, accountBindingId: "acc-1")?.map { $0.meta.id }, ["tt3"])
    }

    func testClearAllForProfile() {
        let itemTrakt = [makeItem(id: "tt1", name: "One", type: "movie")]
        let itemSimkl = [makeItem(id: "tt2", name: "Two", type: "movie")]
        let itemProfileB = [makeItem(id: "tt3", name: "Three", type: "movie")]

        RemoteLibraryStore.save(items: itemTrakt, source: .trakt, profileId: testProfileA, accountBindingId: "acc-1")
        RemoteLibraryStore.save(items: itemSimkl, source: .simkl, profileId: testProfileA, accountBindingId: "acc-1")
        RemoteLibraryStore.save(items: itemProfileB, source: .trakt, profileId: testProfileB, accountBindingId: "acc-1")

        RemoteLibraryStore.clearAll(for: testProfileA)

        let loadedTrakt = RemoteLibraryStore.load(source: .trakt, profileId: testProfileA, accountBindingId: "acc-1")
        let loadedSimkl = RemoteLibraryStore.load(source: .simkl, profileId: testProfileA, accountBindingId: "acc-1")
        XCTAssertTrue(loadedTrakt == nil || loadedTrakt!.isEmpty)
        XCTAssertTrue(loadedSimkl == nil || loadedSimkl!.isEmpty)
        XCTAssertEqual(RemoteLibraryStore.load(source: .trakt, profileId: testProfileB, accountBindingId: "acc-1")?.map { $0.meta.id }, ["tt3"])
    }

    @MainActor
    func testLibraryViewModelLoadsInstantlyFromRemoteStore() throws {
        ProfileSettings.setActiveProfile(testProfileA, isPrimary: false)
        LibraryStore.setActiveProfile(testProfileA)
        ProfileSettings.current.set(TraktLibrarySourceMode.trakt.rawValue,
                                    forKey: SettingsKey.traktLibrarySourceMode)
        ProfileSettings.current.set("client-1", forKey: SettingsKey.traktClientID)
        TraktAuthStore.saveToken(
            TraktTokenResponse(
                accessToken: "token-1",
                tokenType: "Bearer",
                expiresIn: 3600,
                refreshToken: "refresh-1",
                createdAt: Int(Date().timeIntervalSince1970)
            ),
            clientID: "client-1",
            store: ProfileSettings.current
        )

        let accountBinding = try XCTUnwrap(RemoteLibraryStore.accountBindingID(for: .trakt, profileId: testProfileA, in: ProfileSettings.current))
        XCTAssertFalse(accountBinding.isEmpty)

        let initialCached = [
            makeItem(id: "tt100", name: "Cached Movie", type: "movie"),
            makeItem(id: "tt200", name: "Cached Show", type: "series")
        ]
        RemoteLibraryStore.save(items: initialCached, source: .trakt, profileId: testProfileA, accountBindingId: accountBinding)

        let viewModel = LibraryViewModel()
        viewModel.loadLibrary()

        XCTAssertEqual(viewModel.items.map { $0.id }, ["tt100", "tt200"])
        XCTAssertFalse(viewModel.isLoading)
    }

    @MainActor
    func testLibraryViewModelMutationUpdatesRemoteStore() throws {
        ProfileSettings.setActiveProfile(testProfileA, isPrimary: false)
        LibraryStore.setActiveProfile(testProfileA)
        ProfileSettings.current.set(TraktLibrarySourceMode.trakt.rawValue,
                                    forKey: SettingsKey.traktLibrarySourceMode)
        ProfileSettings.current.set("client-1", forKey: SettingsKey.traktClientID)
        TraktAuthStore.saveToken(
            TraktTokenResponse(
                accessToken: "token-1",
                tokenType: "Bearer",
                expiresIn: 3600,
                refreshToken: "refresh-1",
                createdAt: Int(Date().timeIntervalSince1970)
            ),
            clientID: "client-1",
            store: ProfileSettings.current
        )

        let accountBinding = try XCTUnwrap(RemoteLibraryStore.accountBindingID(for: .trakt, profileId: testProfileA, in: ProfileSettings.current))
        let context = try XCTUnwrap(TraktLibraryMutationContext())

        let item = NuvioMeta(id: "tt999", name: "Mutation Movie", type: "movie")
        let viewModel = LibraryViewModel()
        viewModel.loadLibrary()

        // Apply mutation
        viewModel.applyTraktMutation(TraktLibraryMutation(meta: item, isInWatchlist: true, context: context))

        // Check viewModel.items
        XCTAssertEqual(viewModel.items.map { $0.id }, ["tt999"])

        // Check RemoteLibraryStore on disk
        let diskItems = RemoteLibraryStore.load(source: .trakt, profileId: testProfileA, accountBindingId: accountBinding)
        XCTAssertEqual(diskItems?.map { $0.meta.id }, ["tt999"])

        // Remove via mutation
        viewModel.applyTraktMutation(TraktLibraryMutation(meta: item, isInWatchlist: false, context: context))
        XCTAssertTrue(viewModel.items.isEmpty)
        let diskItemsAfterRemove = RemoteLibraryStore.load(source: .trakt, profileId: testProfileA, accountBindingId: accountBinding)
        XCTAssertTrue(diskItemsAfterRemove == nil || diskItemsAfterRemove!.isEmpty)
    }
}
