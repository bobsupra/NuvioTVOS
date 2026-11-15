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

