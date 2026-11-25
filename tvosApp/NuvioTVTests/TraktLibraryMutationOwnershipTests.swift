import XCTest
@testable import NuvioTV

private final class TraktLibraryNotificationProbe {
    var mutations = 0
    var refreshes = 0
}

final class TraktLibraryMutationOwnershipTests: XCTestCase {
    private var profileA = ""
    private var profileB = ""
    private var previousSettingsProfileID: String?
    private var previousSettingsProfileIsPrimary = false
    private var previousLibraryProfileID: String?
    private var observers: [NSObjectProtocol] = []

    override func setUp() {
        super.setUp()
        previousSettingsProfileID = ProfileSettings.activeProfileID
        previousSettingsProfileIsPrimary = ProfileSettings.isPrimaryProfileStore(ProfileSettings.current)
        previousLibraryProfileID = LibraryStore.activeProfileId
        profileA = "trakt-library-a-\(UUID().uuidString)"
        profileB = "trakt-library-b-\(UUID().uuidString)"
        activate(profileA)
        seedToken()
    }

    override func tearDown() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        LibraryStore.setActiveProfile(previousLibraryProfileID)
        if let previousSettingsProfileID {
            ProfileSettings.setActiveProfile(previousSettingsProfileID, isPrimary: previousSettingsProfileIsPrimary)
        } else {
            ProfileSettings.clearActiveProfile()
        }
        for profileID in [profileA, profileB] {
            MdbListKeychainTokenStorage().remove(for: profileID)
            UserDefaults.standard.removePersistentDomain(forName: "nuvio.tv.profile.settings.\(profileID)")
        }
        MdbListKeychainTokenStorage().remove(for: ProfileSettings.activeProfileScope)
        super.tearDown()
    }

    @MainActor
    func testCurrentMutationPublishesBothNotifications() throws {
        let mutation = try makeMutation()
        let probe = observeNotifications()
        TraktLibraryService.publishMutation(mutation)
        XCTAssertEqual(probe.mutations, 1)
        XCTAssertEqual(probe.refreshes, 1)
    }

    @MainActor
    func testProviderSwitchSuppressesPublicationAndQueuedConsumerMutation() throws {
        let mutation = try makeMutation()
        let viewModel = LibraryViewModel()
        viewModel.items = [LibraryStoreItem(meta: meta, addedAt: Date()).stremioMeta]
        let probe = observeNotifications()
        // MDBList is authenticated so the old generic usesRemoteLibrary guard
        // would have allowed the Trakt removal into this provider's items.
        let storage = MdbListKeychainTokenStorage(keychain: InMemoryProviderCredentialKeychain())
        XCTAssertTrue(storage.save(
            MdbListStoredTokens(
                accessToken: "test-token",
                refreshToken: "test-refresh",
                expiresAtMillis: Date().timeIntervalSince1970 * 1_000 + 3_600_000
            ),
            for: ProfileSettings.activeProfileScope
        ))
        ProfileSettings.current.set("test-key", forKey: SettingsKey.mdbListApiKey)
        ProfileSettings.current.set(TraktLibrarySourceMode.mdblist.rawValue,
                                    forKey: SettingsKey.traktLibrarySourceMode)
        XCTAssertTrue(SelectedLibraryService.isSelectedAndAuthenticated)

        TraktLibraryService.publishMutation(mutation)
        viewModel.applyTraktMutation(mutation)

        XCTAssertEqual(probe.mutations, 0)
        XCTAssertEqual(probe.refreshes, 0)
        XCTAssertEqual(viewModel.items.map { $0.id }, [meta.id])
    }

    @MainActor
    func testProfileSwitchSuppressesPublicationAndQueuedConsumerMutation() throws {
        let mutation = try makeMutation()
        activate(profileB)
        seedToken()
        let viewModel = LibraryViewModel()
        viewModel.items = [LibraryStoreItem(meta: meta, addedAt: Date()).stremioMeta]
        let probe = observeNotifications()

        TraktLibraryService.publishMutation(mutation)
        viewModel.applyTraktMutation(mutation)

        XCTAssertEqual(probe.mutations, 0)
        XCTAssertEqual(probe.refreshes, 0)
        XCTAssertEqual(viewModel.items.map { $0.id }, [meta.id])
    }

    @MainActor
    func testRelinkWithIdenticalTokensStillRejectsOldAccountMutation() throws {
        let mutation = try makeMutation()
        seedToken(isNewLogin: true)
        let viewModel = LibraryViewModel()
        viewModel.items = [LibraryStoreItem(meta: meta, addedAt: Date()).stremioMeta]
        let probe = observeNotifications()

        TraktLibraryService.publishMutation(mutation)
        viewModel.applyTraktMutation(mutation)

        XCTAssertEqual(probe.mutations, 0)
        XCTAssertEqual(probe.refreshes, 0)
        XCTAssertEqual(viewModel.items.map { $0.id }, [meta.id])
    }

    @MainActor
    func testTokenRotationKeepsMutationValidForSameAccount() throws {
        let mutation = try makeMutation()
        seedToken(accessToken: "rotated-access", refreshToken: "rotated-refresh")
        let viewModel = LibraryViewModel()
        viewModel.items = [LibraryStoreItem(meta: meta, addedAt: Date()).stremioMeta]
        viewModel.applyTraktMutation(mutation)
        XCTAssertTrue(viewModel.items.isEmpty)
    }

    @MainActor
    func testCurrentMutationStillAddsAndRemovesItems() throws {
        let context = try XCTUnwrap(TraktLibraryMutationContext())
        let viewModel = LibraryViewModel()
        viewModel.applyTraktMutation(TraktLibraryMutation(meta: meta, isInWatchlist: true, context: context))
        XCTAssertEqual(viewModel.items.map { $0.id }, [meta.id])
        viewModel.applyTraktMutation(TraktLibraryMutation(meta: meta, isInWatchlist: false, context: context))
        XCTAssertTrue(viewModel.items.isEmpty)
    }

    @MainActor
    func testLegacySharedPayloadCannotMutateTraktLibrary() {
        let viewModel = LibraryViewModel()
        viewModel.items = [LibraryStoreItem(meta: meta, addedAt: Date()).stremioMeta]
        viewModel.applyTraktMutation(TraktLibraryMutation(meta: meta, isInWatchlist: false))
        XCTAssertEqual(viewModel.items.map { $0.id }, [meta.id])
    }

    func testLibraryMutationMatchesProviderIDThroughCachedIMDbAlias() {
        let cachedAlias = NuvioMeta(
            id: "tmdb:42",
            name: "Alias title",
            imdbId: "tt0042",
            tmdbId: 42,
            type: "movie"
        )
        let canonicalMutation = NuvioMeta(
            id: "tt0042",
            name: "Canonical title",
            imdbId: "tt0042",
            type: "movie"
        )

        XCTAssertTrue(LibraryMutationIdentity.matches(
            itemID: "tmdb:42",
            itemType: "movie",
            cachedMetadata: cachedAlias,
            mutation: canonicalMutation
        ))
        XCTAssertFalse(LibraryMutationIdentity.matches(
            itemID: "tmdb:42",
            itemType: "series",
            cachedMetadata: cachedAlias,
            mutation: canonicalMutation
        ))
    }

    private var meta: NuvioMeta { NuvioMeta(id: "tt-library-\(profileA)", name: "Test", type: "movie") }

    private func activate(_ profileID: String) {
        ProfileSettings.setActiveProfile(profileID, isPrimary: false)
        LibraryStore.setActiveProfile(profileID)
        ProfileSettings.current.set(TraktLibrarySourceMode.trakt.rawValue,
                                    forKey: SettingsKey.traktLibrarySourceMode)
        ProfileSettings.current.set("test-client", forKey: SettingsKey.traktClientID)
    }

    private func seedToken(accessToken: String = "test-access", refreshToken: String = "test-refresh",
                           isNewLogin: Bool = false) {
        TraktAuthStore.saveToken(TraktTokenResponse(accessToken: accessToken, tokenType: "Bearer",
                                                  expiresIn: 3600, refreshToken: refreshToken,
                                                  createdAt: Int(Date().timeIntervalSince1970)),
                                 clientID: "test-client", store: ProfileSettings.current, isNewLogin: isNewLogin)
    }

    @MainActor
    private func makeMutation() throws -> TraktLibraryMutation {
        TraktLibraryMutation(meta: meta, isInWatchlist: false,
                             context: try XCTUnwrap(TraktLibraryMutationContext()))
    }

    private func observeNotifications() -> TraktLibraryNotificationProbe {
        let probe = TraktLibraryNotificationProbe()
        observers.append(NotificationCenter.default.addObserver(forName: TraktLibraryService.mutationNotification,
                                                                object: nil, queue: nil) { _ in
            probe.mutations += 1
        })
        observers.append(NotificationCenter.default.addObserver(forName: TraktSettingsStore.libraryChangedNotification,
                                                                object: nil, queue: nil) { _ in
            probe.refreshes += 1
        })
        return probe
    }
}

