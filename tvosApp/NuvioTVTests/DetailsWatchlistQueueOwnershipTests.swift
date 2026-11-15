import XCTest
@testable import NuvioTV

private final class QueueOwnershipTokens: SimklTokenStorage, WeTrakrTokenStorage, MdbListTokenStorage {
    private var access: [String: String] = [:]
    private var refresh: [String: String] = [:]
    private var oauth: [String: MdbListStoredTokens] = [:]
    func accessToken(for scope: String) -> String? { access[scope] }
    func setAccessToken(_ token: String?, for scope: String) { access[scope] = token }
    func refreshToken(for scope: String) -> String? { refresh[scope] }
    func setRefreshToken(_ token: String?, for scope: String) { refresh[scope] = token }
    func tokens(for scope: String) -> MdbListStoredTokens? { oauth[scope] }
    func save(_ tokens: MdbListStoredTokens, for scope: String) -> Bool {
        oauth[scope] = tokens
        return true
    }
    func remove(for scope: String) { oauth[scope] = nil }
    func removeAll() { access = [:]; refresh = [:]; oauth = [:] }
}

@MainActor
private final class QueueOwnershipGate {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var result: Bool?
    func wait() async -> Bool {
        if let result { return result }
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish(_ result: Bool) {
        self.result = result
        continuation?.resume(returning: result)
        continuation = nil
    }
}

private enum QueueOwnershipMode: CaseIterable {
    case trakt, simklV1, simklV2, weTrakr, mdbOAuth, mdbAPIKey
    var source: TraktLibrarySourceMode {
        switch self {
        case .trakt: return .trakt
        case .simklV1, .simklV2: return .simkl
        case .weTrakr: return .wetrakr
        case .mdbOAuth, .mdbAPIKey: return .mdblist
        }
    }
}

@MainActor
private final class QueueOwnershipFixture {
    let profile = "details-queue-\(UUID().uuidString)"
    let tokens = QueueOwnershipTokens()
    private let previousSettings = ProfileSettings.activeProfileID
    private let previousPrimary = ProfileSettings.isPrimaryProfileStore(ProfileSettings.current)
    private let previousLibrary = LibraryStore.activeProfileId
    var store: UserDefaults { ProfileSettings.current }

    init(_ mode: QueueOwnershipMode) {
        ProfileSettings.setActiveProfile(profile, isPrimary: false)
        LibraryStore.setActiveProfile(profile)
        store.set("queue-client", forKey: SettingsKey.traktClientID)
        store.set("queue-client", forKey: SettingsKey.simklClientID)
        store.set("queue-client", forKey: SettingsKey.wetrakrClientID)
        seed(mode)
    }

    func restore() {
        LibraryStore.setActiveProfile(previousLibrary)
        if let previousSettings {
            ProfileSettings.setActiveProfile(previousSettings, isPrimary: previousPrimary)
        } else {
            ProfileSettings.clearActiveProfile()
        }
        UserDefaults.standard.removePersistentDomain(forName: "nuvio.tv.profile.settings.\(profile)")
        tokens.removeAll()
    }

    func context() -> SelectedLibraryMutationContext? {
        SelectedLibraryMutationContext(simklTokens: tokens, weTrakrTokens: tokens, mdbListTokens: tokens)
    }

