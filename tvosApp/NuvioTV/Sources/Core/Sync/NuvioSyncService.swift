//
//  NuvioSyncService.swift
//  NuvioTV
//
//  Nuvio API profile, settings, library, watched, and progress sync for tvOS.
//  Mirrors the Android TV app's account contract over URLSession.
//

import Combine
import Foundation
import UIKit

@MainActor
final class NuvioSyncManager: ObservableObject {
    /// Posted by the Settings add-on list after an order/enabled-state change.
    /// The object is `[StreamAddonPreference]`, with `[String]` accepted for the
    /// old reorder-only path.
    nonisolated static let addonOrderChangedNotification = Notification.Name("nuvio.tv.addons.orderChanged")
    /// Posted after an account pull has applied every profile-scoped Home input.
    /// Revision counters publish individual changes, while this completion
    /// signal guarantees one final catalog rebuild on slower physical devices.
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
    /// Persistent Home input versions. Unlike a one-shot notification, the
    /// latest values are still visible when Home mounts after account sync.
    @Published private(set) var homeCatalogRevision: UInt = 0
    @Published private(set) var homeCollectionsRevision: UInt = 0

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
    private var homeCatalogPushTask: Task<Void, Never>?
    private var profileSelectionRefreshTask: Task<Void, Never>?
    private var completedInitialPullKeys: Set<String> = []
    /// When each account+profile last finished a pull, so a screen re-entry can
    /// tell "the user came back" from "the data is old".
    private var lastCompletedPullAt: [String: Date] = [:]
    /// Mirrors the Android client's force-resync floor. Short enough that a
    /// change made on a phone shows up on the next screen change, long enough
    /// that walking between tabs costs nothing.
    private static let minimumRefreshInterval: TimeInterval = 30
    /// Which account+profile the in-flight pull belongs to, so a request for the
    /// same one can queue while a request for a different one still preempts it.
    private var activePullKey: String?
    /// A refresh that arrived while a pull was running, replayed on completion.
    private var pendingResyncRequested = false
    private var automaticAccountPullRetryCount = 0
    /// The backend uses this heartbeat to show the Apple TV under the account's
    /// linked devices. Keep it well below the server's stale-device window,
    /// without adding a request to every foreground refresh.
    private var lastDeviceRegistrationAt: Date?
    private static let deviceRegistrationInterval: TimeInterval = 15 * 60
    /// Identifies the pull that currently owns `pullTask` and the post-login
    /// loading gate. A cancelled pull can unwind after its replacement starts;
    /// without an ownership token, that stale task can reveal the local Guest
    /// while the replacement is still downloading the account.
    private var pullGeneration: UInt = 0
    private var observedAuthUserId: String?
    private var observedActiveProfileId: String?
    private var isApplyingRemote = false
    /// Profile-list application can publish `activeProfile` synchronously. Keep
    /// that internal refresh distinct from a real user switch while the rest of
    /// a (potentially long) remote-data pull is in progress.
    private var isApplyingRemoteProfiles = false
    private var didAttach = false