@MainActor
final class LibraryMetadataHydratorTests: XCTestCase {
    func testPublishesSeedsBeforeBoundedEnrichmentAndKeepsOrderedIdentity() async throws {
        let seeds = (0..<6).map { index in
            LibraryStoreItem(
                meta: NuvioMeta(id: "tt-\(index)", name: "Seed \(index)", type: "movie"),
                addedAt: Date(timeIntervalSince1970: TimeInterval(100 - index))
            )
        }
        let gate = LibraryHydrationGate()
        let probe = LibraryHydrationProbe()
        let repository = LibraryHydrationRepository(gate: gate, probe: probe)
        let task = Task {
            await LibraryMetadataHydrator.hydrate(
                seeds: seeds,
                repository: repository,
                onSnapshot: { snapshot in
                    probe.recordSnapshot(snapshot)
                    return true
                },
                isCurrent: { true }
            )
        }

        await gate.waitForRequestCount(4)
        XCTAssertEqual(probe.snapshots.first, seeds)
        XCTAssertFalse(probe.metadataLookupPrecededSnapshot)
        let initialConcurrency = await gate.maximumActiveLookups()
        XCTAssertEqual(initialConcurrency, 4)

        var requestedCount = 4
        for id in ["tt-3", "tt-1", "tt-2", "tt-0", "tt-4", "tt-5"] {
            await gate.waitForRequest(id)
            await gate.resolve(id, with: resolvedMeta(for: id))
            if requestedCount < seeds.count {
                requestedCount += 1
                await gate.waitForRequestCount(requestedCount)
            }
        }

        let taskResult = await task.value
        let result = try XCTUnwrap(taskResult)
        XCTAssertEqual(result.map(\.id), seeds.map(\.id))
        XCTAssertEqual(result.map(\.addedAt), seeds.map(\.addedAt))
        XCTAssertEqual(result.map(\.meta.name), seeds.map { "Hydrated \($0.id)" })
        XCTAssertTrue(result.allSatisfy { $0.meta.genres == ["Drama"] })
        XCTAssertEqual(probe.snapshots.last?.map(\.id), seeds.map(\.id))
        let maximumConcurrency = await gate.maximumActiveLookups()
        XCTAssertEqual(maximumConcurrency, 4)
    }