    func seed(_ mode: QueueOwnershipMode, refresh: Bool = false, suffix: String = "a") {
        switch mode {
        case .trakt:
            TraktAuthStore.saveToken(
                TraktTokenResponse(accessToken: "access-\(suffix)", tokenType: "Bearer", expiresIn: 3600,
                                   refreshToken: "refresh-\(suffix)", createdAt: Int(Date().timeIntervalSince1970)),
                clientID: "queue-client", store: store, isNewLogin: !refresh
            )
        case .simklV1, .simklV2:
            let prefix = mode == .simklV2 ? "simkl_at_" : "legacy-"
            SimklAuthStore.saveToken(
                "\(prefix)\(suffix)", refreshToken: mode == .simklV2 ? "refresh-\(suffix)" : nil,
                expiresIn: 3600, clientID: "queue-client", profileScope: profile,
                store: store, tokenStorage: tokens, isNewLogin: !refresh
            )
        case .weTrakr:
            WeTrakrAuthStore.saveToken(
                "access-\(suffix)", refreshToken: "refresh-\(suffix)", expiresIn: 3600,
                clientID: "queue-client", profileScope: profile, store: store,
                tokenStorage: tokens, isNewLogin: !refresh
            )
        case .mdbOAuth:
            let value = MdbListStoredTokens(accessToken: "access-\(suffix)", refreshToken: "refresh-\(suffix)",
                                            expiresAtMillis: Date().timeIntervalSince1970 * 1000 + 3_600_000)
            if refresh {
                // Production refresh updates token storage, without issuing a new grant.
                _ = tokens.save(value, for: profile)
            } else {
                _ = MdbListAuthStore.saveTokens(value, user: nil, profileScope: profile,
                                                store: store, tokenStorage: tokens)
            }
        case .mdbAPIKey:
            store.set("api-key-\(suffix)", forKey: SettingsKey.mdbListApiKey)
        }
        store.set(mode.source.rawValue, forKey: SettingsKey.traktLibrarySourceMode)
    }

    func logout(_ mode: QueueOwnershipMode) {
        switch mode {
        case .trakt: TraktAuthStore.clearAuth(store: store)
        case .simklV1, .simklV2:
            SimklAuthStore.clearAuth(profileScope: profile, store: store, tokenStorage: tokens)
        case .weTrakr:
            WeTrakrAuthStore.clearAuth(profileScope: profile, store: store, tokenStorage: tokens)
        case .mdbOAuth:
            MdbListAuthStore.clearAuth(profileScope: profile, store: store, tokenStorage: tokens)
        case .mdbAPIKey:
            store.removeObject(forKey: SettingsKey.mdbListApiKey)
        }
    }
}

private final class QueueOwnershipRepository: CatalogRepository {
    let meta = NuvioMeta(id: "tt-queue-\(UUID().uuidString)", name: "Queue fixture", type: "movie")
    func getHomeCatalogs() async throws -> [NuvioCatalog] { [] }
    func getMetadata(id: String, type: String) async throws -> NuvioMeta { meta }
    func getStreams(id: String, type: String) async throws -> [NuvioStream] { [] }
    func search(query: String) async throws -> [NuvioMeta] { [] }
    func browseCatalog(contentType: String, catalogId: String, page: Int, genre: String?, year: Int?, sort: String?) async throws -> CatalogPage {
        CatalogPage(items: [], hasMore: false, page: page)
    }
    func browseCatalog(contentType: String, catalogId: String, skip: Int, genre: String?) async throws -> CatalogPage {
        CatalogPage(items: [], hasMore: false, page: 0, nextSkip: skip)
    }
    func browseCatalog(addonId: String?, contentType: String, catalogId: String, skip: Int, genre: String?) async throws -> CatalogPage {
        CatalogPage(items: [], hasMore: false, page: 0, nextSkip: skip)
    }
    func getGenres(contentType: String) async throws -> [String] { [] }
    func getCollectionFolderItems(sources: [NuvioCollectionCatalogSource], limit: Int) async -> [NuvioMeta] { [] }
    func cacheCatalogMetadata(_ meta: NuvioMeta) {}
    func cachedMetadata(for id: String) -> NuvioMeta? { nil }
}

@MainActor
final class DetailsWatchlistQueueOwnershipTests: XCTestCase {
    func testDelayedQueueRejectsSameProfileLogoutAndRelinkForEveryAuthMode() async throws {
        for mode in QueueOwnershipMode.allCases {
            let fixture = QueueOwnershipFixture(mode)
            defer { fixture.restore() }
            let gate = QueueOwnershipGate()
            let started = expectation(description: "First write started: \(mode)")
            var sent: [Bool] = []
            let vm = await makeViewModel(fixture) { _, membership in
                sent.append(membership)
                if sent.count == 1 { started.fulfill(); return await gate.wait() }
                return true
            }
            defer { vm.cancelAllTasks() }
            XCTAssertNotNil(fixture.context())
            vm.toggleWatchlist()
            await fulfillment(of: [started], timeout: 2)
            vm.toggleWatchlist()
            fixture.logout(mode)
            fixture.seed(mode, suffix: "b")
            gate.finish(true)
            await vm.watchlistMutationTask?.value
            XCTAssertEqual(sent, [true], "Old intent must not target the replacement account: \(mode)")
        }
    }