    deinit {
        pullTask?.cancel()
        pushTask?.cancel()
        homeCatalogPushTask?.cancel()
        profileSelectionRefreshTask?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// The attached manager, for the few callers that need to reach sync from
    /// outside the view tree. Weak so the root owning it stays authoritative.
    @MainActor static private(set) weak var current: NuvioSyncManager?

    func attach(authManager: AuthManager, profileViewModel: ProfileViewModel) {
        // `onAppear` may run again after SwiftUI rebuilds the root. Refresh the
        // dependencies even though notification observers only attach once.
        self.authManager = authManager
        self.profileViewModel = profileViewModel
        Self.current = self
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
            forName: StreamBadgeSettingsStore.changedNotification,
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
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.homeCatalogRevision &+= 1
                self.pushAddonPreferences(preferences)
            }
        })
        observers.append(center.addObserver(
            forName: CollectionsStore.changedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.homeCollectionsRevision &+= 1
            }
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

    /// Bumps the Home catalog input version after a local change to which rows
    /// Home shows (Settings → Home Catalogs). Home keys its load on this
    /// revision, so a hidden row disappears — and a restored one is fetched
    /// again — without waiting for an account pull to publish the same change.
    func noteHomeCatalogSettingsChangedLocally() {
        homeCatalogRevision &+= 1
        scheduleHomeCatalogPush()
    }

    /// Debounces Home layout edits so moving a row several times only sends the
    /// final order. The initial account pull must finish first; otherwise a
    /// local snapshot could replace remote settings that tvOS has not loaded.
    private func scheduleHomeCatalogPush() {
        guard !isApplyingRemote,
              AuthConfig.isConfigured,
              authManager?.isAuthenticated == true,
              let key = currentSyncKey(),
              completedInitialPullKeys.contains(key) else { return }

        homeCatalogPushTask?.cancel()
        homeCatalogPushTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 500_000_000)
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  let key = self.currentSyncKey(),
                  self.completedInitialPullKeys.contains(key) else { return }
            await self.pushHomeCatalogSettings()
        }
    }

    private func pushHomeCatalogSettings() async {
        guard let target = await currentSyncTarget(),
              let key = currentSyncKey(),
              completedInitialPullKeys.contains(key) else { return }
        let items = TVHomeCatalogOrder.syncItems()
        do {
            try ensureStillSyncing()
            try await client.pushHomeCatalogSettings(
                session: target.session,
                remoteProfileId: target.remoteProfileId,
                items: items
            )
            Self.catalogSettingsSyncDiagnostic = "pushed \(items.count) item(s)"
        } catch is CancellationError {
            return
        } catch {
            print("Nuvio home catalog settings push failed: \(error.localizedDescription)")
        }
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
            if !isSameAccount {
                lastDeviceRegistrationAt = nil
            }
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
            homeCatalogPushTask?.cancel()
            profileSelectionRefreshTask?.cancel()
            profileSelectionRefreshTask = nil
            completedInitialPullKeys.removeAll()
            lastCompletedPullAt.removeAll()
            activePullKey = nil
            pendingResyncRequested = false
            observedAuthUserId = nil
            observedActiveProfileId = nil
            lastDeviceRegistrationAt = nil
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

    /// Re-reads the account so changes made on another device land here.
    ///
    /// Called when tvOS returns to the foreground, and whenever Home re-reads
    /// Continue Watching. Home renders that row straight from the local ledger
    /// when Nuvio Sync owns progress — unlike Trakt and Simkl, which re-fetch
    /// from the provider on every refresh — so without this the row showed
    /// whatever the last pull left behind, and a title deleted elsewhere stayed
    /// until the app was backgrounded or the profile switched.
    ///
    /// Startup already owns its initial pull, so only refresh an account/profile
    /// whose bootstrap completed, and never replace an in-flight pull.
    ///
    /// Rate-limited per account+profile, matching the Android client's
    /// `FORCE_RESYNC_MIN_INTERVAL_MS`. Returning to Home is a hint that the row
    /// may be stale, not an instruction to re-download the account: every
    /// landing used to pull profiles, settings, library, watched and progress
    /// again, which is seconds of work for data that had not changed. Inside the
    /// window the row keeps rendering from the local ledger, which a local edit
    /// updates immediately anyway.
    func refreshAccountIfIdle() {
        guard let key = currentSyncKey(), completedInitialPullKeys.contains(key) else { return }
        guard pullTask == nil else { return }
        if let lastPulledAt = lastCompletedPullAt[key],
           Date().timeIntervalSince(lastPulledAt) < Self.minimumRefreshInterval {
            return
        }
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
        guard profile != nil, !isApplyingRemoteProfiles else { return }
        // A delayed snapshot captured the previous profile and must not resume
        // by reading the newly-active profile's global stores.
        pushTask?.cancel()
        homeCatalogPushTask?.cancel()

        // A profile the account has already pulled this session has all its data
        // on disk, so switching to it is a local operation — the Android client
        // does no network work on a switch at all. Only a profile this session
        // has never seen needs its snapshot before it can render; everything
        // else refreshes on the ordinary schedule, off the critical path.
        if let key = currentSyncKey(), completedInitialPullKeys.contains(key) {
            refreshAccountIfIdle()
            return
        }
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
                self.isApplyingRemoteProfiles = true
                let applied = self.profileViewModel?.applyRemoteProfiles(merged) == true
                self.isApplyingRemoteProfiles = false
                self.isApplyingRemote = false
                guard applied else {
                    throw AuthError(message: "The saved profiles could not be applied on this Apple TV.")
                }
                self.profileSyncError = nil
                print("Nuvio sync saved and confirmed \(remoteProfiles.count) profile(s).")
            } catch is CancellationError {
                self.isApplyingRemoteProfiles = false
                self.isApplyingRemote = false
            } catch {
                self.isApplyingRemoteProfiles = false
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
                && remote.effectiveAvatarValue == local.avatarId
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
                isApplyingRemoteProfiles = true
                let applied = profileViewModel.applyRemoteProfiles(merged)
                observedActiveProfileId = profileViewModel.activeProfile?.id
                isApplyingRemoteProfiles = false
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

        isApplyingRemoteProfiles = false
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

        // A forced pull for the account+profile already being pulled queues
        // instead of replacing it, mirroring the Android client. Cancelling
        // mid-pull tears down a sync that may be between a network read and its
        // local apply, and the replacement then re-downloads what the cancelled
        // one had already fetched. A pull for a *different* key still cancels:
        // that data belongs to a profile the user has left.
        if force, pullTask != nil, activePullKey == currentSyncKey() {
            pendingResyncRequested = true
            return
        }

        pullGeneration &+= 1
        let generation = pullGeneration
        automaticAccountPullRetryCount = 0
        pullTask?.cancel()
        activePullKey = currentSyncKey()
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
        activePullKey = nil
        isPullingAccountProfiles = false
        // A request that arrived mid-pull was deferred rather than dropped, so
        // honour it now — but through the same floor, so a burst of screen
        // changes still collapses into one refresh.
        if pendingResyncRequested {
            pendingResyncRequested = false
            refreshAccountIfIdle()
        }
    }

    /// Session and remote profile id for a one-off account write, or nil when the
    /// account is not in a state to accept one.
    private func currentSyncTarget() async -> (session: AuthSession, remoteProfileId: Int)? {
        guard AuthConfig.isConfigured,
              let authManager,
              let profileViewModel,
              let session = await authManager.validSessionForSync(),
              let activeProfile = profileViewModel.activeProfile ?? profileViewModel.profiles.first else {
            return nil
        }
        return (
            session,
            ProfileSyncIndexStore.remoteId(for: activeProfile, in: profileViewModel.profiles)
        )
    }

    /// Uploads pending watch progress now instead of waiting for the debounced
    /// push. Returns whether the upload completed.
    @discardableResult
    func pushWatchProgressNow() async -> Bool {
        guard let target = await currentSyncTarget() else { return false }
        // Same ownership rule as the debounced push — this path skips
        // `pushLocalSnapshots` entirely, so it needs the gate of its own.
        if let profileId = profileViewModel?.activeProfile?.id,
           !Self.ownsWatchState(for: profileId) {
            return false
        }
        do {
            try await client.pushWatchProgress(
                session: target.session,
                remoteProfileId: target.remoteProfileId
            )
            return true
        } catch {
            print("Nuvio watch progress push failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Retires specific progress rows on the account.
    ///
    /// Deleting locally is not enough once rows have been uploaded — the next
    /// pull would simply restore them, so anything that removes synced progress
    /// has to retire it server-side too.
    @discardableResult
    func deleteRemoteWatchProgress(keys: [String]) async -> Bool {
        guard !keys.isEmpty else { return true }
        guard let target = await currentSyncTarget() else { return false }
        do {
            try await client.deleteWatchProgress(
                session: target.session,
                remoteProfileId: target.remoteProfileId,
                keys: keys
            )
            return true
        } catch {
            print("Nuvio watch progress delete failed: \(error.localizedDescription)")
            return false
        }
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
    private func ensureStillSyncing(profileId: String? = nil) throws {
        try Task.checkCancellation()
        guard authManager?.isAuthenticated == true else { throw CancellationError() }
        guard let profileId else { return }
        guard profileViewModel?.activeProfile?.id == profileId,
              ContinueWatchingStore.activeProfileId == profileId,
              LibraryStore.activeProfileId == profileId,
              WatchedStore.activeProfileId == profileId,
              CollectionsStore.activeProfileId == profileId else {
            throw CancellationError()
        }
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
        var attemptedDeviceRegistration = false

        for (attempt, delay) in delays.enumerated() {
            if delay > 0 {
                try await Task.sleep(nanoseconds: delay * 1_000_000_000)
            }
            try ensureStillSyncing()
            Self.accountSyncDiagnostic = "connecting account (\(attempt + 1)/\(delays.count))"

            guard let session = await authManager.validSessionForSync(validateWithServer: true) else {
                lastError = AuthError(message: "The account session could not be restored.")
                // Retrying a session the server has already refused only spends
                // the backoff and ends on the same failure.
                if authManager.sessionNeedsReauthentication { break }
                continue
            }

            // Newer Nuvio backends keep a separate linked-device record. Older
            // tvOS builds never registered it, which left this Apple TV absent
            // from the account page even when authentication succeeded. The
            // registration is deliberately best-effort so an older backend
            // remains usable.
            let shouldRegisterDevice = !attemptedDeviceRegistration && (
                lastDeviceRegistrationAt == nil
                    || Date().timeIntervalSince(lastDeviceRegistrationAt ?? .distantPast)
                        >= Self.deviceRegistrationInterval
            )
            if shouldRegisterDevice {
                attemptedDeviceRegistration = true
                do {
                    try await client.registerCurrentDevice(session: session)
                    lastDeviceRegistrationAt = Date()
                    print("Nuvio sync registered this Apple TV as a linked device.")
                } catch {
                    print("Nuvio device registration skipped: \(error.localizedDescription)")
                }
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
                if error.statusCode == 401 || error.statusCode == 403 {
                    _ = await authManager.refreshSessionForSync()
                    if authManager.sessionNeedsReauthentication { break }
                }
            } catch {
                lastError = error
            }
        }

        if authManager.sessionNeedsReauthentication {
            throw AuthError(message: Self.reauthenticationMessage)
        }
        throw lastError
    }

    /// One wording for the state where the account is still configured on this
    /// Apple TV but its session can no longer be renewed.
    static let reauthenticationMessage =
        "Your Nuvio session expired. Sign in again to resume syncing."

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
            isApplyingRemoteProfiles = true
            let profilesApplied = profileViewModel.applyRemoteProfiles(merged)
            // `$activeProfile` can be delivered by SwiftUI after this
            // synchronous apply returns. Record the imported selection before
            // clearing the guard so it cannot cancel this same account pull.
            observedActiveProfileId = profileViewModel.activeProfile?.id
            isApplyingRemoteProfiles = false
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
                try ensureStillSyncing(profileId: activeProfile.id)
                isApplyingRemote = true
                let settingsApplied = try await client.pullProfileSettings(
                    session: session,
                    remoteProfileId: remoteProfileId,
                    localProfileId: activeProfile.id
                )
                try ensureStillSyncing(profileId: activeProfile.id)
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
                try ensureStillSyncing(profileId: activeProfile.id)
                lastPulledAddonRows = remoteAddons
                let appliedCount = client.applyAddons(remoteAddons, localProfileId: activeProfile.id)
                // Mirror Android's DataStore Flow: publish immediately after
                // this profile-scoped input lands instead of waiting for the
                // unrelated library/progress pulls below to finish.
                homeCatalogRevision &+= 1
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
                    try ensureStillSyncing(profileId: activeProfile.id)
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
                    try ensureStillSyncing(profileId: activeProfile.id)
                    client.applyHomeCatalogSettings(catalogSettings, localProfileId: activeProfile.id)
                    homeCatalogRevision &+= 1
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
                try ensureStillSyncing(profileId: activeProfile.id)
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
                try ensureStillSyncing(profileId: activeProfile.id)
                // These rows are what the Nuvio account itself holds, so they
                // are attributed to Nuvio Sync — not to whichever tracker
                // happens to be selected right now.
                WatchedStore.mergeRemote(remoteWatched.map { $0.adding(source: .nuvioSync) })
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                pullFailures += 1
                print("Nuvio watched sync failed: \(error.localizedDescription)")
            }

            do {
                // Captured before the request: rows written while it is in
                // flight are not absent because someone deleted them.
                let progressPullStartedAt = Date()
                let remoteProgress = try await client.pullWatchProgress(
                    session: session,
                    remoteProfileId: remoteProfileId
                )
                try ensureStillSyncing(profileId: activeProfile.id)
                // Authoritative, deletions included. The account is this
                // backend's source of truth, and a row deleted on another
                // device reaches us only as an absence from the snapshot.
                let progressReconcile = WatchProgressLedger.reconcileRemote(
                    remoteProgress,
                    syncStartedAt: progressPullStartedAt
                )
                guard progressReconcile.saved else {
                    throw AuthError(message: "Watch progress could not be saved on this Apple TV.")
                }
                if !progressReconcile.removedKeys.isEmpty,
                   WatchProgressLedger.records().isEmpty {
                    // The rebuild below returns early on an empty ledger without
                    // replacing the derived rows, which would leave the card for
                    // the title that was just deleted on screen.
                    ContinueWatchingStore.replaceAll([])
                }
                // Rendering is a separate, retryable pass: the rows are already
                // durable, so a slow or failing metadata lookup can no longer
                // cost the user their history.
                await ContinueWatchingBuilder.rebuild(reason: "account pull")
                let uploadStatus = watchStateUploadsEnabled ? "uploads on" : "uploads off"
                Self.progressSyncDiagnostic = "profile \(activeProfile.id), remote \(remoteProgress.count), "
                    + "\(uploadStatus); \(ContinueWatchingBuilder.diagnostic); "
                    + ContinueWatchingStore.persistenceDiagnostic
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
                try ensureStillSyncing(profileId: activeProfile.id)
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

            // Home can already be loading from an earlier revision while the
            // add-on and catalog settings above are still landing. Always
            // request one final rebuild from the complete synced snapshot.
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
                // Only a complete pull arms the refresh floor; a partial one has
                // to stay re-pullable.
                lastCompletedPullAt[key] = Date()
            }
            await pushLocalSnapshots()
        } catch is CancellationError {
            guard generation == pullGeneration else { return }
            isApplyingRemoteProfiles = false
            isApplyingRemote = false
            Self.accountSyncDiagnostic = "cancelled; retry pending"
        } catch {
            guard generation == pullGeneration else { return }
            isApplyingRemoteProfiles = false
            isApplyingRemote = false
            // "JWT expired" on every request is not a sync failure to retry —
            // it is a session the user has to renew, and saying so is the only
            // way an account that syncs nothing stops looking like an empty one.
            if authManager.sessionNeedsReauthentication {
                Self.accountSyncDiagnostic = "session expired — sign in again"
                print("Nuvio sync stopped: \(Self.reauthenticationMessage)")
                return
            }
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
            try ensureStillSyncing(profileId: activeProfile.id)
            try await client.pushProfileSettings(
                session: session,
                remoteProfileId: remoteProfileId,
                localProfileId: activeProfile.id
            )

            guard Self.watchStateSyncEnabled(for: activeProfile.id) else { return }

            // `activeProfile` falls back to `profiles.first`, but the stores it
            // reads from are pointed at whatever profile is genuinely active.
            // Deciding ownership from one profile's settings while uploading
            // another profile's rows is how watch state escaped the gate during
            // the launch window, before profile selection had settled.
            guard WatchedStore.activeProfileId == activeProfile.id else { return }

            let profileStore = ProfileSettings.store(for: activeProfile.id)
            let ownsLibrary = Self.ownsLibrary(for: activeProfile.id)
            if ownsLibrary {
                try ensureStillSyncing(profileId: activeProfile.id)
                try await client.pushLibrary(session: session, remoteProfileId: remoteProfileId)
            }

            let ownsWatchState = Self.ownsWatchState(for: activeProfile.id)
            if ownsWatchState {
                try ensureStillSyncing(profileId: activeProfile.id)
                try await client.pushWatched(session: session, remoteProfileId: remoteProfileId)
                try ensureStillSyncing(profileId: activeProfile.id)
                try await client.pushWatchProgress(session: session, remoteProfileId: remoteProfileId)
            }

            let library = ownsLibrary
                ? "\(LibraryStore.items().count) library item(s)"
                : "library owned by \(TraktSettingsStore.librarySourceMode(in: profileStore).rawValue)"
            let watchState = ownsWatchState
                ? "\(WatchedStore.items().count) watched, \(ContinueWatchingStore.items().count) progress item(s)"
                : "watch state owned by \(TraktSettingsStore.watchProgressSource(in: profileStore).rawValue)"
            print("Nuvio sync pushed \(library); \(watchState).")
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

    /// Whether Nuvio Sync is the account that *owns* watch state.
    ///
    /// `watchProgressSource` names exactly one owner. When that owner is Trakt
    /// or Simkl, their snapshot is reconciled into the same local `WatchedStore`
    /// the push reads from — so an unconditional push copies another tracker's
    /// history into the Nuvio account, where it then outlives disconnecting
    /// that tracker. Only upload watch state Nuvio Sync is actually the source
    /// of. The local store keeps the merged view either way; this gates the
    /// upload, not the merge.
    private static func ownsWatchState(for profileId: String) -> Bool {
        TraktSettingsStore.watchProgressSource(
            in: ProfileSettings.store(for: profileId)
        ) == .nuvioSync
    }

    /// Whether Nuvio Sync owns the library, on the same rule as
    /// ``ownsWatchState(for:)`` — `librarySourceMode` names one owner, and a
    /// Trakt or Simkl watchlist is reconciled into the same local
    /// `LibraryStore` this push reads from. The two settings are independent,
    /// so a profile can own one and not the other.
    private static func ownsLibrary(for profileId: String) -> Bool {
        TraktSettingsStore.librarySourceMode(
            in: ProfileSettings.store(for: profileId)
        ) == .local
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
                    // The web app stores custom image links in avatar_url,
                    // while catalog selections use avatar_id.
                    avatarId: remote.effectiveAvatarValue,
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
    private static let mobileSettingsPlatform = "mobile"
    private static let settingsFeature = "tvos_settings"
    private static let streamBadgeSettingsFeature = "stream_badge_settings"
    /// Shared with Android TV (`ProfileSettingsSyncService` / `DebridSettingsDataStore`).
    private static let debridSettingsFeature = "debrid_settings"
    /// Shared with Android TV's TMDB settings repository.
    private static let tmdbSettingsFeature = "tmdb_settings"

    private let session: URLSession = .shared
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
    private var lastPulledProfileSettingsJSON: [String: Any]?
    private var lastPulledMobileProfileSettingsJSON: [String: Any]?
    private var lastPulledHomeCatalogSettingsJSON: [String: Any]?

    private static func validAvatarURL(_ value: String) -> String? {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              url.host != nil else {
            return nil
        }
        return value
    }

    /// Registers this installation in the account's linked-device list. This
    /// is separate from the sync origin ID: the latter prevents a client from
    /// reacting to its own writes, while this RPC gives the account page a
    /// human-readable device and client version.
    @MainActor
    func registerCurrentDevice(session: AuthSession) async throws {
        let device = UIDevice.current
        let clientVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "dev"
        let deviceName = device.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let platform = "\(device.systemName) \(device.systemVersion)"

        try await rpcVoid(
            "register_current_device",
            session: session,
            params: [
                "p_installation_id": SyncClientIdentity.current(),
                "p_client_name": "Nuvio tvOS",
                "p_client_version": clientVersion,
                "p_platform": platform,
                "p_device_name": deviceName.isEmpty ? "Apple TV" : deviceName
            ]
        )
    }

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
    private static let homeCatalogSharedSyncPlatform = "home_catalog_shared"

    /// Pulls the account's Home catalog layout (which catalogs show on Home and
    /// in what order), mirroring Android's `HomeCatalogSettingsSyncService`.
    /// Returns the first platform that has any items, preferring the shared blob.
    func pullHomeCatalogSettings(session: AuthSession, remoteProfileId: Int) async throws -> HomeCatalogSyncPayload? {
        lastPulledHomeCatalogSettingsJSON = nil
        for platform in Self.homeCatalogSyncPlatforms {
            // Each platform is queried independently so one failing (or absent
            // on older backends) can't stop the others from being tried.
            guard let settingsJSON = try? await pullHomeCatalogSettingsJSON(
                session: session,
                remoteProfileId: remoteProfileId,
                platform: platform
            ) else { continue }
            lastPulledHomeCatalogSettingsJSON = settingsJSON
            let payload = HomeCatalogSyncPayload(dictionary: settingsJSON)
            if !payload.items.isEmpty { return payload }
        }
        return nil
    }

    func pushHomeCatalogSettings(
        session: AuthSession,
        remoteProfileId: Int,
        items: [[String: Any]]
    ) async throws {
        // Match Android's shared-payload merge: catalog edits replace only the
        // items while preserving standalone Home settings owned by other apps.
        var settingsJSON = (try? await pullHomeCatalogSettingsJSON(
            session: session,
            remoteProfileId: remoteProfileId,
            platform: Self.homeCatalogSharedSyncPlatform
        )) ?? lastPulledHomeCatalogSettingsJSON ?? [:]
        let remoteItems = settingsJSON["items"] as? [[String: Any]] ?? []
        settingsJSON["items"] = Self.mergeHomeCatalogItems(
            local: items,
            remote: remoteItems
        )
        try await rpcVoid(
            "sync_push_home_catalog_settings",
            session: session,
            params: [
                "p_profile_id": remoteProfileId,
                "p_platform": Self.homeCatalogSharedSyncPlatform,
                "p_settings_json": settingsJSON
            ]
        )
        lastPulledHomeCatalogSettingsJSON = settingsJSON
    }

    private func pullHomeCatalogSettingsJSON(
        session: AuthSession,
        remoteProfileId: Int,
        platform: String
    ) async throws -> [String: Any]? {
        let data = try await rpcData(
            "sync_pull_home_catalog_settings",
            session: session,
            params: ["p_profile_id": remoteProfileId, "p_platform": platform]
        )
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        return rows.first?["settings_json"] as? [String: Any]
    }

    private static func mergeHomeCatalogItems(
        local: [[String: Any]],
        remote: [[String: Any]]
    ) -> [[String: Any]] {
        var remoteByKey: [String: [String: Any]] = [:]
        for item in remote {
            let key = homeCatalogItemKey(item)
            guard !key.isEmpty, remoteByKey[key] == nil else { continue }
            remoteByKey[key] = item
        }
        return local.map { item in
            guard let remoteItem = remoteByKey[homeCatalogItemKey(item)] else { return item }
            var merged = remoteItem
            for (key, value) in item {
                // tvOS has no custom-title editor; preserve a title authored on
                // Android instead of replacing it with the local empty default.
                if key == "custom_title", (value as? String)?.isEmpty == true { continue }
                merged[key] = value
            }
            return merged
        }
    }

    private static func homeCatalogItemKey(_ item: [String: Any]) -> String {
        let isCollection = (item["is_collection"] as? Bool)
            ?? (item["is_collection"] as? NSNumber)?.boolValue
            ?? false
        if isCollection {
            return "collection:\(item["collection_id"] as? String ?? "")"
        }
        return "catalog:\(item["addon_id"] as? String ?? ""):\(item["type"] as? String ?? ""):\(item["catalog_id"] as? String ?? "")"
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
            // Custom links are a separate server field from catalog avatar ids.
            // Omitting both fields preserves a custom remote avatar. The public
            // API defines an explicit null/empty value as a clear, and tvOS
            // currently has no explicit "remove avatar" action.
            let avatarValue = profile.avatarId.trimmingCharacters(in: .whitespacesAndNewlines)
            if let avatarURL = Self.validAvatarURL(avatarValue) {
                payload["avatar_url"] = avatarURL
            } else if !avatarValue.isEmpty {
                payload["avatar_id"] = avatarValue
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
        lastPulledProfileSettingsJSON = nil
        lastPulledMobileProfileSettingsJSON = nil

        let settingsJSON = try await pullProfileSettingsJSON(
            session: session,
            remoteProfileId: remoteProfileId,
            platform: Self.settingsPlatform
        )
        lastPulledProfileSettingsJSON = settingsJSON
        // Android TV keeps this feature in its mobile-compatible settings blob.
        // Pull it independently so badge packs/settings follow the account even
        // when tvOS has never written a tv blob for this profile.
        let mobileSettingsJSON = try? await pullProfileSettingsJSON(
            session: session,
            remoteProfileId: remoteProfileId,
            platform: Self.mobileSettingsPlatform
        )
        lastPulledMobileProfileSettingsJSON = mobileSettingsJSON

        let features = settingsJSON?["features"] as? [String: Any] ?? [:]
        let mobileFeatures = mobileSettingsJSON?["features"] as? [String: Any] ?? [:]
        let tvosFeature = features[Self.settingsFeature] as? [String: Any]
        let debridFeature = features[Self.debridSettingsFeature] as? [String: Any]
        let tmdbFeature = features[Self.tmdbSettingsFeature] as? [String: Any]
        // Prefer mobile: Android TV writes there, while tvOS also mirrors the
        // feature into the tv blob for clients that only read that platform.
        let streamBadgeFeature = (mobileFeatures[Self.streamBadgeSettingsFeature] as? [String: Any])
            ?? (features[Self.streamBadgeSettingsFeature] as? [String: Any])
        guard tvosFeature != nil || debridFeature != nil || tmdbFeature != nil || streamBadgeFeature != nil else {
            return false
        }

        if let tvosFeature {
            importSettings(tvosFeature, localProfileId: localProfileId)
        }
        // Android TV stores debrid keys in a sibling feature on the same "tv" blob.
        importDebridSettings(debridFeature, localProfileId: localProfileId)
        importTmdbSettings(tmdbFeature, localProfileId: localProfileId)
        importStreamBadgeSettings(streamBadgeFeature, localProfileId: localProfileId)
        return true
    }

    private func pullProfileSettingsJSON(
        session: AuthSession,
        remoteProfileId: Int,
        platform: String
    ) async throws -> [String: Any]? {
        let raw = try await rpcJSONObject(
            "sync_pull_profile_settings_blob",
            session: session,
            params: [
                "p_profile_id": remoteProfileId,
                "p_platform": platform
            ]
        )
        guard let rows = raw as? [[String: Any]] else { return nil }
        return rows.first?["settings_json"] as? [String: Any]
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
        features[Self.streamBadgeSettingsFeature] = exportStreamBadgeSettings(localProfileId: localProfileId)
        // Keep Android stream-filter keys; overlay API keys + preferred resolver.
        let existingDebrid = features[Self.debridSettingsFeature] as? [String: Any]
        features[Self.debridSettingsFeature] = exportDebridSettings(
            localProfileId: localProfileId,
            existing: existingDebrid
        )
        let existingTmdb = features[Self.tmdbSettingsFeature] as? [String: Any]
        features[Self.tmdbSettingsFeature] = exportTmdbSettings(
            localProfileId: localProfileId,
            existing: existingTmdb
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

        // Keep the Android/mobile-compatible feature in its own blob as well.
        // Other mobile settings remain untouched by merging the latest remote
        // document before replacing only stream_badge_settings.
        do {
            var mobileSettingsJSON = try await pullProfileSettingsJSON(
                session: session,
                remoteProfileId: remoteProfileId,
                platform: Self.mobileSettingsPlatform
            ) ?? lastPulledMobileProfileSettingsJSON ?? [:]
            var mobileFeatures = mobileSettingsJSON["features"] as? [String: Any] ?? [:]
            mobileFeatures[Self.streamBadgeSettingsFeature] = exportStreamBadgeSettings(localProfileId: localProfileId)
            mobileSettingsJSON["features"] = mobileFeatures
            if mobileSettingsJSON["version"] == nil { mobileSettingsJSON["version"] = 1 }
            try await rpcVoid(
                "sync_push_profile_settings_blob",
                session: session,
                params: [
                    "p_profile_id": remoteProfileId,
                    "p_platform": Self.mobileSettingsPlatform,
                    "p_settings_json": mobileSettingsJSON
                ]
            )
            lastPulledMobileProfileSettingsJSON = mobileSettingsJSON
        } catch {
            // tvOS settings sync remains successful if an older backend does
            // not expose the mobile platform row/RPC yet.
            print("Nuvio stream badge mobile sync skipped: \(error.localizedDescription)")
        }
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
        // Only rows Nuvio Sync itself owns. The caller already checks that Nuvio
        // is the selected source, but the local store still holds marks imported
        // from Trakt or Simkl in an earlier session, and those are not this
        // account's to upload.
        let payload = WatchedStore.items()
            .filter {
                $0.isVisible(under: .nuvioSync)
                    // A series title marker is only a local aggregate used by
                    // tvOS to render the watched state. Upload its concrete
                    // episode rows instead, so specials and unaired episodes
                    // are never implied by a whole-show row.
                    && !($0.meta.isSeries && $0.season == nil && $0.episode == nil)
            }
            .map { item -> [String: Any] in
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
            // Omit rather than null, matching Android's delete payload. The push
            // above deliberately keeps explicit nulls because that endpoint wants
            // them — the two RPCs differ, so they are matched individually rather
            // than by one blanket rule.
            var key: [String: Any] = ["content_id": tombstone.metaId]
            if let season = tombstone.season { key["season"] = season }
            if let episode = tombstone.episode { key["episode"] = episode }
            return key
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

    /// Pulls the account's watch progress as raw rows.
    ///
    /// This performs no metadata lookups and applies no display rules, so a
    /// synced row can no longer be lost because an add-on was slow, an id was
    /// outside Cinemeta's space, or the writer never recorded a duration.
    /// Rendering — including the finished-episode rollover to "Next Up" — is
    /// `ContinueWatchingBuilder`'s job, and a failure there is retried instead
    /// of discarding history.
    func pullWatchProgress(session: AuthSession, remoteProfileId: Int) async throws -> [WatchProgressRecord] {
        let remote: [RemoteWatchProgress] = try await rpcRows(
            "sync_pull_watch_progress",
            session: session,
            params: [
                "p_profile_id": remoteProfileId
            ]
        ).elements

        return remote.map { entry in
            let type = Self.normalizedContentType(entry.contentType)
            return WatchProgressRecord(
                progressKey: entry.progressKey,
                contentId: entry.contentId,
                contentType: type,
                videoId: entry.videoId,
                season: entry.season,
                episode: entry.episode,
                position: Double(entry.position) / 1000.0,
                duration: Double(entry.duration) / 1000.0,
                lastWatchedAt: Self.date(fromMilliseconds: entry.lastWatched)
            )
        }
    }

    /// Pushes the raw ledger.
    ///
    /// Earlier builds pushed the *rendered* Continue Watching list and then
    /// deleted every progress key that list did not mention. Because that list
    /// was a lossy, twenty-item, one-row-per-show derivative of the account, the
    /// delete could retire rows this device had merely failed to render —
    /// including an episode the phone had legitimately just started. Deletions
    /// now happen only where the user actually removed something, via
    /// `deleteWatchProgress`.
    func pushWatchProgress(session: AuthSession, remoteProfileId: Int) async throws {
        // Episode entries must use the phone's row conventions — video_id
        // "id:s:e" and progress_key "id_s{s}e{e}" — or each platform upserts
        // its own parallel row for the same episode and they fight over
        // recency/progress on the other clients.
        // Only rows this device changed. Everything else came from the server,
        // which already has it — echoing the whole ledger back would put a
        // few hundred kilobytes on the wire every sync for no benefit.
        let records = WatchProgressLedger.records().filter(\.isPendingPush)
        let payload = records.map { record -> [String: Any] in
            var entry: [String: Any] = [
                "content_id": record.contentId,
                "content_type": record.contentType,
                "video_id": record.videoId,
                "position": Int64(record.position * 1000),
                "duration": Int64(record.duration * 1000),
                "last_watched": Self.milliseconds(from: record.lastWatchedAt),
                "progress_key": record.progressKey
            ]
            // Omit season/episode for movies rather than sending explicit nulls,
            // matching the Android client. To Postgres the two differ — an
            // explicit null still satisfies a key-presence test — and sending
            // them made the backend drop every movie row while accepting the
            // episodes alongside them.
            if let season = record.season { entry["season"] = season }
            if let episode = record.episode { entry["episode"] = episode }
            return entry
        }
        guard !payload.isEmpty else { return }
        try await rpcVoid(
            "sync_push_watch_progress",
            session: session,
            params: [
                "p_entries": payload,
                "p_profile_id": remoteProfileId
            ]
        )
        WatchProgressLedger.markPushed(keys: records.map(\.progressKey))
    }

    /// Retires specific rows the user removed on this device.
    func deleteWatchProgress(
        session: AuthSession,
        remoteProfileId: Int,
        keys: [String]
    ) async throws {
        guard !keys.isEmpty else { return }
        try await rpcVoid(
            "sync_delete_watch_progress",
            session: session,
            params: [
                "p_keys": keys,
                "p_profile_id": remoteProfileId
            ]
        )
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

    private func exportStreamBadgeSettings(localProfileId: String) -> [String: Any] {
        let defaults = ProfileSettings.store(for: localProfileId)
        let mappings: [(String, String)] = [
            (SettingsKey.streamBadgeRules, "stream_badge_rules"),
            (SettingsKey.showFileSizeBadges, "show_file_size_badges"),
            (SettingsKey.showAddonLogo, "show_addon_logo"),
            (SettingsKey.streamBadgePlacement, "stream_badge_placement")
        ]
        var feature: [String: Any] = [:]
        for (localKey, remoteKey) in mappings {
            guard let value = defaults.object(forKey: localKey),
                  let encoded = Self.encodeSettingValue(value) else { continue }
            feature[remoteKey] = encoded
        }
        return feature
    }

    private func importStreamBadgeSettings(_ remote: [String: Any]?, localProfileId: String) {
        guard let remote else { return }
        let defaults = ProfileSettings.store(for: localProfileId)
        let mappings: [(String, String)] = [
            ("stream_badge_rules", SettingsKey.streamBadgeRules),
            ("show_file_size_badges", SettingsKey.showFileSizeBadges),
            ("show_addon_logo", SettingsKey.showAddonLogo),
            ("stream_badge_placement", SettingsKey.streamBadgePlacement)
        ]

        // Android's replaceFromSyncPayload clears the feature before applying
        // the remote values, so omitted optional values do not leave stale
        // settings from the previous profile/account behind.
        mappings.forEach { _, localKey in
            defaults.removeObject(forKey: localKey)
        }
        for (remoteKey, localKey) in mappings {
            if let encoded = remote[remoteKey] as? [String: Any],
               let value = Self.decodeSettingValue(encoded) {
                defaults.set(value, forKey: localKey)
            } else if let value = remote[remoteKey] as? String {
                defaults.set(value, forKey: localKey)
            } else if let value = remote[remoteKey] as? Bool {
                defaults.set(value, forKey: localKey)
            }
        }
        StreamBadgeSettingsStore.postChanged()
    }

    private func exportSettings(localProfileId: String) -> [String: Any] {
        let defaults = ProfileSettings.store(for: localProfileId)
        var exported: [String: Any] = [:]
        SettingsKey.all.forEach { key in
            // Sync policy is device-local. Exporting it lets a temporary test
            // or another TV disable account progress pulls everywhere.
            guard key != SettingsKey.accountSyncWatchState else { return }
            guard !SettingsKey.deviceLocal.contains(key) else { return }
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
            guard !SettingsKey.deviceLocal.contains(key) else { return }
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

    private enum AndroidTmdbKey {
        static let enabled = "tmdb_enabled"
        static let apiKey = "tmdb_api_key"
        static let language = "tmdb_language"
        static let useTrailers = "tmdb_use_trailers"
        static let useArtwork = "tmdb_use_artwork"
        static let useBasicInfo = "tmdb_use_basic_info"
        static let useDetails = "tmdb_use_details"
        static let useCredits = "tmdb_use_credits"
        static let useProductions = "tmdb_use_productions"
        static let useNetworks = "tmdb_use_networks"
        static let useEpisodes = "tmdb_use_episodes"
        static let useSeasonPosters = "tmdb_use_season_posters"
        static let useMoreLikeThis = "tmdb_use_more_like_this"
        static let useCollections = "tmdb_use_collections"
    }

    private func exportTmdbSettings(
        localProfileId: String,
        existing: [String: Any]?
    ) -> [String: Any] {
        let defaults = ProfileSettings.store(for: localProfileId)
        var feature = existing ?? [:]

        let mappings: [(String, String)] = [
            (SettingsKey.tmdbEnabled, AndroidTmdbKey.enabled),
            (SettingsKey.tmdbApiKey, AndroidTmdbKey.apiKey),
            (SettingsKey.tmdbLanguage, AndroidTmdbKey.language),
            (SettingsKey.tmdbUseTrailers, AndroidTmdbKey.useTrailers),
            (SettingsKey.tmdbUseArtwork, AndroidTmdbKey.useArtwork),
            (SettingsKey.tmdbUseBasicInfo, AndroidTmdbKey.useBasicInfo),
            (SettingsKey.tmdbUseDetails, AndroidTmdbKey.useDetails),
            (SettingsKey.tmdbUseCredits, AndroidTmdbKey.useCredits),
            (SettingsKey.tmdbUseProductions, AndroidTmdbKey.useProductions),
            (SettingsKey.tmdbUseNetworks, AndroidTmdbKey.useNetworks),
            (SettingsKey.tmdbUseEpisodes, AndroidTmdbKey.useEpisodes),
            (SettingsKey.tmdbUseSeasonPosters, AndroidTmdbKey.useSeasonPosters),
            (SettingsKey.tmdbUseMoreLikeThis, AndroidTmdbKey.useMoreLikeThis),
            (SettingsKey.tmdbUseCollections, AndroidTmdbKey.useCollections),
        ]

        for (localKey, androidKey) in mappings {
            guard let value = defaults.object(forKey: localKey),
                  let encoded = Self.encodeSettingValue(value) else {
                continue
            }
            feature[androidKey] = encoded
        }
        return feature
    }

    private func importTmdbSettings(_ remote: [String: Any]?, localProfileId: String) {
        guard let remote, !remote.isEmpty else { return }
        let defaults = ProfileSettings.store(for: localProfileId)

        let mappings: [(String, String)] = [
            (AndroidTmdbKey.enabled, SettingsKey.tmdbEnabled),
            (AndroidTmdbKey.apiKey, SettingsKey.tmdbApiKey),
            (AndroidTmdbKey.language, SettingsKey.tmdbLanguage),
            (AndroidTmdbKey.useTrailers, SettingsKey.tmdbUseTrailers),
            (AndroidTmdbKey.useArtwork, SettingsKey.tmdbUseArtwork),
            (AndroidTmdbKey.useBasicInfo, SettingsKey.tmdbUseBasicInfo),
            (AndroidTmdbKey.useDetails, SettingsKey.tmdbUseDetails),
            (AndroidTmdbKey.useCredits, SettingsKey.tmdbUseCredits),
            (AndroidTmdbKey.useProductions, SettingsKey.tmdbUseProductions),
            (AndroidTmdbKey.useNetworks, SettingsKey.tmdbUseNetworks),
            (AndroidTmdbKey.useEpisodes, SettingsKey.tmdbUseEpisodes),
            (AndroidTmdbKey.useSeasonPosters, SettingsKey.tmdbUseSeasonPosters),
            (AndroidTmdbKey.useMoreLikeThis, SettingsKey.tmdbUseMoreLikeThis),
            (AndroidTmdbKey.useCollections, SettingsKey.tmdbUseCollections),
        ]

        for (androidKey, localKey) in mappings {
            if let encoded = remote[androidKey] as? [String: Any],
               let value = Self.decodeSettingValue(encoded) {
                defaults.set(value, forKey: localKey)
            } else if let value = remote[androidKey] as? String {
                // Tolerate raw strings from older Android TV builds.
                defaults.set(value, forKey: localKey)
            } else if let value = remote[androidKey] as? Bool {
                defaults.set(value, forKey: localKey)
            }
        }
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
        if let data = value as? Data {
            // UserDefaults-backed `@AppStorage<Data>` preferences (currently
            // the selected Home hero catalogs) are still profile settings.
            // JSON cannot carry raw bytes, so use a portable base64 value.
            return ["type": "data", "value": data.base64EncodedString()]
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
        case "data":
            guard let base64 = value as? String else { return nil }
            return Data(base64Encoded: base64)
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
enum EpisodeMetadataEnrichment {
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
              TmdbDetailsService.useEpisodes,
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
            URLQueryItem(name: "language", value: TmdbDetailsService.preferredLanguage)
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
    let avatarUrl: String?
    let usesPrimaryAddons: Bool
    let usesPrimaryPlugins: Bool
    let pinEnabled: Bool?

    var effectiveAvatarValue: String {
        let url = avatarUrl?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return url.isEmpty ? (avatarId ?? "") : url
    }

    enum CodingKeys: String, CodingKey {
        case profileIndex
        case name
        case avatarId
        case avatarUrl
        case usesPrimaryAddons
        case usesPrimaryPlugins
        case pinEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profileIndex = try container.decode(Int.self, forKey: .profileIndex)
        name = (try? container.decode(String.self, forKey: .name)) ?? ""
        avatarId = try? container.decodeIfPresent(String.self, forKey: .avatarId)
        avatarUrl = try? container.decodeIfPresent(String.self, forKey: .avatarUrl)
        usesPrimaryAddons = (try? container.decode(Bool.self, forKey: .usesPrimaryAddons)) ?? false
        usesPrimaryPlugins = (try? container.decode(Bool.self, forKey: .usesPrimaryPlugins)) ?? false
        pinEnabled = try? container.decodeIfPresent(Bool.self, forKey: .pinEnabled)
    }

    private init(copying profile: RemoteProfile, pinEnabled: Bool?) {
        profileIndex = profile.profileIndex
        name = profile.name
        avatarId = profile.avatarId
        avatarUrl = profile.avatarUrl
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