    func testMetadataFailureKeepsSeedAndObsoleteSnapshotStopsBeforeLookup() async throws {
        let seeds = [
            LibraryStoreItem(meta: NuvioMeta(id: "tt-fail", name: "Keep me", type: "series"), addedAt: Date()),
            LibraryStoreItem(meta: NuvioMeta(id: "tt-success", name: "Seed title", type: "movie"), addedAt: Date())
        ]
        let gate = LibraryHydrationGate()
        let repository = LibraryHydrationRepository(gate: gate, probe: LibraryHydrationProbe())
        let task = Task {
            await LibraryMetadataHydrator.hydrate(
                seeds: seeds,
                repository: repository,
                isCurrent: { true }
            )
        }
        await gate.waitForRequestCount(2)
        await gate.fail("tt-fail")
        await gate.resolve("tt-success", with: resolvedMeta(for: "tt-success"))
        let taskResult = await task.value
        let result = try XCTUnwrap(taskResult)
        XCTAssertEqual(result.map(\.id), ["tt-fail", "tt-success"])
        XCTAssertEqual(result.first?.meta.name, "Keep me")
        XCTAssertEqual(result.last?.meta.name, "Hydrated tt-success")

        let obsoleteGate = LibraryHydrationGate()
        let obsoleteResult = await LibraryMetadataHydrator.hydrate(
            seeds: seeds,
            repository: LibraryHydrationRepository(gate: obsoleteGate, probe: LibraryHydrationProbe()),
            onSnapshot: { _ in false },
            isCurrent: { true }
        )
        XCTAssertNil(obsoleteResult)
        let obsoleteRequestCount = await obsoleteGate.requestCount()
        XCTAssertEqual(obsoleteRequestCount, 0)
    }