    func testStaleFailureCannotRollbackAfterSameProfileRelinkForEveryAuthMode() async {
        for mode in QueueOwnershipMode.allCases {
            let fixture = QueueOwnershipFixture(mode)
            defer { fixture.restore() }
            let gate = QueueOwnershipGate()
            let started = expectation(description: "Write started: \(mode)")
            let vm = await makeViewModel(fixture) { _, _ in
                started.fulfill()
                return await gate.wait()
            }
            defer { vm.cancelAllTasks() }
            vm.toggleWatchlist()
            await fulfillment(of: [started], timeout: 2)
            fixture.logout(mode)
            fixture.seed(mode, suffix: "b")
            gate.finish(false)
            await vm.watchlistMutationTask?.value
            XCTAssertTrue(vm.uiState.isInWatchlist, "Stale account failure must not revert UI: \(mode)")
        }
    }

    func testOrdinaryRefreshPreservesQueuedOrderForEveryOAuthMode() async {
        for mode in [QueueOwnershipMode.trakt, .simklV2, .weTrakr, .mdbOAuth] {
            let fixture = QueueOwnershipFixture(mode)
            defer { fixture.restore() }
            let gate = QueueOwnershipGate()
            let started = expectation(description: "First write started: \(mode)")
            var sent: [Bool] = []
            let vm = await makeViewModel(fixture) { _, membership in
                sent.append(membership)
                if sent.count == 1 { started.fulfill(); return await gate.wait() }
                return true
            }
            defer { vm.cancelAllTasks() }
            vm.toggleWatchlist()
            await fulfillment(of: [started], timeout: 2)
            vm.toggleWatchlist()
            fixture.seed(mode, refresh: true, suffix: "rotated")
            gate.finish(true)
            await vm.watchlistMutationTask?.value
            XCTAssertEqual(sent, [true, false], "Refresh must retain both writes and their order: \(mode)")
            XCTAssertFalse(vm.uiState.isInWatchlist)
        }
    }

    func testFailureAfterRefreshStillRollsBackTheCurrentIntent() async {
        for mode in [QueueOwnershipMode.trakt, .simklV2, .weTrakr, .mdbOAuth] {
            let fixture = QueueOwnershipFixture(mode)
            defer { fixture.restore() }
            let gate = QueueOwnershipGate()
            let started = expectation(description: "Write started before refresh: \(mode)")
            let vm = await makeViewModel(fixture) { _, _ in
                started.fulfill()
                return await gate.wait()
            }
            defer { vm.cancelAllTasks() }
            vm.toggleWatchlist()
            await fulfillment(of: [started], timeout: 2)
            fixture.seed(mode, refresh: true, suffix: "rotated")
            gate.finish(false)
            await vm.watchlistMutationTask?.value
            XCTAssertFalse(vm.uiState.isInWatchlist, "Refresh must not suppress a current failure: \(mode)")
        }
    }

    func testSameTokenNewGrantStillInvalidatesOAuthAndLegacyContexts() {
        for mode in [QueueOwnershipMode.trakt, .simklV1, .simklV2, .weTrakr, .mdbOAuth] {
            let fixture = QueueOwnershipFixture(mode)
            defer { fixture.restore() }
            let context = fixture.context()
            XCTAssertEqual(context?.isCurrent, true)
            fixture.seed(mode) // Identical credentials; deliberately a new grant.
            XCTAssertEqual(context?.isCurrent, false, "Token equality must not authorize a relink: \(mode)")
        }
    }

