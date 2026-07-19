//
//  NuvioSyncService.swift
//  NuvioTV
//
//  Nuvio API profile, settings, library, watched, and progress sync for tvOS.
//  Mirrors the Android TV app's account contract over URLSession.
//

import Combine
import Foundation

@MainActor
final class NuvioSyncManager: ObservableObject {
    /// Posted by the Settings add-on list after an order/enabled-state change.
    /// The object is `[StreamAddonPreference]`, with `[String]` accepted for the
    /// old reorder-only path.
    static let addonOrderChangedNotification = Notification.Name("nuvio.tv.addons.orderChanged")
    /// Posted after an account pull applies profile-scoped Home inputs (add-ons,
    /// catalog layout, and watch progress). Home keeps its catalog tree cached,
    /// so it must explicitly rebuild once those inputs arrive.
    static let homeContentSyncedNotification = Notification.Name("nuvio.tv.homeContentSynced")
    /// Short, non-sensitive status strings shown only when Home content is
    /// missing on a physical Apple TV.
    static private(set) var addonSyncDiagnostic = "not pulled"
    static private(set) var progressSyncDiagnostic = "not pulled"
    static private(set) var catalogSettingsSyncDiagnostic = "not pulled"
    static private(set) var accountSyncDiagnostic = "not started"

    /// True from sign-in until the first profile pull has been applied (or the
    /// pull fails), so the who's-watching screen can wait for real profile
    /// names instead of rendering local stubs.
    @Published private(set) var isPullingAccountProfiles = false
    @Published private(set) var profileSyncError: String?

    private let client = NuvioAPIClient()

    /// Full remote addon rows from the last pull — including disabled add-ons
    /// and custom names that tvOS doesn't render. `sync_push_addons` replaces
    /// the whole set, so a reorder must round-trip these untouched.
    private var lastPulledAddonRows: [RemoteAddon] = []

    // These are lifetime dependencies, not callbacks. Retaining them guarantees
    // that a delayed sync always sees the same live profile storage attached by
    // the SwiftUI root. The root owns all three objects, and neither dependency
    // points back to this manager, so this creates no retain cycle.
    private var authManager: AuthManager?
    private var profileViewModel: ProfileViewModel?
    private var observers: [NSObjectProtocol] = []
    private var pullTask: Task<Void, Never>?
    private var pushTask: Task<Void, Never>?
    private var profileSelectionRefreshTask: Task<Void, Never>?
    private var completedInitialPullKeys: Set<String> = []
    private var automaticAccountPullRetryCount = 0
    /// Identifies the pull that currently owns `pullTask` and the post-login
    /// loading gate. A cancelled pull can unwind after its replacement starts;
    /// without an ownership token, that stale task can reveal the local Guest
    /// while the replacement is still downloading the account.
    private var pullGeneration: UInt = 0
    private var observedAuthUserId: String?
    private var observedActiveProfileId: String?
    private var isApplyingRemote = false
    private var didAttach = false