    func testCancellationPreventsEnrichedSnapshotPublication() async throws {
        let seeds = (0..<4).map { index in
            LibraryStoreItem(
                meta: NuvioMeta(id: "tt-cancel-\(index)", name: "Seed \(index)", type: "movie"),
                addedAt: Date()
            )
        }
        let gate = LibraryHydrationGate()
        let probe = LibraryHydrationProbe()
        let task = Task {
            await LibraryMetadataHydrator.hydrate(
                seeds: seeds,
                repository: LibraryHydrationRepository(gate: gate, probe: probe),
                onSnapshot: { snapshot in
                    probe.recordSnapshot(snapshot)
                    return true
                },
                isCurrent: { !Task.isCancelled }
            )
        }
        await gate.waitForRequestCount(4)
        task.cancel()
        for seed in seeds {
            await gate.resolve(seed.id, with: resolvedMeta(for: seed.id))
        }

        let taskResult = await task.value
        XCTAssertNil(taskResult)
        XCTAssertEqual(probe.snapshots, [seeds])
    }

    private func resolvedMeta(for id: String) -> NuvioMeta {
        NuvioMeta(
            id: "canonical-\(id)",
            name: "Hydrated \(id)",
            posterUrl: "https://example.test/\(id).jpg",
            type: "movie",
            genres: ["Drama"]
        )
    }
}

private final class LibraryHydrationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedSnapshots: [[LibraryStoreItem]] = []
    private var lookupStartedBeforeSnapshot = false

    var snapshots: [[LibraryStoreItem]] {
        lock.lock()
        defer { lock.unlock() }
        return recordedSnapshots
    }

    var metadataLookupPrecededSnapshot: Bool {
        lock.lock()
        defer { lock.unlock() }
        return lookupStartedBeforeSnapshot
    }

    func recordSnapshot(_ snapshot: [LibraryStoreItem]) {
        lock.lock()
        recordedSnapshots.append(snapshot)
        lock.unlock()
    }

    func recordMetadataLookup() {
        lock.lock()
        if recordedSnapshots.isEmpty { lookupStartedBeforeSnapshot = true }
        lock.unlock()
    }
}

private actor LibraryHydrationGate {
    private var continuations: [String: CheckedContinuation<NuvioMeta, Error>] = [:]
    private var requestedIDs: [String] = []
    private var requestWaiters: [(count: Int?, id: String?, continuation: CheckedContinuation<Void, Never>)] = []
    private var activeLookups = 0
    private var maxActiveLookups = 0

    func lookup(id: String) async throws -> NuvioMeta {
        activeLookups += 1
        maxActiveLookups = max(maxActiveLookups, activeLookups)
        requestedIDs.append(id)
        resumeReadyRequestWaiters()
        defer { activeLookups -= 1 }
        return try await withCheckedThrowingContinuation { continuation in
            continuations[id] = continuation
        }
    }

    func waitForRequestCount(_ count: Int) async {
        guard requestedIDs.count < count else { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append((count, nil, continuation))
        }
    }

    func waitForRequest(_ id: String) async {
        guard !requestedIDs.contains(id) else { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append((nil, id, continuation))
        }
    }

    func resolve(_ id: String, with meta: NuvioMeta) {
        continuations.removeValue(forKey: id)?.resume(returning: meta)
    }

    func fail(_ id: String) {
        continuations.removeValue(forKey: id)?.resume(throwing: URLError(.badServerResponse))
    }

    func requestCount() -> Int { requestedIDs.count }
    func maximumActiveLookups() -> Int { maxActiveLookups }

    private func resumeReadyRequestWaiters() {
        let ready = requestWaiters.filter { waiter in
            if let count = waiter.count { return requestedIDs.count >= count }
            if let id = waiter.id { return requestedIDs.contains(id) }
            return false
        }
        requestWaiters.removeAll { waiter in
            if let count = waiter.count { return requestedIDs.count >= count }
            if let id = waiter.id { return requestedIDs.contains(id) }
            return false
        }
        ready.forEach { $0.continuation.resume() }
    }
}

private final class LibraryHydrationRepository: MockCatalogRepository {
    let gate: LibraryHydrationGate
    let probe: LibraryHydrationProbe

    init(gate: LibraryHydrationGate, probe: LibraryHydrationProbe) {
        self.gate = gate
        self.probe = probe
    }

    override func getMetadata(id: String, type: String) async throws -> NuvioMeta {
        probe.recordMetadataLookup()
        return try await gate.lookup(id: id)
    }
}