    func testMDBListCredentialAndAuthModeChangesRejectCapturedOwnership() {
        let fixture = QueueOwnershipFixture(.mdbAPIKey)
        defer { fixture.restore() }
        let api = fixture.context()
        fixture.seed(.mdbOAuth)
        XCTAssertEqual(api?.isCurrent, false)
        let oauth = fixture.context()
        fixture.logout(.mdbOAuth)
        fixture.seed(.mdbAPIKey)
        XCTAssertEqual(oauth?.isCurrent, false)
        let previousKey = fixture.context()
        fixture.seed(.mdbAPIKey, suffix: "b")
        XCTAssertEqual(previousKey?.isCurrent, false)
    }

    func testOldFailurePreservesLatestMutationGenerationGuard() async {
        let fixture = QueueOwnershipFixture(.mdbAPIKey)
        defer { fixture.restore() }
        let gate = QueueOwnershipGate()
        let started = expectation(description: "First write started")
        var sent: [Bool] = []
        let vm = await makeViewModel(fixture) { _, membership in
            sent.append(membership)
            if sent.count == 1 { started.fulfill(); return await gate.wait() }
            return true
        }
        defer { vm.cancelAllTasks() }
        vm.toggleWatchlist()
        await fulfillment(of: [started], timeout: 2)
        vm.toggleWatchlist()
        vm.toggleWatchlist()
        gate.finish(false)
        await vm.watchlistMutationTask?.value
        XCTAssertEqual(sent, [true, false, true])
        XCTAssertTrue(vm.uiState.isInWatchlist)
    }

    private func makeViewModel(
        _ fixture: QueueOwnershipFixture,
        writer: @escaping @MainActor (NuvioMeta, Bool) async -> Bool
    ) async -> DetailsViewModel {
        let repository = QueueOwnershipRepository()
        let vm = DetailsViewModel(
            repository: repository, streamDiscoveryMode: .repository,
            deferredPreparationDelay: { throw CancellationError() }, enrichmentStarter: { _, _ in },
            watchlistContext: { fixture.context() }, remoteWatchlistMutation: { meta, membership, _ in await writer(meta, membership) }
        )
        await vm.loadDetails(id: repository.meta.id, type: repository.meta.type).value
        return vm
    }
}

/// SelectedLibraryService.setWatchlist(_:isInWatchlist:context:) waits for the AniList id
/// mapping before writing. Whatever changes during that wait, the write goes only to the
/// profile and account that started it, and is reported only for them.
@MainActor
final class SelectedLibraryWriteOwnershipTests: XCTestCase {
    private let meta = NuvioMeta(id: "tt0111161", name: "Film", imdbId: "tt0111161", type: "movie")

    private func switchProfile(away fixture: QueueOwnershipFixture) -> String {
        let other = "details-other-\(UUID().uuidString)"
        ProfileSettings.setActiveProfile(other, isPrimary: false)
        LibraryStore.setActiveProfile(other)
        return other
    }

    private func cleanUp(_ id: String) {
        UserDefaults.standard.removePersistentDomain(forName: "nuvio.tv.profile.settings.\(id)")
    }

    func testAProfileSwitchDuringTheMappingWritesNothingForEveryAuthMode() async {
        for mode in QueueOwnershipMode.allCases {
            let fixture = QueueOwnershipFixture(mode)
            defer { fixture.restore() }
            guard let context = fixture.context() else { return XCTFail("no context: \(mode)") }
            var other: String?
            var writes = 0
            let result = await SelectedLibraryService.setWatchlist(
                meta, isInWatchlist: true, context: context,
                resolve: { meta in other = self.switchProfile(away: fixture); return meta },
                write: { _, _, _ in writes += 1; return true }
            )
            XCTAssertFalse(result, "\(mode)")
            XCTAssertEqual(writes, 0, "Must not write to the next profile's library: \(mode)")
            other.map(cleanUp)
        }
    }