    deinit {
        pullTask?.cancel()
        pushTask?.cancel()
        profileSelectionRefreshTask?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func attach(authManager: AuthManager, profileViewModel: ProfileViewModel) {
        // `onAppear` may run again after SwiftUI rebuilds the root. Refresh the
        // dependencies even though notification observers only attach once.
        self.authManager = authManager
        self.profileViewModel = profileViewModel
        profileViewModel.configureRemotePinVerifier { [weak self] profileId, pin in
            guard let self else {
                throw AuthError(message: "PIN verification is unavailable.")
            }
            return try await self.verifyRemoteProfilePin(profileId: profileId, pin: pin)
        }
        guard !didAttach else { return }
        didAttach = true

        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: ProfileManager.profilesChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.schedulePush() }
        })
        observers.append(center.addObserver(
            forName: LibraryStore.changedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.schedulePush() }
        })
        observers.append(center.addObserver(
            forName: WatchedStore.changedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.schedulePush() }
        })
        observers.append(center.addObserver(
            forName: ContinueWatchingStore.changedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.schedulePush() }
        })
        observers.append(center.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.schedulePush() }
        })
        observers.append(center.addObserver(
            forName: Self.addonOrderChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let preferences: [StreamAddonPreference]
            if let postedPreferences = notification.object as? [StreamAddonPreference] {
                preferences = postedPreferences
            } else {
                let urls = notification.object as? [String] ?? []
                preferences = urls.map { StreamAddonPreference(url: $0, enabled: true) }
            }
            Task { @MainActor in self?.pushAddonPreferences(preferences) }
        })
        observers.append(center.addObserver(
            forName: CollectionsStore.locallyEditedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let raw = notification.object as? [[String: Any]] ?? []
            Task { @MainActor in self?.pushCollectionsEdit(raw) }
        })

        // `AuthManager` restores its persisted session synchronously in init.
        // SwiftUI can therefore deliver the current auth/profile publishers
        // before this manager's `onAppear` attachment runs. Reconcile their
        // snapshots now so a restored account cannot miss its only startup
        // pull and leave Home showing local defaults until auth changes again.
        observedActiveProfileId = profileViewModel.activeProfile?.id
        authStateChanged(authManager.authState)
    }

    func authStateChanged(_ state: AuthState) {
        switch state {
        case let .fullAccount(userId, _):
            // `AuthManager` republishes the same account after refreshing its
            // token. Treating that as a new login force-cancelled the bootstrap
            // request which caused the refresh. Only a genuinely different
            // account should replace an in-flight pull.
            let isSameAccount = userId == observedAuthUserId
            if isSameAccount {
                // A token refresh republishes the same account. Keep an active
                // bootstrap intact, and do not repeat one that already landed.
                if pullTask != nil { return }
                // Once owned recovery has exhausted its retries, leave the
                // visible error stable. Only the user's Retry action should
                // re-arm the gate and start another full bootstrap.
                if profileSyncError != nil { return }
                if let key = currentSyncKey(), completedInitialPullKeys.contains(key) {
                    return
                }
            }
            observedAuthUserId = userId
            Self.accountSyncDiagnostic = "scheduled"
            if AuthConfig.isConfigured {
                isPullingAccountProfiles = true
            }
            // If the publisher fired before `attach`, no task was created. The
            // snapshot reconciliation in `attach` reaches this branch again and
            // starts the missing pull without cancelling any valid same-user work.
            schedulePull(force: !isSameAccount)
        case .signedOut:
            Self.accountSyncDiagnostic = "signed out"
            pullGeneration &+= 1
            pullTask?.cancel()
            pullTask = nil
            pushTask?.cancel()
            profileSelectionRefreshTask?.cancel()
            profileSelectionRefreshTask = nil
            completedInitialPullKeys.removeAll()
            observedAuthUserId = nil
            observedActiveProfileId = nil
            isPullingAccountProfiles = false
            profileSyncError = nil
        case .loading:
            break
        }
    }

    /// Called by the successful-login continuation. Auth-state observation is
    /// still the primary trigger, but this explicit hand-off closes the SwiftUI
    /// lifecycle gap where the publisher can be delivered before attachment.
    /// It never restarts an in-flight or already-completed bootstrap.
    func beginPostLoginSync() {
        guard AuthConfig.isConfigured, authManager?.isAuthenticated == true else { return }
        if let key = currentSyncKey(), completedInitialPullKeys.contains(key) { return }

        profileSyncError = nil
        isPullingAccountProfiles = true
        schedulePull()
    }

    /// Refresh cross-device changes whenever tvOS returns to the foreground.
    /// Startup already owns its initial pull, so only refresh an account/profile
    /// whose bootstrap completed and never replace an in-flight pull.
    func refreshAccountFromForeground() {
        guard let key = currentSyncKey(), completedInitialPullKeys.contains(key) else { return }
        guard pullTask == nil else { return }
        schedulePull(force: true)
    }

    /// Retries the complete account bootstrap, not just the profile list. This
    /// is the same operation a profile switch used to trigger accidentally.
    func retryInitialAccountPull() {
        guard AuthConfig.isConfigured, authManager?.isAuthenticated == true else { return }
        profileSyncError = nil
        isPullingAccountProfiles = true
        schedulePull(force: true)
    }

    func activeProfileChanged(_ profile: Profile?) {
        let profileId = profile?.id
        guard profileId != observedActiveProfileId else { return }
        observedActiveProfileId = profileId
        guard profile != nil, !isApplyingRemote else { return }
        schedulePull(force: true)
    }

    private func verifyRemoteProfilePin(profileId: String, pin: String) async throws -> Bool {
        guard let authManager,
              let profileViewModel,
              let profile = profileViewModel.profiles.first(where: { $0.id == profileId }),
              let session = await authManager.validSessionForSync() else {
            throw AuthError(message: "The account session is unavailable.")
        }

        let remoteProfileId = ProfileSyncIndexStore.remoteId(
            for: profile,
            in: profileViewModel.profiles
        )
        let result = try await client.verifyProfilePin(
            session: session,
            remoteProfileId: remoteProfileId,
            pin: pin
        )
        return result.unlocked
    }

    func verifyProfilePin(profileId: String, pin: String) async -> Bool {
        do {
            return try await verifyRemoteProfilePin(profileId: profileId, pin: pin)
        } catch {
            print("Remote profile PIN verification failed: \(error.localizedDescription)")
            return false
        }
    }

    func updateProfilePin(
        profileId: String,
        pin: String?,
        currentPin: String?
    ) async -> Bool {
        guard let authManager,
              let profileViewModel,
              let profile = profileViewModel.profiles.first(where: { $0.id == profileId }),
              let session = await authManager.validSessionForSync() else {
            return false
        }

        let remoteProfileId = ProfileSyncIndexStore.remoteId(
            for: profile,
            in: profileViewModel.profiles
        )

        do {
            if let pin {
                try await client.setProfilePin(
                    session: session,
                    remoteProfileId: remoteProfileId,
                    pin: pin,
                    currentPin: currentPin
                )
            } else {
                try await client.clearProfilePin(
                    session: session,
                    remoteProfileId: remoteProfileId,
                    currentPin: currentPin
                )
            }
            return profileViewModel.setProfilePinProtection(
                id: profileId,
                isProtected: pin != nil
            )
        } catch {
            print("Remote profile PIN update failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Mirrors Android's profile-save path: a user edit replaces the complete
    /// account profile set, then reads it back so the picker reflects exactly
    /// what the server accepted. This intentionally does not use the delayed
    /// general snapshot queue.
    func syncProfilesAfterLocalEdit() {
        guard AuthConfig.isConfigured, authManager?.isAuthenticated == true else { return }
        guard let profileViewModel else { return }
        let profiles = profileViewModel.profiles
        guard !profiles.isEmpty else { return }
        guard let syncKey = currentSyncKey(), completedInitialPullKeys.contains(syncKey) else {
            profileSyncError = "Finish loading the account before saving profile changes."
            retryInitialAccountPull()
            return
        }
        guard !profiles.contains(where: Self.isPlaceholderProfile) else {
            profileSyncError = "Account profiles have not finished loading yet."
            retryInitialAccountPull()
            return
        }

        Task { @MainActor [weak self] in
            guard let self,
                  let authManager = self.authManager,
                  let session = await authManager.validSessionForSync(),
                  authManager.isAuthenticated else { return }
            do {
                try self.ensureStillSyncing()
                try await self.client.pushProfiles(session: session, profiles: profiles)
                try self.ensureStillSyncing()
                let remoteProfiles = try await self.client.pullProfiles(session: session)
                guard !remoteProfiles.isEmpty else {
                    throw AuthError(message: "The server did not return the saved profiles.")
                }
                guard Self.remoteProfiles(remoteProfiles, confirm: profiles) else {
                    // Never erase a newly created local profile because a
                    // delayed or broken server read returned only the old
                    // default row. The user can still select it immediately;
                    // a later retry will reconcile once Nuvio confirms it.
                    self.profileSyncError = "Profile saved on this Apple TV, but Nuvio has not confirmed it yet."
                    print("Nuvio profile save was not yet confirmed; keeping the local profile list.")
                    return
                }
                let merged = ProfileSyncIndexStore.localProfiles(
                    from: remoteProfiles,
                    preserving: profiles
                )
                self.isApplyingRemote = true
                let applied = self.profileViewModel?.applyRemoteProfiles(merged) == true
                self.isApplyingRemote = false
                guard applied else {
                    throw AuthError(message: "The saved profiles could not be applied on this Apple TV.")
                }
                self.profileSyncError = nil
                print("Nuvio sync saved and confirmed \(remoteProfiles.count) profile(s).")
            } catch is CancellationError {
                self.isApplyingRemote = false
            } catch {
                self.isApplyingRemote = false
                self.profileSyncError = "Couldn't save profiles: \(error.localizedDescription)"
                print("Nuvio profile sync failed: \(error.localizedDescription)")
            }
        }
    }

    private static func remoteProfiles(_ remoteProfiles: [RemoteProfile], confirm localProfiles: [Profile]) -> Bool {
        localProfiles.allSatisfy { local in
            let remoteId = ProfileSyncIndexStore.remoteId(for: local, in: localProfiles)
            guard let remote = remoteProfiles.first(where: { $0.profileIndex == remoteId }) else {
                return false
            }
            let remoteName = remote.name.isEmpty ? "Nuvio User" : remote.name
            return remoteName == local.name
                && (remote.avatarId ?? "") == local.avatarId
                && remote.usesPrimaryAddons == local.usesPrimaryAddons
                && remote.usesPrimaryPlugins == local.usesPrimaryPlugins
        }
    }

    /// Performs a profiles-only account refresh when the profile picker has no
    /// real local profiles. This is deliberately independent of startup sync:
    /// entering the picker must always provide a fresh opportunity to recover
    /// from a missed auth-state event, an expired JWT, or a transient empty RPC.
    func refreshProfilesForSelectionIfNeeded(force: Bool = false) {
        guard AuthConfig.isConfigured, authManager?.isAuthenticated == true else { return }
        guard let profileViewModel else { return }
        guard force || profileViewModel.profiles.allSatisfy(Self.isPlaceholderProfile) else {
            profileSyncError = nil
            return
        }
        guard profileSelectionRefreshTask == nil else { return }
        // Let the full startup pull finish first. If it succeeds, the picker is
        // updated by ProfileManager's notification; if not, its completion
        // reveals the picker and this method runs again from `onAppear`.
        guard !isPullingAccountProfiles else { return }

        profileSyncError = nil
        isPullingAccountProfiles = true
        profileSelectionRefreshTask = Task { @MainActor [weak self] in
            await self?.refreshProfilesForSelection()
        }
    }

    private func refreshProfilesForSelection() async {
        var shouldPullFullAccount = false
        defer {
            isPullingAccountProfiles = false
            profileSelectionRefreshTask = nil
            if shouldPullFullAccount {
                retryInitialAccountPull()
            }
        }
        guard let authManager, let profileViewModel else { return }

        var lastError: Error?
        let delays: [UInt64] = [0, 1, 2, 4]
        for (attempt, delay) in delays.enumerated() {
            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: delay * 1_000_000_000)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled, authManager.isAuthenticated else { return }

            guard let session = await authManager.validSessionForSync(validateWithServer: true) else {
                lastError = AuthError(message: "Your account session could not be restored.")
                continue
            }
            do {
                let remoteProfiles = try await client.pullProfiles(session: session)
                guard !remoteProfiles.isEmpty else {
                    lastError = nil
                    continue
                }
                let merged = ProfileSyncIndexStore.localProfiles(
                    from: remoteProfiles,
                    preserving: profileViewModel.profiles
                )
                isApplyingRemote = true
                let applied = profileViewModel.applyRemoteProfiles(merged)
                observedActiveProfileId = profileViewModel.activeProfile?.id
                isApplyingRemote = false
                guard applied else {
                    lastError = AuthError(message: "The downloaded profiles could not be applied.")
                    continue
                }
                profileSyncError = nil
                // A profiles-only recovery must always be followed by the
                // complete Home/account pull. Do not depend on the timing of
                // SwiftUI's `$activeProfile` delivery to start it.
                shouldPullFullAccount = true
                print("Nuvio profile picker refreshed \(remoteProfiles.count) account profile(s).")
                return
            } catch {
                lastError = error
                // Match the Android client: if the first authenticated request
                // is rejected, refresh the JWT before retrying the RPC.
                if attempt == 0 {
                    _ = await authManager.refreshSessionForSync()
                }
            }
        }

        isApplyingRemote = false
        if let lastError {
            profileSyncError = "Couldn't load account profiles: \(lastError.localizedDescription)"
        } else {
            profileSyncError = "No synced profiles were returned for this account."
        }
    }

    private func schedulePull(force: Bool = false) {
        guard AuthConfig.isConfigured else {
            Self.accountSyncDiagnostic = "backend not configured"
            return
        }
        guard authManager?.isAuthenticated == true else {
            Self.accountSyncDiagnostic = "not authenticated"
            return
        }
        if !force, pullTask != nil { return }

        pullGeneration &+= 1
        let generation = pullGeneration
        automaticAccountPullRetryCount = 0
        pullTask?.cancel()
        pullTask = Task { @MainActor [weak self] in
            if !force {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            guard !Task.isCancelled else {
                self?.finishPull(generation: generation)
                return
            }
            await self?.pullThenPush(generation: generation)
        }
    }

    private func releasePostLoginGate(generation: UInt) {
        guard generation == pullGeneration else { return }
        isPullingAccountProfiles = false
    }

    private func finishPull(generation: UInt) {
        guard generation == pullGeneration else { return }
        pullTask = nil
        isPullingAccountProfiles = false
    }

    private func schedulePush() {
        guard !isApplyingRemote else { return }
        guard AuthConfig.isConfigured else { return }
        guard authManager?.isAuthenticated == true else { return }
        guard let key = currentSyncKey(), completedInitialPullKeys.contains(key) else { return }

        pushTask?.cancel()
        pushTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 1_500_000_000)
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  let key = self.currentSyncKey(),
                  self.completedInitialPullKeys.contains(key) else { return }
            await self.pushLocalSnapshots()
        }
    }

    /// Task cancellation is cooperative, so a pull that is mid-flight when the
    /// user signs out would otherwise finish and pour account data back into
    /// the freshly wiped local stores. Call between every network step and the
    /// local apply that follows it; throws once auth flips or the task is
    /// cancelled so the sync dies before it can touch local state.
    private func ensureStillSyncing() throws {
        try Task.checkCancellation()
        guard authManager?.isAuthenticated == true else { throw CancellationError() }
    }

    /// A freshly exchanged TV token can become visible to Auth before the sync
    /// RPCs can read the account rows. Retry session validation and the profile
    /// RPC as one bootstrap operation, reacquiring the session every time. The
    /// old code retried one stale token and converted every RPC error to an
    /// empty profile list, which exposed the local Guest and ended the pull.
    private func bootstrapAccount(
        authManager: AuthManager
    ) async throws -> (session: AuthSession, profiles: [RemoteProfile]) {
        let delays: [UInt64] = [0, 1, 2, 3, 4, 5]
        var lastError: Error = AuthError(message: "The account session is not ready yet.")

        for (attempt, delay) in delays.enumerated() {
            if delay > 0 {
                try await Task.sleep(nanoseconds: delay * 1_000_000_000)
            }
            try ensureStillSyncing()
            Self.accountSyncDiagnostic = "connecting account (\(attempt + 1)/\(delays.count))"

            guard let session = await authManager.validSessionForSync(validateWithServer: true) else {
                lastError = AuthError(message: "The account session could not be restored.")
                continue
            }

            do {
                let profiles = try await client.pullProfiles(session: session)
                try ensureStillSyncing()
                guard !profiles.isEmpty else {
                    lastError = AuthError(message: "Nuvio has not returned the account profiles yet.")
                    continue
                }
                return (session, profiles)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as AuthError {
                lastError = error
                if error.statusCode == 401 {
                    _ = await authManager.refreshSessionForSync()
                }
            } catch {
                lastError = error
            }
        }

        throw lastError
    }

    private func pullThenPush(generation: UInt) async {
        // Release the who's-watching sync gate on every exit path; the happy
        // path clears it only after profile-scoped Home inputs are persisted.
        defer { finishPull(generation: generation) }

        guard let authManager, let profileViewModel else {
            Self.accountSyncDiagnostic = "manager not attached"
            return
        }

        do {
            let bootstrap = try await bootstrapAccount(authManager: authManager)
            let session = bootstrap.session
            let remoteProfiles = bootstrap.profiles
            Self.accountSyncDiagnostic = "applying profiles"
            let merged = ProfileSyncIndexStore.localProfiles(
                from: remoteProfiles,
                preserving: profileViewModel.profiles
            )
            isApplyingRemote = true
            let profilesApplied = profileViewModel.applyRemoteProfiles(merged)
            // `$activeProfile` can be delivered by SwiftUI after this
            // synchronous apply returns. Record the imported selection before
            // clearing the guard so it cannot cancel this same account pull.
            observedActiveProfileId = profileViewModel.activeProfile?.id
            isApplyingRemote = false
            guard profilesApplied else {
                throw AuthError(message: "The downloaded profiles could not be applied on this Apple TV.")
            }
            profileSyncError = nil
            print("Nuvio sync pulled \(remoteProfiles.count) account profile(s).")

            guard let activeProfile = profileViewModel.activeProfile ?? profileViewModel.profiles.first else {
                return
            }

            let remoteProfileId = ProfileSyncIndexStore.remoteId(
                for: activeProfile,
                in: profileViewModel.profiles
            )
            let addonProfileId = activeProfile.usesPrimaryAddons && remoteProfileId != 1
                ? 1
                : remoteProfileId

            var profileSettingsReconciled = true
            var pullFailures = 0
            Self.accountSyncDiagnostic = "pulling account data"
            do {
                try ensureStillSyncing()
                isApplyingRemote = true
                let settingsApplied = try await client.pullProfileSettings(
                    session: session,
                    remoteProfileId: remoteProfileId,
                    localProfileId: activeProfile.id
                )
                if !settingsApplied {
                    try await client.pushProfileSettings(
                        session: session,
                        remoteProfileId: remoteProfileId,
                        localProfileId: activeProfile.id
                    )
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Profile settings are independent of Home inputs. Keep pulling
                // add-ons, catalog layout, and progress, but do not enable the
                // later snapshot push after this partial reconciliation.
                profileSettingsReconciled = false
                print("Nuvio profile settings sync failed: \(error.localizedDescription)")
            }

            do {
                let remoteAddons = try await client.pullAddons(
                    session: session,
                    remoteProfileId: addonProfileId
                )
                try ensureStillSyncing()
                lastPulledAddonRows = remoteAddons
                let appliedCount = client.applyAddons(remoteAddons, localProfileId: activeProfile.id)
                Self.addonSyncDiagnostic = "remote \(remoteAddons.count), enabled \(appliedCount)"
                print("Nuvio sync pulled \(appliedCount) enabled add-on(s).")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                pullFailures += 1
                Self.addonSyncDiagnostic = "failed: \(error.localizedDescription)"
                print("Nuvio add-on sync failed: \(error.localizedDescription)")
            }

            do {
                if let collectionsBlob = try await client.pullCollections(
                    session: session,
                    remoteProfileId: remoteProfileId
                ) {
                    try ensureStillSyncing()
                    CollectionsStore.applyRemote(collectionsBlob)
                    let count = CollectionsStore.collections().count
                    print("Nuvio sync pulled collections (\(collectionsBlob.count) bytes, \(count) collection(s)).")
                } else {
                    print("Nuvio sync pulled collections: server returned none.")
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                pullFailures += 1
                print("Nuvio collections sync failed: \(error.localizedDescription)")
            }

            do {
                if let catalogSettings = try await client.pullHomeCatalogSettings(
                    session: session,
                    remoteProfileId: remoteProfileId
                ) {
                    try ensureStillSyncing()
                    client.applyHomeCatalogSettings(catalogSettings, localProfileId: activeProfile.id)
                    Self.catalogSettingsSyncDiagnostic = "pulled \(catalogSettings.items.count) item(s)"
                    print("Nuvio sync pulled home catalog settings (\(catalogSettings.items.count) item(s)).")
                } else {
                    Self.catalogSettingsSyncDiagnostic = "server returned none"
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                pullFailures += 1
                Self.catalogSettingsSyncDiagnostic = "failed: \(error.localizedDescription)"
                print("Nuvio home catalog sync failed: \(error.localizedDescription)")
            }

            // Pull each watch-state collection independently so one failing
            // request (or one undecodable payload) can't abort the others.
            let watchStateUploadsEnabled = Self.watchStateSyncEnabled(for: activeProfile.id)
            // Always pull account state. The local switch may stop this Apple
            // TV from uploading edits, but it must not make an authenticated
            // account look empty after reinstalling the app.
            do {
                let remoteLibrary = try await client.pullLibrary(
                    session: session,
                    remoteProfileId: remoteProfileId
                )
                try ensureStillSyncing()
                LibraryStore.mergeRemote(remoteLibrary)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                pullFailures += 1
                print("Nuvio library sync failed: \(error.localizedDescription)")
            }

            do {
                let remoteWatched = try await client.pullWatched(
                    session: session,
                    remoteProfileId: remoteProfileId
                )
                try ensureStillSyncing()
                WatchedStore.mergeRemote(remoteWatched)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                pullFailures += 1
                print("Nuvio watched sync failed: \(error.localizedDescription)")
            }

            do {
                let remoteProgress = try await client.pullWatchProgress(
                    session: session,
                    remoteProfileId: remoteProfileId
                )
                try ensureStillSyncing()
                guard ContinueWatchingStore.mergeRemote(remoteProgress) else {
                    throw AuthError(message: ContinueWatchingStore.persistenceDiagnostic)
                }
                let uploadStatus = watchStateUploadsEnabled ? "uploads on" : "uploads off"
                Self.progressSyncDiagnostic = "profile \(activeProfile.id), remote \(remoteProgress.count), stored \(ContinueWatchingStore.items().count), \(uploadStatus); \(ContinueWatchingStore.persistenceDiagnostic)"
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                pullFailures += 1
                Self.progressSyncDiagnostic = "failed: \(error.localizedDescription)"
                print("Nuvio watch progress sync failed: \(error.localizedDescription)")
            }
            isApplyingRemote = false

            let pullWasIncomplete = pullFailures > 0 || !profileSettingsReconciled
            if pullWasIncomplete, automaticAccountPullRetryCount < 2 {
                automaticAccountPullRetryCount += 1
                Self.accountSyncDiagnostic = "retrying account data (\(automaticAccountPullRetryCount)/2)"
                try await Task.sleep(
                    nanoseconds: UInt64(automaticAccountPullRetryCount) * 1_000_000_000
                )
                try ensureStillSyncing()
                await pullThenPush(generation: generation)
                return
            }

            if pullWasIncomplete {
                profileSyncError = "Some account data couldn't be loaded. Retry the account sync."
                Self.accountSyncDiagnostic = "account data partially loaded"
            } else {
                automaticAccountPullRetryCount = 0
                profileSyncError = nil
            }

            // Home may have loaded while this pull was in flight using the
            // default/no-add-on settings. Rebuild its cached catalog tree only
            // after all profile-scoped inputs above have landed.
            NotificationCenter.default.post(name: Self.homeContentSyncedNotification, object: nil)
            if !pullWasIncomplete {
                Self.accountSyncDiagnostic = "home inputs pulled"
            }
            // The post-login screen represents the complete initial sync. Do
            // not reveal the picker while progress/add-ons are still being
            // written under the newly imported profile.
            releasePostLoginGate(generation: generation)

            // Enable pushes only after a complete pull; pushing a snapshot built
            // from a partial pull could overwrite remote state we never saw.
            guard !pullWasIncomplete else { return }
            if let key = currentSyncKey() {
                completedInitialPullKeys.insert(key)
            }
            await pushLocalSnapshots()
        } catch is CancellationError {
            isApplyingRemote = false
            Self.accountSyncDiagnostic = "cancelled; retry pending"
        } catch {
            isApplyingRemote = false
            Self.accountSyncDiagnostic = "failed: \(error.localizedDescription)"
            print("Nuvio sync failed: \(error.localizedDescription)")
            // Keep profile recovery inside this same login-owned task. Running
            // it as detached background work used to lower the gate here and
            // expose Guest while recovery was still actively pulling.
            if profileViewModel.profiles.allSatisfy(Self.isPlaceholderProfile) {
                profileSyncError = "Couldn't load the account yet: \(error.localizedDescription)"
                if await backfillAccountProfiles() {
                    await pullThenPush(generation: generation)
                }
            }
        }
    }

    /// Re-pulls account profiles a few times after the initial post-login pull
    /// came back empty. That first read often races a just-issued token and
    /// returns nothing even though the account has profiles; the who's-watching
    /// screen would then be left showing the local "Nuvio Guest" placeholder
    /// until the user picks a profile (which triggers a fresh pull) and returns.
    /// This stays awaited by the post-login bootstrap so the placeholder cannot
    /// be selected while a recoverable account read is still in progress.
    private func backfillAccountProfiles() async -> Bool {
        print("Nuvio sync starting profile backfill (post-login read yielded no profiles).")
        // Backoff between attempts (seconds); spans ~55s so a slow backend
        // that only makes a fresh account's profiles readable well after the
        // token is issued still gets caught.
        let delays: [UInt64] = [2, 3, 4, 6, 8, 10, 10, 12]
        for seconds in delays {
            do {
                try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                try ensureStillSyncing()
            } catch {
                return false
            }
            guard let authManager, let profileViewModel else { return false }
            guard let session = await authManager.validSessionForSync(validateWithServer: true) else {
                continue
            }
            guard (try? ensureStillSyncing()) != nil else { return false }
            let remote: [RemoteProfile]
            do {
                remote = try await client.pullProfiles(session: session)
            } catch let error as AuthError where error.statusCode == 401 {
                _ = await authManager.refreshSessionForSync()
                continue
            } catch {
                continue
            }
            guard !remote.isEmpty else {
                print("Nuvio sync profile backfill attempt still empty.")
                continue
            }
            let merged = ProfileSyncIndexStore.localProfiles(
                from: remote,
                preserving: profileViewModel.profiles
            )
            isApplyingRemote = true
            let applied = profileViewModel.applyRemoteProfiles(merged)
            observedActiveProfileId = profileViewModel.activeProfile?.id
            isApplyingRemote = false
            guard applied else {
                print("Nuvio sync could not apply backfilled profiles; retrying.")
                continue
            }
            profileSyncError = nil
            print("Nuvio sync backfilled \(remote.count) profile(s) before profile selection.")
            return true
        }
        print("Nuvio sync profile backfill gave up after \(delays.count) attempts.")
        return false
    }

    /// Pushes a locally edited collections blob to the account (same
    /// `sync_push_collections` contract as Android).
    ///
    /// Always pull-merges first: a Settings edit on this Apple TV must not
    /// wipe collections that only exist on Android (created after the last
    /// full pull, or never decoded locally). Intentional deletes of ids that
    /// were present in the last pull still go through.
    private func pushCollectionsEdit(_ raw: [[String: Any]]) {
        guard AuthConfig.isConfigured else { return }
        guard let authManager, authManager.isAuthenticated else { return }
        guard let profileViewModel,
              let activeProfile = profileViewModel.activeProfile ?? profileViewModel.profiles.first else { return }

        let remoteProfileId = ProfileSyncIndexStore.remoteId(
            for: activeProfile,
            in: profileViewModel.profiles
        )
        let previouslyPulledIds = CollectionsStore.lastPulledCollectionIds()

        Task { @MainActor [weak self] in
            guard let self, let session = await authManager.validSessionForSync() else { return }
            do {
                var payload = raw
                if let remoteBlob = try await self.client.pullCollections(
                    session: session,
                    remoteProfileId: remoteProfileId
                ),
                   let remoteRows = Self.collectionsArray(from: remoteBlob) {
                    payload = CollectionsStore.mergeLocalEdit(
                        local: raw,
                        remote: remoteRows,
                        previouslyPulledIds: previouslyPulledIds
                    )
                }

                try await self.client.pushCollections(
                    session: session,
                    remoteProfileId: remoteProfileId,
                    rawCollections: payload
                )
                // Keep local cache aligned with what we uploaded (includes
                // remote-only rows we preserved).
                if let data = try? JSONSerialization.data(withJSONObject: payload) {
                    CollectionsStore.applyRemote(data)
                }
                print("Nuvio sync pushed \(payload.count) collection(s).")
            } catch {
                print("Nuvio collections push failed: \(error.localizedDescription)")
            }
        }
    }

    private static func collectionsArray(from data: Data) -> [[String: Any]]? {
        let object = try? JSONSerialization.jsonObject(with: data)
        if let array = object as? [[String: Any]] { return array }
        if let text = object as? String,
           let inner = text.data(using: .utf8),
           let array = (try? JSONSerialization.jsonObject(with: inner)) as? [[String: Any]] {
            return array
        }
        return nil
    }

    private func pushLocalSnapshots() async {
        guard let authManager, let profileViewModel else { return }
        guard let key = currentSyncKey(), completedInitialPullKeys.contains(key) else { return }
        guard let session = await authManager.validSessionForSync() else { return }
        guard let activeProfile = profileViewModel.activeProfile ?? profileViewModel.profiles.first else { return }

        let remoteProfileId = ProfileSyncIndexStore.remoteId(
            for: activeProfile,
            in: profileViewModel.profiles
        )

        do {
            // A push racing a sign-out would upload the freshly wiped (empty)
            // local snapshots over the account's server data — abort between
            // steps the moment auth flips.
            try ensureStillSyncing()
            try await client.pushProfileSettings(
                session: session,
                remoteProfileId: remoteProfileId,
                localProfileId: activeProfile.id
            )

            guard Self.watchStateSyncEnabled(for: activeProfile.id) else { return }
            try ensureStillSyncing()
            try await client.pushLibrary(session: session, remoteProfileId: remoteProfileId)
            try ensureStillSyncing()
            try await client.pushWatched(session: session, remoteProfileId: remoteProfileId)
            try ensureStillSyncing()
            try await client.pushWatchProgress(session: session, remoteProfileId: remoteProfileId)
            print("Nuvio sync pushed \(LibraryStore.items().count) library, \(WatchedStore.items().count) watched, \(ContinueWatchingStore.items().count) progress item(s).")
        } catch is CancellationError {
            // Signed out mid-push: stop quietly, nothing was corrupted.
        } catch {
            print("Nuvio sync push failed: \(error.localizedDescription)")
        }
    }

    /// Pushes the complete local add-on list to the account. The public RPC is
    /// full-replace, so omitted rows (including an entirely empty list) must be
    /// allowed to delete their remote counterparts.
    private func pushAddonPreferences(_ preferences: [StreamAddonPreference]) {
        let normalizedPreferences = Self.normalizedAddonPreferences(preferences)
        guard AuthConfig.isConfigured else { return }
        guard let authManager, authManager.isAuthenticated else { return }
        guard let profileViewModel,
              let activeProfile = profileViewModel.activeProfile ?? profileViewModel.profiles.first else { return }

        let remoteProfileId = ProfileSyncIndexStore.remoteId(
            for: activeProfile,
            in: profileViewModel.profiles
        )
        // The public profile contract allows a secondary profile to consume
        // profile 1's add-ons. It is read-only from that secondary profile;
        // pushing its local view would replace the primary profile's full set.
        guard remoteProfileId == 1 || !activeProfile.usesPrimaryAddons else { return }
        let knownRows = lastPulledAddonRows

        Task { @MainActor [weak self] in
            guard let self, let session = await authManager.validSessionForSync() else { return }
            var payload: [[String: Any]] = []

            for (index, preference) in normalizedPreferences.enumerated() {
                let known = knownRows.first {
                    Self.normalizedAddonURL($0.url) == preference.url
                }
                var row: [String: Any] = [
                    "url": preference.url,
                    "sort_order": index,
                    "enabled": preference.enabled
                ]
                if let name = known?.name, !name.isEmpty { row["name"] = name }
                payload.append(row)
            }

            do {
                try await self.client.pushAddons(
                    session: session,
                    remoteProfileId: remoteProfileId,
                    rows: payload
                )
                print("Nuvio sync pushed \(payload.count) add-on(s) after settings update.")
            } catch {
                print("Nuvio add-on push failed: \(error.localizedDescription)")
            }
        }
    }

    private static func normalizedAddonPreferences(_ preferences: [StreamAddonPreference]) -> [StreamAddonPreference] {
        var seen: Set<String> = []
        return preferences.compactMap { preference -> StreamAddonPreference? in
            guard let url = normalizedAddonURL(preference.url),
                  seen.insert(url).inserted else { return nil }
            return StreamAddonPreference(url: url, enabled: preference.enabled)
        }
    }

    private static func normalizedAddonURL(_ rawValue: String) -> String? {
        CinemetaCatalogRepository.normalizedManifestURL(from: rawValue)?.absoluteString
    }

    private func currentSyncKey() -> String? {
        guard let authManager, let profileViewModel else { return nil }
        guard case let .fullAccount(userId, _) = authManager.authState else { return nil }
        // Read the published array once so both the fallback selection and the
        // remote-index lookup use the same main-actor snapshot.
        let profiles = profileViewModel.profiles
        guard let activeProfile = profileViewModel.activeProfile ?? profiles.first else {
            return nil
        }
        let remoteProfileId = ProfileSyncIndexStore.remoteId(
            for: activeProfile,
            in: profiles
        )
        return "\(userId):\(remoteProfileId)"
    }

    /// The locally seeded Guest that exists before account sync. "Nuvio User"
    /// is also the legitimate default name returned by Nuvio accounts and must
    /// not be mistaken for an unsynced placeholder.
    private static func isPlaceholderProfile(_ profile: Profile) -> Bool {
        if profile.id == "guest" { return true }
        // Compatibility with an older fresh-install seed that used remote slot
        // 1 locally. Synced primary profiles are marked admin, so a real account
        // profile named "Nuvio Guest" is not mistaken for the placeholder.
        let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return profile.id == "1" && !profile.isAdmin && profile.avatarId.isEmpty
            && name == "nuvio guest"
    }

    private static func watchStateSyncEnabled(for profileId: String) -> Bool {
        let defaults = ProfileSettings.store(for: profileId)
        if let value = defaults.object(forKey: SettingsKey.accountSyncWatchState) as? Bool {
            return value
        }
        return true
    }

    /// Removes the persisted local→remote profile-slot bindings. Called on
    /// sign-out so a future account's profiles don't inherit stale mappings.
    static func eraseProfileIndexBindings() {
        ProfileSyncIndexStore.eraseAll()
    }
}

private enum ProfileSyncIndexStore {
    private static let prefix = "nuvio.tv.sync.profileIndex."

    static func eraseAll() {
        let defaults = UserDefaults.standard
        defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(prefix) }
            .forEach { defaults.removeObject(forKey: $0) }
    }

    static func remoteId(for profile: Profile, in profiles: [Profile]) -> Int {
        if let numeric = Int(profile.id), (1...6).contains(numeric) {
            bind(localId: profile.id, remoteId: numeric)
            return numeric
        }

        let key = prefix + profile.id
        let stored = UserDefaults.standard.integer(forKey: key)
        if (1...6).contains(stored) {
            return stored
        }

        let used = Set(profiles.compactMap { candidate -> Int? in
            if candidate.id == profile.id { return nil }
            if let numeric = Int(candidate.id), (1...6).contains(numeric) { return numeric }
            let mapped = UserDefaults.standard.integer(forKey: prefix + candidate.id)
            return (1...6).contains(mapped) ? mapped : nil
        })
        let assigned = (1...6).first(where: { !used.contains($0) }) ?? 1
        bind(localId: profile.id, remoteId: assigned)
        return assigned
    }

    static func localProfiles(from remoteProfiles: [RemoteProfile], preserving localProfiles: [Profile]) -> [Profile] {
        var localByRemoteId: [Int: Profile] = [:]
        localProfiles.forEach { profile in
            // `guest` is a temporary signed-out/install seed, not an account
            // profile identity. Preserving it caused remote profile 1 and all
            // downloaded Home data to remain scoped to `guest` after login.
            guard profile.id != "guest" else { return }
            let remoteId: Int
            if let numeric = Int(profile.id), (1...6).contains(numeric) {
                remoteId = numeric
            } else {
                let mapped = UserDefaults.standard.integer(forKey: prefix + profile.id)
                guard (1...6).contains(mapped) else { return }
                remoteId = mapped
            }
            localByRemoteId[remoteId] = localByRemoteId[remoteId] ?? profile
        }

        return remoteProfiles
            .sorted { $0.profileIndex < $1.profileIndex }
            .map { remote in
                let preservedProfile = localByRemoteId[remote.profileIndex]
                let localId = preservedProfile?.id ?? String(remote.profileIndex)
                bind(localId: localId, remoteId: remote.profileIndex)
                return Profile(
                    id: localId,
                    name: remote.name.isEmpty ? "Nuvio User" : remote.name,
                    isPinProtected: remote.pinEnabled ?? preservedProfile?.isPinProtected ?? false,
                    isAdmin: remote.profileIndex == 1,
                    avatarId: remote.avatarId?.isEmpty == false ? remote.avatarId! : "",
                    usesPrimaryAddons: remote.usesPrimaryAddons,
                    usesPrimaryPlugins: remote.usesPrimaryPlugins
                )
            }
    }

    private static func bind(localId: String, remoteId: Int) {
        let key = prefix + localId
        guard UserDefaults.standard.integer(forKey: key) != remoteId else { return }
        UserDefaults.standard.set(remoteId, forKey: key)
    }
}

/// Stable per-install identity required by current Nuvio mutation RPCs. It lets
/// delta/event sync distinguish this Apple TV's writes from another client.
private enum SyncClientIdentity {
    private static let defaultsKey = "client_instance_id"
    private static let prefix = "nuvio-tv-"

    static func current() -> String {
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: defaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
           isValid(stored) {
            return stored
        }

        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let generated = prefix + suffix
        defaults.set(generated, forKey: defaultsKey)
        return generated
    }

    private static func isValid(_ value: String) -> Bool {
        guard (16...96).contains(value.count) else { return false }
        return value.allSatisfy { character in
            character.isLetter || character.isNumber || character == "-" || character == "_"
        }
    }
}

fileprivate final class NuvioAPIClient {
    private static let pullPageSize = 500
    private static let settingsPlatform = "tv"
    private static let settingsFeature = "tvos_settings"
    /// Shared with Android TV (`ProfileSettingsSyncService` / `DebridSettingsDataStore`).
    private static let debridSettingsFeature = "debrid_settings"

    private let session: URLSession = .shared
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
    private let catalogRepository: CatalogRepository = CinemetaCatalogRepository()
    private var lastPulledProfileSettingsJSON: [String: Any]?

    func pullProfiles(session: AuthSession) async throws -> [RemoteProfile] {
        let rows: LossyRows<RemoteProfile> = try await rpcRows(
            "sync_pull_profiles",
            session: session,
            params: [:]
        )
        if rows.rawCount > 0, rows.elements.isEmpty {
            throw AuthError(message: "The profile response was not in a supported format.")
        }

        // Profile rows intentionally exclude PIN secrets. Android obtains the
        // protection flags from this dedicated RPC, then verifies entered PINs
        // server-side. Mirror that contract so a clean Apple TV install does
        // not silently render every account profile as unlocked.
        do {
            let lockRows: LossyRows<RemoteProfileLockState> = try await rpcRows(
                "sync_pull_profile_locks",
                session: session,
                params: [:]
            )
            let locks = Dictionary(uniqueKeysWithValues: lockRows.elements.map {
                ($0.profileIndex, $0.pinEnabled)
            })
            return rows.elements.map { profile in
                profile.withPinEnabled(locks[profile.profileIndex] ?? profile.pinEnabled)
            }
        } catch {
            print("Nuvio profile lock sync failed; preserving the last known lock state: \(error.localizedDescription)")
            return rows.elements
        }
    }

    func verifyProfilePin(
        session: AuthSession,
        remoteProfileId: Int,
        pin: String
    ) async throws -> RemoteProfilePinVerification {
        let rows: LossyRows<RemoteProfilePinVerification> = try await rpcRows(
            "verify_profile_pin",
            session: session,
            params: [
                "p_profile_id": remoteProfileId,
                "p_pin": pin
            ]
        )
        return rows.elements.first ?? RemoteProfilePinVerification(
            unlocked: false,
            retryAfterSeconds: 0
        )
    }

    func setProfilePin(
        session: AuthSession,
        remoteProfileId: Int,
        pin: String,
        currentPin: String?
    ) async throws {
        var params: [String: Any] = [
            "p_profile_id": remoteProfileId,
            "p_pin": pin
        ]
        if let currentPin, !currentPin.isEmpty {
            params["p_current_pin"] = currentPin
        }
        try await rpcVoid("set_profile_pin", session: session, params: params)
    }

    func clearProfilePin(
        session: AuthSession,
        remoteProfileId: Int,
        currentPin: String?
    ) async throws {
        var params: [String: Any] = ["p_profile_id": remoteProfileId]
        if let currentPin, !currentPin.isEmpty {
            params["p_current_pin"] = currentPin
        }
        try await rpcVoid("clear_profile_pin", session: session, params: params)
    }

    func pullAddons(session: AuthSession, remoteProfileId: Int) async throws -> [RemoteAddon] {
        let rows: LossyRows<RemoteAddon> = try await rest(
            "addons?select=%2A&profile_id=eq.\(remoteProfileId)&order=sort_order",
            session: session
        )
        return rows.elements
    }

    /// Pulls the account's collections blob (`sync_pull_collections`, same
    /// contract as the Android app). Returns the raw `collections_json` array
    /// re-encoded as Data, or nil when the account has none.
    func pullCollections(session: AuthSession, remoteProfileId: Int) async throws -> Data? {
        let data = try await rpcData(
            "sync_pull_collections",
            session: session,
            params: ["p_profile_id": remoteProfileId]
        )
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let blob = rows.first?["collections_json"],
              !(blob is NSNull) else {
            return nil
        }
        // Backend may return a JSON array or a double-encoded JSON string.
        if let array = blob as? [[String: Any]] {
            return try JSONSerialization.data(withJSONObject: array)
        }
        if let text = blob as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != "null" else { return nil }
            if let inner = trimmed.data(using: .utf8),
               let array = try? JSONSerialization.jsonObject(with: inner) as? [[String: Any]] {
                return try JSONSerialization.data(withJSONObject: array)
            }
            // Already a JSON array string — pass through for applyRemote.
            return trimmed.data(using: .utf8)
        }
        return try JSONSerialization.data(withJSONObject: blob)
    }

    func applyAddons(_ addons: [RemoteAddon], localProfileId: String) -> Int {
        let preferences = addons
            .sorted { $0.sortOrder < $1.sortOrder }
            .compactMap { addon -> StreamAddonPreference? in
                guard let url = CinemetaCatalogRepository.normalizedManifestURL(from: addon.url) else { return nil }
                return StreamAddonPreference(url: url.absoluteString, enabled: addon.enabled)
            }

        let defaults = ProfileSettings.store(for: localProfileId)
        CinemetaCatalogRepository.setConfiguredStreamAddonPreferences(preferences, in: defaults)
        return preferences.filter(\.enabled).count
    }

    /// Home-catalog settings platforms in priority order — the shared blob the
    /// mobile/Google-TV apps now write, then the legacy per-platform rows.
    private static let homeCatalogSyncPlatforms = ["home_catalog_shared", "tv", "mobile"]

    /// Pulls the account's Home catalog layout (which catalogs show on Home and
    /// in what order), mirroring Android's `HomeCatalogSettingsSyncService`.
    /// Returns the first platform that has any items, preferring the shared blob.
    func pullHomeCatalogSettings(session: AuthSession, remoteProfileId: Int) async throws -> HomeCatalogSyncPayload? {
        for platform in Self.homeCatalogSyncPlatforms {
            // Each platform is queried independently so one failing (or absent
            // on older backends) can't stop the others from being tried.
            guard let data = try? await rpcData(
                "sync_pull_home_catalog_settings",
                session: session,
                params: ["p_profile_id": remoteProfileId, "p_platform": platform]
            ) else { continue }
            guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let settingsJSON = rows.first?["settings_json"] as? [String: Any] else {
                continue
            }
            let payload = HomeCatalogSyncPayload(dictionary: settingsJSON)
            if !payload.items.isEmpty { return payload }
        }
        return nil
    }

    /// Applies the pulled Home catalog layout: records the add-on catalog order
    /// (so the repository sorts Home's add-on rows to match the account) and the
    /// set of catalogs hidden from Home (so the repository drops them). Catalog
    /// keys use `<addonId>_<type>_<catalogId>`; collection keys use
    /// `collection_<collectionId>` so rows can be ordered alongside catalogs.
    func applyHomeCatalogSettings(_ payload: HomeCatalogSyncPayload, localProfileId: String) {
        let catalogItems = payload.items.filter { !$0.isCollection }
        let collectionItems = payload.items.filter(\.isCollection)

        // Interleave catalogs and collections in the account's saved order so
        // Home can place collection rows among addon catalogs.
        let orderKeys = payload.items
            .sorted { $0.order < $1.order }
            .map { item -> String in
                if item.isCollection {
                    return "collection_\(item.collectionId)"
                }
                return "\(item.addonId)_\(item.type)_\(item.catalogId)"
            }
        let disabledKeys = catalogItems
            .filter { !$0.enabled }
            .map { "\($0.addonId)_\($0.type)_\($0.catalogId)" }
        let disabledCollectionIds = collectionItems
            .filter { !$0.enabled }
            .map(\.collectionId)
            .filter { !$0.isEmpty }

        let defaults = ProfileSettings.store(for: localProfileId)
        if let data = try? JSONEncoder().encode(orderKeys) {
            defaults.set(data, forKey: SettingsKey.homeCatalogSyncedOrder)
        }
        if let data = try? JSONEncoder().encode(disabledKeys) {
            defaults.set(data, forKey: SettingsKey.homeCatalogDisabled)
        }
        if let data = try? JSONEncoder().encode(disabledCollectionIds) {
            defaults.set(data, forKey: SettingsKey.homeCollectionDisabled)
        }
    }

    /// Replaces the profile's collections blob (`sync_push_collections`).
    func pushCollections(session: AuthSession, remoteProfileId: Int, rawCollections: [[String: Any]]) async throws {
        try await rpcVoid(
            "sync_push_collections",
            session: session,
            params: [
                "p_profile_id": remoteProfileId,
                "p_collections_json": rawCollections
            ]
        )
    }

    /// Replaces the profile's addon set (same contract as Android's
    /// `sync_push_addons`): rows carry url, sort_order, enabled, name?.
    func pushAddons(session: AuthSession, remoteProfileId: Int, rows: [[String: Any]]) async throws {
        try await rpcVoid(
            "sync_push_addons",
            session: session,
            params: [
                "p_addons": rows,
                "p_profile_id": remoteProfileId
            ]
        )
    }

    func pushProfiles(session: AuthSession, profiles: [Profile]) async throws {
        let payloads = profiles.prefix(6).map { profile -> [String: Any] in
            var payload: [String: Any] = [
                "profile_index": ProfileSyncIndexStore.remoteId(for: profile, in: profiles),
                "name": profile.name,
                "avatar_color_hex": "#1E88E5",
                "uses_primary_addons": profile.usesPrimaryAddons,
                "uses_primary_plugins": profile.usesPrimaryPlugins
            ]
            // Omitting avatar_id preserves a custom remote avatar. The public
            // API defines an explicit null/empty value as a clear, and tvOS
            // currently has no explicit "remove avatar" action.
            if !profile.avatarId.isEmpty {
                payload["avatar_id"] = profile.avatarId
            }
            return payload
        }
        try await rpcVoid(
            "sync_push_profiles",
            session: session,
            params: [
                "p_client_max_profiles": 6,
                "p_profiles": payloads
            ]
        )
    }

    func pullProfileSettings(
        session: AuthSession,
        remoteProfileId: Int,
        localProfileId: String
    ) async throws -> Bool {
        let raw = try await rpcJSONObject(
            "sync_pull_profile_settings_blob",
            session: session,
            params: [
                "p_profile_id": remoteProfileId,
                "p_platform": Self.settingsPlatform
            ]
        )
        guard let rows = raw as? [[String: Any]],
              let settingsJSON = rows.first?["settings_json"] as? [String: Any] else {
            lastPulledProfileSettingsJSON = nil
            return false
        }
        lastPulledProfileSettingsJSON = settingsJSON
        let features = settingsJSON["features"] as? [String: Any] ?? [:]
        let tvosFeature = features[Self.settingsFeature] as? [String: Any]
        let debridFeature = features[Self.debridSettingsFeature] as? [String: Any]
        guard tvosFeature != nil || debridFeature != nil else {
            return false
        }

        if let tvosFeature {
            importSettings(tvosFeature, localProfileId: localProfileId)
        }
        // Android TV stores debrid keys in a sibling feature on the same "tv" blob.
        importDebridSettings(debridFeature, localProfileId: localProfileId)
        return true
    }

    func pushProfileSettings(
        session: AuthSession,
        remoteProfileId: Int,
        localProfileId: String
    ) async throws {
        // This RPC atomically replaces the complete (user, profile, platform)
        // blob. Merge our namespaced feature into the row we just pulled so
        // Android/other TV feature keys survive a tvOS settings update.
        var settingsJSON = lastPulledProfileSettingsJSON ?? [:]
        var features = settingsJSON["features"] as? [String: Any] ?? [:]
        features[Self.settingsFeature] = exportSettings(localProfileId: localProfileId)
        // Keep Android stream-filter keys; overlay API keys + preferred resolver.
        let existingDebrid = features[Self.debridSettingsFeature] as? [String: Any]
        features[Self.debridSettingsFeature] = exportDebridSettings(
            localProfileId: localProfileId,
            existing: existingDebrid
        )
        settingsJSON["features"] = features
        if settingsJSON["version"] == nil { settingsJSON["version"] = 1 }
        try await rpcVoid(
            "sync_push_profile_settings_blob",
            session: session,
            params: [
                "p_profile_id": remoteProfileId,
                "p_platform": Self.settingsPlatform,
                "p_settings_json": settingsJSON
            ]
        )
    }

    func pullLibrary(session: AuthSession, remoteProfileId: Int) async throws -> [LibraryStoreItem] {
        var allItems: [RemoteLibraryItem] = []
        var offset = 0
        while true {
            let page: LossyRows<RemoteLibraryItem> = try await rpcRows(
                "sync_pull_library",
                session: session,
                params: [
                    "p_profile_id": remoteProfileId,
                    "p_limit": Self.pullPageSize,
                    "p_offset": offset
                ]
            )
            allItems += page.elements
            // Paginate on the server's raw row count, not the decoded count —
            // dropped rows must not end the loop early.
            if page.rawCount < Self.pullPageSize { break }
            offset += Self.pullPageSize
        }
        return allItems.map { remote in
            LibraryStoreItem(
                meta: remote.meta,
                addedAt: Self.date(fromMilliseconds: remote.addedAt)
            )
        }
    }

    func pushLibrary(session: AuthSession, remoteProfileId: Int) async throws {
        let payload = LibraryStore.items().map { item -> [String: Any] in
            var row: [String: Any] = [
                "content_id": item.meta.id,
                "content_type": item.meta.type,
                "name": item.meta.name,
                "poster": Self.jsonValue(item.meta.posterUrl),
                "poster_shape": "POSTER",
                "background": Self.jsonValue(item.meta.backgroundUrl),
                "description": Self.jsonValue(item.meta.description),
                "release_info": Self.jsonValue(item.meta.releaseInfo ?? item.meta.year.map(String.init)),
                "genres": item.meta.genres ?? [],
                "addon_base_url": NSNull(),
                "added_at": Self.milliseconds(from: item.addedAt)
            ]
            if let rating = item.meta.rating {
                row["imdb_rating"] = rating
            }
            return row
        }
        guard !payload.isEmpty else { return }
        try await rpcVoid(
            "sync_push_library",
            session: session,
            params: [
                "p_items": payload,
                "p_profile_id": remoteProfileId
            ]
        )
    }

    func pullWatched(session: AuthSession, remoteProfileId: Int) async throws -> [WatchedStoreItem] {
        var allItems: [RemoteWatchedItem] = []
        var page = 1
        while true {
            let remotePage: LossyRows<RemoteWatchedItem> = try await rpcRows(
                "sync_pull_watched_items",
                session: session,
                params: [
                    "p_profile_id": remoteProfileId,
                    "p_page": page,
                    "p_page_size": Self.pullPageSize
                ]
            )
            allItems += remotePage.elements
            if remotePage.rawCount < Self.pullPageSize { break }
            page += 1
        }
        return allItems.map { remote in
            WatchedStoreItem(
                meta: remote.meta,
                watchedAt: Self.date(fromMilliseconds: remote.watchedAt),
                season: remote.season,
                episode: remote.episode
            )
        }
    }

    func pushWatched(session: AuthSession, remoteProfileId: Int) async throws {
        let payload = WatchedStore.items().map { item -> [String: Any] in
            [
                "content_id": item.meta.id,
                "content_type": item.meta.type,
                "title": item.meta.name,
                "season": item.season.map { $0 as Any } ?? NSNull(),
                "episode": item.episode.map { $0 as Any } ?? NSNull(),
                "watched_at": Self.milliseconds(from: item.watchedAt)
            ]
        }
        if !payload.isEmpty {
            try await rpcVoid(
                "sync_push_watched_items",
                session: session,
                params: [
                    "p_items": payload,
                    "p_profile_id": remoteProfileId
                ]
            )
        }

        // Marks the user removed locally must also leave the server, or the
        // next pull restores the checkmark. Deletes are retried on every push;
        // the tombstone is only cleared once a pull confirms the row is gone
        // (mergeRemote), so a delete that silently no-ops can't resurrect it.
        let tombstones = await MainActor.run { WatchedStore.tombstones() }
        guard !tombstones.isEmpty else { return }
        let keys = tombstones.map { tombstone -> [String: Any] in
            [
                "content_id": tombstone.metaId,
                "season": tombstone.season.map { $0 as Any } ?? NSNull(),
                "episode": tombstone.episode.map { $0 as Any } ?? NSNull()
            ]
        }
        try await rpcVoid(
            "sync_delete_watched_items",
            session: session,
            params: [
                "p_keys": keys,
                "p_profile_id": remoteProfileId
            ]
        )
    }

    func pullWatchProgress(session: AuthSession, remoteProfileId: Int) async throws -> [ContinueWatchingItem] {
        let remote: [RemoteWatchProgress] = try await rpcRows(
            "sync_pull_watch_progress",
            session: session,
            params: [
                "p_profile_id": remoteProfileId
            ]
        ).elements
        var items: [ContinueWatchingItem] = []
        for entry in remote {
            let type = Self.normalizedContentType(entry.contentType)
            let existing = ContinueWatchingStore.item(for: entry.contentId)
            var meta = existing?.meta ?? entry.fallbackMeta(type: type)
            if existing == nil,
               let fetched = try? await catalogRepository.getMetadata(id: entry.contentId, type: type) {
                meta = fetched
            }
            var position = Double(entry.position) / 1000.0
            let duration = Double(entry.duration) / 1000.0
            var season = entry.season ?? existing?.season
            var episode = entry.episode ?? existing?.episode
            guard duration > 0 else { continue }

            // The store drops finished entries on read; the phone instead rolls
            // a finished episode over to the following one, so mirror that here —
            // otherwise a series whose last-played episode ended disappears
            // from Continue Watching after sync.
            let finished = (duration - position) < 60 || (position / duration) >= 0.92

            // Never keep an old cached episode guide for a Next Up item. These
            // are exactly the records that commonly start as "TBA" and then
            // receive a title, overview, and still after release.
            let mayBeUpNext = meta.isSeries && season != nil && episode != nil
                && (finished || position <= 1.5)
            if mayBeUpNext,
               let refreshed = try? await catalogRepository.refreshMetadata(id: entry.contentId, type: type) {
                meta = refreshed
            }

            if finished {
                guard meta.isSeries, let currentSeason = season, let currentEpisode = episode else { continue }
                if meta.videos?.isEmpty != false,
                   let fetched = try? await catalogRepository.refreshMetadata(id: entry.contentId, type: type) {
                    meta = fetched
                }
                guard let next = Self.nextEpisode(after: (currentSeason, currentEpisode), in: meta) else {
                    continue
                }
                season = next.season
                episode = next.episode
                // Keep the finished episode's duration as the runtime estimate
                // and start the rolled-over entry at the top.
                position = 1
            }

            // An episode row at effectively zero progress (including rows older
            // builds pushed for rolled-over entries) presents as "Next Up" too,
            // not as playback with the full runtime remaining.
            let upNext = finished
                || (meta.isSeries && season != nil && episode != nil && position <= 1.5)

            let selectedEpisode = Self.episode(in: meta, season: season, episode: episode)
            let sameEpisodeAsExisting = existing?.season == season && existing?.episode == episode
            let tmdbEpisode = upNext
                ? await EpisodeMetadataEnrichment.fetch(meta: meta, season: season, episode: episode)
                : nil

            items.append(
                ContinueWatchingItem(
                    meta: meta,
                    // A rolled-over entry must not reuse the finished episode's
                    // stream URL; empty forces Home to resolve the new episode.
                    streamUrl: finished ? "" : (existing?.streamUrl ?? ""),
                    position: position,
                    duration: duration,
                    lastWatchedAt: Self.date(fromMilliseconds: entry.lastWatched),
                    season: season,
                    episode: episode,
                    released: tmdbEpisode?.released ?? selectedEpisode?.released
                        ?? (sameEpisodeAsExisting ? existing?.released : nil),
                    episodeTitleOverride: tmdbEpisode?.title ?? Self.nonPlaceholder(selectedEpisode?.title)
                        ?? (sameEpisodeAsExisting ? existing?.episodeTitleOverride : nil),
                    episodeOverviewOverride: tmdbEpisode?.overview ?? Self.nonEmpty(selectedEpisode?.overview)
                        ?? (sameEpisodeAsExisting ? existing?.episodeOverviewOverride : nil),
                    episodeThumbnailOverride: tmdbEpisode?.thumbnail ?? selectedEpisode?.thumbnail
                        ?? (sameEpisodeAsExisting ? existing?.episodeThumbnailOverride : nil),
                    isUpNext: upNext ? true : nil
                )
            )
        }
        return items
    }

    private static func nextEpisode(
        after current: (season: Int, episode: Int),
        in meta: NuvioMeta
    ) -> NuvioVideo? {
        (meta.videos ?? [])
            .filter { $0.season > 0 }
            .sorted { ($0.season, $0.episode) < ($1.season, $1.episode) }
            .first { ($0.season, $0.episode) > (current.season, current.episode) }
    }

    private static func episode(in meta: NuvioMeta, season: Int?, episode: Int?) -> NuvioVideo? {
        guard let season, let episode else { return nil }
        return meta.videos?.first { $0.season == season && $0.episode == episode }
    }

    private static func nonPlaceholder(_ value: String?) -> String? {
        guard let value = nonEmpty(value), value.caseInsensitiveCompare("TBA") != .orderedSame else {
            return nil
        }
        return value
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    func pushWatchProgress(session: AuthSession, remoteProfileId: Int) async throws {
        // Episode entries must use the phone's row conventions — video_id
        // "id:s:e" and progress_key "id_s{s}e{e}" — or each platform upserts
        // its own parallel row for the same episode and they fight over
        // recency/progress on the other clients.
        var staleSeriesKeys: [String] = []
        let payload = ContinueWatchingStore.items().compactMap { item -> [String: Any]? in
            // "Next Up" entries are presentation, not playback — pushing them
            // would create phantom just-started rows on the other clients. The
            // finished previous-episode row already carries the signal, so
            // retire any phantom this build (or an older one) wrote earlier.
            if item.isUpNextEntry {
                if let season = item.season, let episode = item.episode {
                    staleSeriesKeys.append("\(item.meta.id)_s\(season)e\(episode)")
                }
                staleSeriesKeys.append(item.meta.id)
                return nil
            }
            let videoId: String
            let progressKey: String
            if let season = item.season, let episode = item.episode {
                videoId = "\(item.meta.id):\(season):\(episode)"
                progressKey = "\(item.meta.id)_s\(season)e\(episode)"
                staleSeriesKeys.append(item.meta.id)
            } else {
                videoId = item.meta.id
                progressKey = item.meta.id
            }
            return [
                "content_id": item.meta.id,
                "content_type": item.meta.type,
                "video_id": videoId,
                "season": item.season.map { $0 as Any } ?? NSNull(),
                "episode": item.episode.map { $0 as Any } ?? NSNull(),
                "position": Int64(item.position * 1000),
                "duration": Int64(item.duration * 1000),
                "last_watched": Self.milliseconds(from: item.lastWatchedAt),
                "progress_key": progressKey
            ]
        }
        if !payload.isEmpty {
            try await rpcVoid(
                "sync_push_watch_progress",
                session: session,
                params: [
                    "p_entries": payload,
                    "p_profile_id": remoteProfileId
                ]
            )
        }

        // Older builds pushed series episodes under the bare series id; those
        // rows linger as duplicates on other clients, so retire them.
        if !staleSeriesKeys.isEmpty {
            try? await rpcVoid(
                "sync_delete_watch_progress",
                session: session,
                params: [
                    "p_keys": staleSeriesKeys,
                    "p_profile_id": remoteProfileId
                ]
            )
        }
    }

    private func rpcRows<T: Decodable>(
        _ name: String,
        session authSession: AuthSession,
        params: [String: Any]
    ) async throws -> LossyRows<T> {
        let data = try await rpcData(name, session: authSession, params: params)
        return try decoder.decode(LossyRows<T>.self, from: data)
    }

    private func rpcVoid(
        _ name: String,
        session authSession: AuthSession,
        params: [String: Any]
    ) async throws {
        var resolvedParams = params
        if name.hasPrefix("sync_push_") || name.hasPrefix("sync_delete_") {
            resolvedParams["p_origin_client_id"] = SyncClientIdentity.current()
        }
        _ = try await rpcData(name, session: authSession, params: resolvedParams)
    }

    private func rpcJSONObject(
        _ name: String,
        session authSession: AuthSession,
        params: [String: Any]
    ) async throws -> Any {
        let data = try await rpcData(name, session: authSession, params: params)
        return try JSONSerialization.jsonObject(with: data)
    }

    private func rest<T: Decodable>(
        _ path: String,
        session authSession: AuthSession
    ) async throws -> T {
        guard AuthConfig.isConfigured else {
            throw AuthError(message: "Account backend is not configured.")
        }
        guard let url = URL(string: "\(AuthConfig.normalizedAPIBaseURL)/rest/v1/\(path)") else {
            throw AuthError(message: "Invalid backend URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(AuthConfig.apiKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(authSession.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AuthError(message: "No response from server")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AuthError(
                message: Self.serverErrorMessage(data: data, status: http.statusCode),
                statusCode: http.statusCode
            )
        }
        return try decoder.decode(T.self, from: data)
    }

    private func rpcData(
        _ name: String,
        session authSession: AuthSession,
        params: [String: Any]
    ) async throws -> Data {
        guard AuthConfig.isConfigured else {
            throw AuthError(message: "Account backend is not configured.")
        }
        guard let url = URL(string: "\(AuthConfig.normalizedAPIBaseURL)/rest/v1/rpc/\(name)") else {
            throw AuthError(message: "Invalid backend URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(AuthConfig.apiKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(authSession.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: params)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AuthError(message: "No response from server")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AuthError(
                message: Self.serverErrorMessage(data: data, status: http.statusCode),
                statusCode: http.statusCode
            )
        }
        if data.isEmpty { return Data("null".utf8) }
        return data
    }

    private func exportSettings(localProfileId: String) -> [String: Any] {
        let defaults = ProfileSettings.store(for: localProfileId)
        var exported: [String: Any] = [:]
        SettingsKey.all.forEach { key in
            // Sync policy is device-local. Exporting it lets a temporary test
            // or another TV disable account progress pulls everywhere.
            guard key != SettingsKey.accountSyncWatchState else { return }
            guard let value = defaults.object(forKey: key),
                  let encoded = Self.encodeSettingValue(value) else {
                return
            }
            exported[key] = encoded
        }
        return exported
    }

    private func importSettings(_ remote: [String: Any], localProfileId: String) {
        let defaults = ProfileSettings.store(for: localProfileId)
        SettingsKey.all.forEach { key in
            guard key != SettingsKey.accountSyncWatchState else { return }
            guard let encoded = remote[key] as? [String: Any],
                  let value = Self.decodeSettingValue(encoded) else {
                return
            }
            defaults.set(value, forKey: key)
        }

        // Older clients sync only the legacy primary/secondary/tertiary keys.
        // If such a payload supplies a primary value, make that legacy snapshot
        // authoritative and clear omitted lower slots instead of retaining stale
        // local choices that could make System unexpectedly filter languages.
        if remote[SettingsKey.subtitleLanguages] == nil,
           remote[SettingsKey.subtitleLanguage] != nil {
            defaults.removeObject(forKey: SettingsKey.subtitleLanguages)
            if remote[SettingsKey.subtitleLanguageSecondary] == nil {
                defaults.set("None", forKey: SettingsKey.subtitleLanguageSecondary)
            }
            if remote[SettingsKey.subtitleLanguageTertiary] == nil {
                defaults.set("None", forKey: SettingsKey.subtitleLanguageTertiary)
            }
        }
    }

    // MARK: - Android-compatible debrid_settings feature

    /// Preference names written by Android TV `DebridSettingsDataStore` (and
    /// compose mobile variants with a `debrid_` prefix).
    private enum AndroidDebridKey {
        static let torbox = "torbox_api_key"
        static let premiumize = "premiumize_api_key"
        static let realDebrid = "real_debrid_api_key"
        static let preferred = "preferred_resolver_provider_id"
        static let enabled = "debrid_enabled"
        static let cloudLibrary = "cloud_library_enabled"

        // Compose / iOS KMP export keys (platform "mobile", but may appear).
        static let torboxPrefixed = "debrid_torbox_api_key"
        static let premiumizePrefixed = "debrid_premiumize_api_key"
        static let realDebridPrefixed = "debrid_real_debrid_api_key"
        static let preferredPrefixed = "debrid_preferred_resolver_provider_id"
    }

    private func exportDebridSettings(
        localProfileId: String,
        existing: [String: Any]?
    ) -> [String: Any] {
        let defaults = ProfileSettings.store(for: localProfileId)
        var feature = existing ?? [:]

        func putString(_ key: String, _ value: String) {
            feature[key] = Self.encodeSettingValue(value)
        }
        func putBool(_ key: String, _ value: Bool) {
            feature[key] = Self.encodeSettingValue(value)
        }

        let torbox = (defaults.string(forKey: SettingsKey.torboxAccessToken) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let premiumize = (defaults.string(forKey: SettingsKey.premiumizeAccessToken) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let realDebrid = (defaults.string(forKey: SettingsKey.realDebridAccessToken) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        putString(AndroidDebridKey.torbox, torbox)
        putString(AndroidDebridKey.premiumize, premiumize)
        putString(AndroidDebridKey.realDebrid, realDebrid)

        let selected = DebridProviderKind(settingsValue: defaults.string(forKey: SettingsKey.debridProvider))
        let preferredId = selected.androidProviderId
            ?? (torbox.isEmpty ? nil : "torbox")
            ?? (premiumize.isEmpty ? nil : "premiumize")
            ?? (realDebrid.isEmpty ? nil : "realdebrid")
            ?? ""
        putString(AndroidDebridKey.preferred, preferredId)

        let anyKey = !torbox.isEmpty || !premiumize.isEmpty || !realDebrid.isEmpty
        putBool(AndroidDebridKey.enabled, anyKey)
        // Preserve Android's cloud toggle when present; default on when we have keys.
        if feature[AndroidDebridKey.cloudLibrary] == nil {
            putBool(AndroidDebridKey.cloudLibrary, anyKey)
        }

        return feature
    }

    private func importDebridSettings(_ remote: [String: Any]?, localProfileId: String) {
        guard let remote, !remote.isEmpty else { return }
        let defaults = ProfileSettings.store(for: localProfileId)

        func stringValue(_ keys: [String]) -> String? {
            for key in keys {
                if let encoded = remote[key] as? [String: Any],
                   let value = Self.decodeSettingValue(encoded) as? String {
                    return value
                }
                // Tolerate raw strings if an older client wrote them.
                if let value = remote[key] as? String {
                    return value
                }
            }
            return nil
        }

        if let torbox = stringValue([AndroidDebridKey.torbox, AndroidDebridKey.torboxPrefixed]) {
            defaults.set(torbox, forKey: SettingsKey.torboxAccessToken)
        }
        if let premiumize = stringValue([AndroidDebridKey.premiumize, AndroidDebridKey.premiumizePrefixed]) {
            defaults.set(premiumize, forKey: SettingsKey.premiumizeAccessToken)
        }
        if let realDebrid = stringValue([AndroidDebridKey.realDebrid, AndroidDebridKey.realDebridPrefixed]) {
            defaults.set(realDebrid, forKey: SettingsKey.realDebridAccessToken)
        }

        let preferredRaw = stringValue([AndroidDebridKey.preferred, AndroidDebridKey.preferredPrefixed])
        var selected = DebridProviderKind(androidProviderId: preferredRaw)

        // If preferred is missing/empty, pick the first configured provider.
        if selected == .none {
            let torbox = (defaults.string(forKey: SettingsKey.torboxAccessToken) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let premiumize = (defaults.string(forKey: SettingsKey.premiumizeAccessToken) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let realDebrid = (defaults.string(forKey: SettingsKey.realDebridAccessToken) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !torbox.isEmpty {
                selected = .torbox
            } else if !premiumize.isEmpty {
                selected = .premiumize
            } else if !realDebrid.isEmpty {
                selected = .realDebrid
            }
        }

        if selected != .none {
            defaults.set(selected.rawValue, forKey: SettingsKey.debridProvider)
            let token = DebridCredentials.token(for: selected, store: defaults)
            defaults.set(token, forKey: SettingsKey.debridApiKey)
        }
    }

    private static func encodeSettingValue(_ value: Any) -> [String: Any]? {
        if let string = value as? String {
            return ["type": "string", "value": string]
        }
        if let bool = value as? Bool {
            return ["type": "boolean", "value": bool]
        }
        if let int = value as? Int {
            return ["type": "int", "value": int]
        }
        if let double = value as? Double {
            return ["type": "double", "value": double]
        }
        if let float = value as? Float {
            return ["type": "float", "value": float]
        }
        return nil
    }

    private static func decodeSettingValue(_ encoded: [String: Any]) -> Any? {
        guard let type = encoded["type"] as? String else { return nil }
        let value = encoded["value"]
        switch type {
        case "string":
            return value as? String
        case "boolean":
            return value as? Bool
        case "int":
            if let int = value as? Int { return int }
            return (value as? NSNumber)?.intValue
        case "long":
            if let int = value as? Int { return int }
            return (value as? NSNumber)?.intValue
        case "float", "double":
            if let double = value as? Double { return double }
            return (value as? NSNumber)?.doubleValue
        default:
            return nil
        }
    }

    private static func milliseconds(from date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1000)
    }

    private static func date(fromMilliseconds milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000.0)
    }

    private static func jsonValue(_ value: Any?) -> Any {
        value ?? NSNull()
    }

    fileprivate static func normalizedContentType(_ type: String) -> String {
        type.lowercased() == "tv" ? "series" : type
    }

    private static func serverErrorMessage(data: Data, status: Int) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["error_description", "msg", "message", "error", "error_code"] {
                if let message = obj[key] as? String, !message.isEmpty {
                    return message
                }
            }
        }
        return "Sync request failed (\(status))"
    }
}

/// Optional episode-level enrichment. This uses the same TMDB integration the
/// Details screen already exposes, and is deliberately a no-op until the user
/// has enabled it and supplied their own key.
private enum EpisodeMetadataEnrichment {
    struct Episode {
        let title: String?
        let overview: String?
        let thumbnail: String?
        let released: String?
    }

    static func fetch(meta: NuvioMeta, season: Int?, episode: Int?) async -> Episode? {
        guard meta.isSeries,
              let tmdbId = meta.tmdbId,
              let season,
              let episode,
              ProfileSettings.current.bool(forKey: SettingsKey.tmdbEnabled) else {
            return nil
        }

        let apiKey = ProfileSettings.current.string(forKey: SettingsKey.tmdbApiKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !apiKey.isEmpty else { return nil }

        var components = URLComponents(
            string: "https://api.themoviedb.org/3/tv/\(tmdbId)/season/\(season)/episode/\(episode)"
        )
        components?.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "language", value: "en-US")
        ]
        guard let url = components?.url else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                return nil
            }
            let decoded = try JSONDecoder().decode(TmdbEpisodeResponse.self, from: data)
            return Episode(
                title: nonEmpty(decoded.name),
                overview: nonEmpty(decoded.overview),
                thumbnail: decoded.stillPath.map { "https://image.tmdb.org/t/p/w780\($0)" },
                released: nonEmpty(decoded.airDate)
            )
        } catch {
            return nil
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

private struct TmdbEpisodeResponse: Decodable {
    let name: String?
    let overview: String?
    let stillPath: String?
    let airDate: String?

    enum CodingKeys: String, CodingKey {
        case name, overview
        case stillPath = "still_path"
        case airDate = "air_date"
    }
}

/// Decodes every row it can and keeps the server's raw row count, so a single
/// malformed row drops just that row instead of failing the whole page — and
/// pagination can still advance by the true count.
private struct LossyRows<Element: Decodable>: Decodable {
    var elements: [Element] = []
    var rawCount = 0

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        while !container.isAtEnd {
            rawCount += 1
            if let element = try? container.decode(Element.self) {
                elements.append(element)
                continue
            }
            // Consume the bad row so the container advances; bail if nothing
            // matches rather than spin on the same index forever.
            if (try? container.decode(DiscardedRow.self)) == nil,
               (try? container.decode([DiscardedRow].self)) == nil,
               (try? container.decode(String.self)) == nil,
               (try? container.decode(Double.self)) == nil,
               (try? container.decode(Bool.self)) == nil,
               (try? container.decodeNil()) != true {
                break
            }
        }
    }

    private struct DiscardedRow: Decodable {}
}

private struct RemoteProfile: Decodable {
    let profileIndex: Int
    let name: String
    let avatarId: String?
    let usesPrimaryAddons: Bool
    let usesPrimaryPlugins: Bool
    let pinEnabled: Bool?

    enum CodingKeys: String, CodingKey {
        case profileIndex
        case name
        case avatarId
        case usesPrimaryAddons
        case usesPrimaryPlugins
        case pinEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profileIndex = try container.decode(Int.self, forKey: .profileIndex)
        name = (try? container.decode(String.self, forKey: .name)) ?? ""
        avatarId = try? container.decodeIfPresent(String.self, forKey: .avatarId)
        usesPrimaryAddons = (try? container.decode(Bool.self, forKey: .usesPrimaryAddons)) ?? false
        usesPrimaryPlugins = (try? container.decode(Bool.self, forKey: .usesPrimaryPlugins)) ?? false
        pinEnabled = try? container.decodeIfPresent(Bool.self, forKey: .pinEnabled)
    }

    private init(copying profile: RemoteProfile, pinEnabled: Bool?) {
        profileIndex = profile.profileIndex
        name = profile.name
        avatarId = profile.avatarId
        usesPrimaryAddons = profile.usesPrimaryAddons
        usesPrimaryPlugins = profile.usesPrimaryPlugins
        self.pinEnabled = pinEnabled
    }

    func withPinEnabled(_ pinEnabled: Bool?) -> RemoteProfile {
        RemoteProfile(copying: self, pinEnabled: pinEnabled)
    }
}

private struct RemoteProfileLockState: Decodable {
    let profileIndex: Int
    let pinEnabled: Bool
}

private struct RemoteProfilePinVerification: Decodable {
    let unlocked: Bool
    let retryAfterSeconds: Int
}

/// The account's Home catalog layout blob (`sync_pull_home_catalog_settings`).
/// Parsed leniently from the RPC's `settings_json` so unknown fields and shape
/// drift can't abort the pull.
struct HomeCatalogSyncPayload {
    let items: [HomeCatalogSyncItem]

    init(dictionary: [String: Any]) {
        let rawItems = dictionary["items"] as? [[String: Any]] ?? []
        self.items = rawItems.compactMap(HomeCatalogSyncItem.init(dictionary:))
    }
}

struct HomeCatalogSyncItem {
    let addonId: String
    let type: String
    let catalogId: String
    let enabled: Bool
    let order: Int
    let isCollection: Bool
    let collectionId: String

    init?(dictionary: [String: Any]) {
        self.addonId = dictionary["addon_id"] as? String ?? ""
        self.type = dictionary["type"] as? String ?? ""
        self.catalogId = dictionary["catalog_id"] as? String ?? ""
        self.enabled = Self.boolValue(dictionary["enabled"], default: true)
        self.order = (dictionary["order"] as? NSNumber)?.intValue
            ?? (dictionary["order"] as? Int)
            ?? 0
        self.isCollection = Self.boolValue(dictionary["is_collection"], default: false)
        self.collectionId = dictionary["collection_id"] as? String ?? ""
        // A non-collection item is only meaningful with an add-on catalog key.
        // Collection rows need a collection id.
        if isCollection {
            if collectionId.isEmpty { return nil }
        } else if addonId.isEmpty || catalogId.isEmpty {
            return nil
        }
    }

    /// JSONSerialization often surfaces booleans as NSNumber; accept both.
    private static func boolValue(_ raw: Any?, default defaultValue: Bool) -> Bool {
        if let value = raw as? Bool { return value }
        if let number = raw as? NSNumber { return number.boolValue }
        return defaultValue
    }
}

private struct RemoteAddon: Decodable {
    let url: String
    let name: String?
    let enabled: Bool
    let sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case url
        case name
        case enabled
        case sortOrder
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = (try? container.decode(String.self, forKey: .url)) ?? ""
        name = try? container.decodeIfPresent(String.self, forKey: .name)
        enabled = (try? container.decode(Bool.self, forKey: .enabled)) ?? true
        sortOrder = (try? container.decode(Int.self, forKey: .sortOrder)) ?? 0
    }
}

private struct RemoteLibraryItem: Decodable {
    let contentId: String
    let contentType: String
    let name: String
    let poster: String?
    let background: String?
    let description: String?
    let releaseInfo: String?
    let imdbRating: Double?
    let genres: [String]
    let addedAt: Int64

    var meta: NuvioMeta {
        let parsedYear = releaseInfo.flatMap { Int(String($0.prefix(4))) }
        return NuvioMeta(
            id: contentId,
            name: name.isEmpty ? contentId : name,
            description: description,
            posterUrl: poster,
            backgroundUrl: background,
            logoUrl: nil,
            imdbId: nil,
            tmdbId: nil,
            type: NuvioAPIClient.normalizedContentType(contentType),
            year: parsedYear,
            genres: genres,
            rating: imdbRating,
            releaseInfo: releaseInfo,
            runtime: nil,
            cast: nil,
            director: nil,
            writer: nil,
            certification: nil,
            country: nil,
            released: nil
        )
    }

    enum CodingKeys: String, CodingKey {
        case contentId
        case contentType
        case name
        case poster
        case background
        case description
        case releaseInfo
        case imdbRating
        case genres
        case addedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        contentId = try container.decode(String.self, forKey: .contentId)
        contentType = try container.decode(String.self, forKey: .contentType)
        name = (try? container.decode(String.self, forKey: .name)) ?? ""
        poster = try? container.decodeIfPresent(String.self, forKey: .poster)
        background = try? container.decodeIfPresent(String.self, forKey: .background)
        description = try? container.decodeIfPresent(String.self, forKey: .description)
        releaseInfo = try? container.decodeIfPresent(String.self, forKey: .releaseInfo)
        imdbRating = try? container.decodeIfPresent(Double.self, forKey: .imdbRating)
        genres = (try? container.decode([String].self, forKey: .genres)) ?? []
        addedAt = (try? container.decode(Int64.self, forKey: .addedAt)) ?? 0
    }
}

private struct RemoteWatchedItem: Decodable {
    let contentId: String
    let contentType: String
    let title: String
    let season: Int?
    let episode: Int?
    let watchedAt: Int64

    var meta: NuvioMeta {
        NuvioMeta(
            id: contentId,
            name: title.isEmpty ? contentId : title,
            description: nil,
            posterUrl: nil,
            backgroundUrl: nil,
            logoUrl: nil,
            imdbId: nil,
            tmdbId: nil,
            type: NuvioAPIClient.normalizedContentType(contentType),
            year: nil,
            genres: nil,
            rating: nil,
            releaseInfo: nil,
            runtime: nil,
            cast: nil,
            director: nil,
            writer: nil,
            certification: nil,
            country: nil,
            released: nil
        )
    }

    enum CodingKeys: String, CodingKey {
        case contentId
        case contentType
        case title
        case season
        case episode
        case watchedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        contentId = try container.decode(String.self, forKey: .contentId)
        contentType = try container.decode(String.self, forKey: .contentType)
        title = (try? container.decode(String.self, forKey: .title)) ?? ""
        season = try? container.decodeIfPresent(Int.self, forKey: .season)
        episode = try? container.decodeIfPresent(Int.self, forKey: .episode)
        watchedAt = (try? container.decode(Int64.self, forKey: .watchedAt)) ?? 0
    }
}

private struct RemoteWatchProgress: Decodable {
    let contentId: String
    let contentType: String
    let videoId: String
    let season: Int?
    let episode: Int?
    let position: Int64
    let duration: Int64
    let lastWatched: Int64
    let progressKey: String

    func fallbackMeta(type: String) -> NuvioMeta {
        NuvioMeta(
            id: contentId,
            name: contentId,
            description: nil,
            posterUrl: nil,
            backgroundUrl: nil,
            logoUrl: nil,
            imdbId: nil,
            tmdbId: nil,
            type: type,
            year: nil,
            genres: nil,
            rating: nil,
            releaseInfo: nil,
            runtime: nil,
            cast: nil,
            director: nil,
            writer: nil,
            certification: nil,
            country: nil,
            released: nil
        )
    }

    enum CodingKeys: String, CodingKey {
        case contentId
        case contentType
        case videoId
        case season
        case episode
        case position
        case duration
        case lastWatched
        case progressKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        contentId = try container.decode(String.self, forKey: .contentId)
        contentType = try container.decode(String.self, forKey: .contentType)
        videoId = (try? container.decode(String.self, forKey: .videoId)) ?? contentId
        season = try? container.decodeIfPresent(Int.self, forKey: .season)
        episode = try? container.decodeIfPresent(Int.self, forKey: .episode)
        position = (try? container.decode(Int64.self, forKey: .position)) ?? 0
        duration = (try? container.decode(Int64.self, forKey: .duration)) ?? 0
        lastWatched = (try? container.decode(Int64.self, forKey: .lastWatched)) ?? 0
        progressKey = (try? container.decode(String.self, forKey: .progressKey)) ?? contentId
    }
}