    func testAnAccountRelinkDuringTheMappingWritesNothingForEveryAuthMode() async {
        for mode in QueueOwnershipMode.allCases {
            let fixture = QueueOwnershipFixture(mode)
            defer { fixture.restore() }
            guard let context = fixture.context() else { return XCTFail("no context: \(mode)") }
            var writes = 0
            let result = await SelectedLibraryService.setWatchlist(
                meta, isInWatchlist: true, context: context,
                resolve: { meta in fixture.seed(mode, suffix: "relinked"); return meta },
                write: { _, _, _ in writes += 1; return true }
            )
            XCTAssertFalse(result, "\(mode)")
            XCTAssertEqual(writes, 0, "Must not write to the newly linked account: \(mode)")
        }
    }

    func testAWriteCompletedOnTheOwnerIsReportedForItEvenAfterASwitchForEveryAuthMode() async {
        let savedReport = TrackingAddonLibraryChanges.report
        defer { TrackingAddonLibraryChanges.report = savedReport }
        for mode in QueueOwnershipMode.allCases {
            let fixture = QueueOwnershipFixture(mode)
            defer { fixture.restore() }
            guard let context = fixture.context() else { return XCTFail("no context: \(mode)") }
            let ownerStore = fixture.store
            var reportedFor: [String?] = []
            TrackingAddonLibraryChanges.report = { _, _, profileID in reportedFor.append(profileID) }
            var writtenTo: LibraryWriteTarget?
            var other: String?

            await TrackingAddonLibraryChanges.perform(true, meta: meta, owner: .init(context: context)) {
                await SelectedLibraryService.setWatchlist(
                    self.meta, isInWatchlist: true, context: context,
                    resolve: { $0 },
                    write: { _, _, target in
                        writtenTo = target
                        // The request is in flight when the user switches profiles.
                        other = self.switchProfile(away: fixture)
                        return true
                    }
                )
            }.value

            XCTAssertTrue(writtenTo?.store === ownerStore, "Written to the owner's store: \(mode)")
            XCTAssertEqual(writtenTo?.source, mode.source, "\(mode)")
            XCTAssertEqual(reportedFor, [fixture.profile], "Reported for the owner, not the next profile: \(mode)")
            other.map(cleanUp)
        }
    }
}

/// Holds every request until the test lets the server answer, so the test can switch
/// profiles while a write is in flight.
private final class HeldResponseURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var _requests = 0
    private static var gate = DispatchSemaphore(value: 0)
    static var started: (() -> Void)?
    /// When set, only requests whose Authorization header contains it are held;
    /// the others are answered at once.
    static var holdOnlyAuthorization: String?
    /// The body to answer a request with (default "{}").
    static var body: ((URLRequest) -> Data)?

    static var requests: Int { lock.withLock { _requests } }

    static func reset() {
        lock.withLock { _requests = 0 }
        gate = DispatchSemaphore(value: 0)
        started = nil
        holdOnlyAuthorization = nil
        body = nil
    }

    static func answer() { gate.signal() }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self._requests += 1 }
        let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let held = Self.holdOnlyAuthorization.map { authorization.contains($0) } ?? true
        let data = Self.body?(request) ?? Data("{}".utf8)
        if held {
            let started = Self.started
            DispatchQueue.main.async { started?() }
        }
        let gate = Self.gate
        DispatchQueue.global().async { [self] in
            if held { gate.wait() }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HeldResponseURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

/// The real Simkl, MDBList and WeTrakr write paths when the profile switches while A's
/// request is in flight: a change the server applied is still a success (so it's reported
/// for A), but nothing updates the UI or cache that now belong to B.
@MainActor
final class LibraryServiceInFlightSwitchTests: XCTestCase {
    private let meta = NuvioMeta(id: "tt0111161", name: "Film", imdbId: "tt0111161", tmdbId: 278, type: "movie", year: 1994)
    private let uiNotifications = [
        TraktLibraryService.mutationNotification,
        TraktSettingsStore.libraryChangedNotification,
        MdbListLibraryService.mutationNotification,
        WeTrakrLibraryService.mutationNotification,
    ]

    override func setUp() {
        super.setUp()
        HeldResponseURLProtocol.reset()
    }

    private func write(_ mode: QueueOwnershipMode, _ fixture: QueueOwnershipFixture, session: URLSession) async -> Bool {
        switch mode {
        case .simklV1, .simklV2:
            return await SimklLibraryService.setWatchlist(
                meta, isInWatchlist: true, store: fixture.store, client: SimklAPIClient(session: session),
                tokenStorage: fixture.tokens, profileScope: fixture.profile
            )
        case .mdbOAuth, .mdbAPIKey:
            return await MdbListLibraryService.setWatchlist(
                meta, isInWatchlist: true, store: fixture.store, client: MdbListAPIClient(session: session),
                tokenStorage: fixture.tokens, profileScope: fixture.profile
            )
        case .weTrakr:
            return await WeTrakrLibraryService.setWatchlist(
                meta, isInWatchlist: true, store: fixture.store, profileScope: fixture.profile,
                tokenStorage: fixture.tokens, client: WeTrakrAPIClient(session: session)
            )
        case .trakt:
            return false
        }
    }

    private enum Interruption { case none, profileSwitch, accountRelink }

    /// Runs A's write and, while it's in flight, optionally switches to another profile or
    /// relinks the same profile to another account. Returns the result, the UI
    /// notifications posted, and the other profile's id.
    private func run(_ mode: QueueOwnershipMode, _ fixture: QueueOwnershipFixture, during interruption: Interruption,
                     beforeAnswer: ((String?) -> Void)? = nil) async -> (Bool, Int, String?) {
        let inFlight = expectation(description: "A's request in flight: \(mode)")
        HeldResponseURLProtocol.started = { inFlight.fulfill() }
        let session = HeldResponseURLProtocol.session()

        let task = Task { await self.write(mode, fixture, session: session) }
        await fulfillment(of: [inFlight], timeout: 3)
        var other: String?
        switch interruption {
        case .none:
            break
        case .profileSwitch:
            let id = "details-other-\(UUID().uuidString)"
            ProfileSettings.setActiveProfile(id, isPrimary: false)
            LibraryStore.setActiveProfile(id)
            other = id
        case .accountRelink:
            // A new grant (or a different API key) on the same profile: account B.
            fixture.seed(mode, suffix: "relinked")
        }
        beforeAnswer?(other)
        // Counted from here on: only what the server's answer causes, not the switch itself.
        var posted = 0
        let tokens = uiNotifications.map {
            NotificationCenter.default.addObserver(forName: $0, object: nil, queue: nil) { _ in posted += 1 }
        }
        defer { tokens.forEach(NotificationCenter.default.removeObserver) }
        HeldResponseURLProtocol.answer()
        let result = await task.value
        return (result, posted, other)
    }

    private func cleanUp(_ id: String?) {
        guard let id else { return }
        UserDefaults.standard.removePersistentDomain(forName: "nuvio.tv.profile.settings.\(id)")
    }

    func testASuccessConfirmedAfterASwitchIsStillASuccessButLeavesTheNewProfilesUIAlone() async {
        for mode in [QueueOwnershipMode.simklV1, .simklV2, .mdbOAuth, .mdbAPIKey, .weTrakr] {
            HeldResponseURLProtocol.reset()
            let fixture = QueueOwnershipFixture(mode)
            defer { fixture.restore() }
            let (result, posted, other) = await run(mode, fixture, during: .profileSwitch)
            defer { cleanUp(other) }
            XCTAssertEqual(HeldResponseURLProtocol.requests, 1, "\(mode)")
            XCTAssertTrue(result, "The server applied A's change, so it must be reported for A: \(mode)")
            XCTAssertEqual(posted, 0, "B's library UI must not get A's change: \(mode)")
        }
    }

    func testWithoutASwitchTheSuccessAlsoUpdatesTheUI() async {
        for mode in [QueueOwnershipMode.simklV1, .simklV2, .mdbOAuth, .mdbAPIKey, .weTrakr] {
            HeldResponseURLProtocol.reset()
            let fixture = QueueOwnershipFixture(mode)
            defer { fixture.restore() }
            let (result, posted, _) = await run(mode, fixture, during: .none)
            XCTAssertTrue(result, "\(mode)")
            XCTAssertGreaterThan(posted, 0, "\(mode)")
        }
    }

    func testWeTrakrNeverPutsAChangeIntoAnotherProfilesCache() async {
        let fixture = QueueOwnershipFixture(.weTrakr)
        defer { fixture.restore() }
        let ownerStore = fixture.store
        let bTitle = NuvioMeta(id: "tt-b", name: "B's title", type: "movie")
        let (result, _, other) = await run(.weTrakr, fixture, during: .profileSwitch) { otherID in
            // B's library was loaded after the switch, while A's request was still out.
            WeTrakrLibraryService.replaceCachedItems(
                [LibraryStoreItem(meta: bTitle, addedAt: Date())], for: ProfileSettings.store(for: otherID)
            )
        }
        defer { cleanUp(other) }
        XCTAssertTrue(result)
        let bCache = WeTrakrLibraryService.cachedItems(for: ProfileSettings.store(for: other))
        XCTAssertEqual(bCache?.map(\.meta.id), ["tt-b"], "A's add must not appear in B's cache")
        XCTAssertNil(WeTrakrLibraryService.cachedItems(for: ownerStore), "B's cache is never handed to A either")
    }

    func testASuccessConfirmedAfterASameProfileRelinkLeavesTheNewAccountsUIAlone() async {
        for mode in [QueueOwnershipMode.simklV1, .simklV2, .mdbOAuth, .mdbAPIKey, .weTrakr] {
            HeldResponseURLProtocol.reset()
            let fixture = QueueOwnershipFixture(mode)
            defer { fixture.restore() }
            let (result, posted, _) = await run(mode, fixture, during: .accountRelink)
            XCTAssertTrue(result, "Account A applied the change, so it's reported for A: \(mode)")
            XCTAssertEqual(posted, 0, "Account B's library UI must not get A's change: \(mode)")
        }
    }

    func testWeTrakrNeverPutsAChangeIntoTheRelinkedAccountsCache() async {
        let fixture = QueueOwnershipFixture(.weTrakr)
        defer { fixture.restore() }
        let store = fixture.store
        let bTitle = NuvioMeta(id: "tt-account-b", name: "Account B's title", type: "movie")
        let (result, _, _) = await run(.weTrakr, fixture, during: .accountRelink) { _ in
            // Account B's library was loaded after the relink, while A's request was still out.
            WeTrakrLibraryService.replaceCachedItems([LibraryStoreItem(meta: bTitle, addedAt: Date())], for: store)
        }
        XCTAssertTrue(result)
        XCTAssertEqual(WeTrakrLibraryService.cachedItems(for: store)?.map(\.meta.id), ["tt-account-b"],
                       "A's add must not appear in account B's cache")
    }

    func testWeTrakrsCacheBelongsToTheAccountItWasLoadedFor() {
        let fixture = QueueOwnershipFixture(.weTrakr)
        defer { fixture.restore() }
        let store = fixture.store
        WeTrakrLibraryService.replaceCachedItems([LibraryStoreItem(meta: meta, addedAt: Date())], for: store)
        XCTAssertNotNil(WeTrakrLibraryService.cachedItems(for: store))
        fixture.seed(.weTrakr, suffix: "relinked")
        XCTAssertNil(WeTrakrLibraryService.cachedItems(for: store), "Account A's list must not show for account B")
    }

    // MARK: WeTrakr library fetch

    private func fetch(_ fixture: QueueOwnershipFixture, store: UserDefaults, session: URLSession) async -> [LibraryStoreItem]? {
        await WeTrakrLibraryService.fetchLibrary(
            store: store, tokenStorage: fixture.tokens, profileScope: fixture.profile,
            client: WeTrakrAPIClient(session: session)
        )
    }

    func testAFetchAnsweredAfterARelinkIsNeitherCachedNorReturnedForTheNewAccount() async {
        HeldResponseURLProtocol.reset()
        let fixture = QueueOwnershipFixture(.weTrakr)
        defer { fixture.restore() }
        let store = fixture.store
        let inFlight = expectation(description: "A's movies and shows requests in flight")
        inFlight.expectedFulfillmentCount = 2
        HeldResponseURLProtocol.started = { inFlight.fulfill() }
        let session = HeldResponseURLProtocol.session()

        let fetchA = Task { await self.fetch(fixture, store: store, session: session) }
        await fulfillment(of: [inFlight], timeout: 3)
        fixture.seed(.weTrakr, suffix: "relinked")   // same profile, account B
        HeldResponseURLProtocol.answer()
        HeldResponseURLProtocol.answer()

        let result = await fetchA.value
        XCTAssertNil(result, "A's list must not be returned as account B's")
        XCTAssertNil(WeTrakrLibraryService.cachedItems(for: store), "nor cached under B's binding")
    }

    func testALateFetchForThePreviousAccountCannotReplaceTheNewAccountsCache() async {
        HeldResponseURLProtocol.reset()
        let fixture = QueueOwnershipFixture(.weTrakr)
        defer { fixture.restore() }
        let store = fixture.store
        // Only account A's requests ("access-a") are held; account B's answer at once,
        // with one movie in B's list.
        HeldResponseURLProtocol.holdOnlyAuthorization = "access-a"
        HeldResponseURLProtocol.body = { request in
            let isB = request.value(forHTTPHeaderField: "Authorization")?.contains("access-relinked") == true
            let isMovies = request.url?.path.hasSuffix("/movies") == true
            return Data((isB && isMovies ? #"[{"id":42,"type":"movie","title":"B Film","year":2020}]"# : "[]").utf8)
        }
        let inFlight = expectation(description: "A's requests in flight")
        inFlight.expectedFulfillmentCount = 2
        HeldResponseURLProtocol.started = { inFlight.fulfill() }
        let session = HeldResponseURLProtocol.session()

        let fetchA = Task { await self.fetch(fixture, store: store, session: session) }
        await fulfillment(of: [inFlight], timeout: 3)
        fixture.seed(.weTrakr, suffix: "relinked")
        let fetchB = await fetch(fixture, store: store, session: session)
        XCTAssertEqual(fetchB?.map(\.meta.name), ["B Film"])
        XCTAssertEqual(WeTrakrLibraryService.cachedItems(for: store)?.map(\.meta.name), ["B Film"])

        // A's answers arrive last.
        HeldResponseURLProtocol.answer()
        HeldResponseURLProtocol.answer()
        let resultA = await fetchA.value
        XCTAssertNil(resultA)
        XCTAssertEqual(WeTrakrLibraryService.cachedItems(for: store)?.map(\.meta.name), ["B Film"],
                       "A's late answer must not replace B's cache")
    }

    func testAFetchWithoutARelinkIsCachedAndReturned() async {
        HeldResponseURLProtocol.reset()
        let fixture = QueueOwnershipFixture(.weTrakr)
        defer { fixture.restore() }
        let store = fixture.store
        HeldResponseURLProtocol.holdOnlyAuthorization = "never-held"
        HeldResponseURLProtocol.body = { request in
            Data((request.url?.path.hasSuffix("/movies") == true
                  ? #"[{"id":7,"type":"movie","title":"A Film","year":2019}]"# : "[]").utf8)
        }
        let result = await fetch(fixture, store: store, session: HeldResponseURLProtocol.session())
        XCTAssertEqual(result?.map(\.meta.name), ["A Film"])
        XCTAssertEqual(WeTrakrLibraryService.cachedItems(for: store)?.map(\.meta.name), ["A Film"])
    }
}

