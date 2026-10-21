import Foundation
import Combine

/// One root-owned composition, attached to ContentView's existing account/profile objects.
/// Construction and attachment remain inert. Explicit room requests may adopt the current player;
/// new playback and exact PiP lease restoration remain explicit launch transitions.
@MainActor
final class WatchPartyAppOwner: ObservableObject {
    struct Presentation: Identifiable {
        let id: UUID
        let mount: WatchPartyPlayerMount
        let context: WatchPartyPlaybackContext
    }
    @Published private(set) var service: WatchPartyService?
    @Published private(set) var presentation: Presentation?
    @Published var message: String?
    // The backend currently configures host-only after room creation. Hide
    // invitations while the explicit host choice remains unconfirmed.
    @Published private(set) var pendingHostOnlyRoomID: String?
    // Local acknowledgement of one consented broadcast, not a persistent
    // server source or a guarantee that peers still have a valid link.
    @Published private(set) var locallySharedStreamRoomID: String?
    private var requestedHostOnly = true

    func markLocalStreamShared(roomID: String) {
        guard service?.session?.party?.id == roomID else { return }
        locallySharedStreamRoomID = roomID
    }

    func clearLocalStreamShared(roomID: String) {
        if locallySharedStreamRoomID == roomID { locallySharedStreamRoomID = nil }
    }

    func confirmPendingHostOnly() async throws {
        guard let service, let room = service.session, let party = room.party,
              party.id == pendingHostOnlyRoomID,
              party.hostMemberID == room.memberID else {
            throw WatchPartySessionError.notReady
        }
        if party.hostOnly != requestedHostOnly {
            try await service.setHostOnly(enabled: requestedHostOnly)
        }
        guard service.session === room, room.party?.id == party.id,
              room.party?.hostOnly == requestedHostOnly else {
            throw WatchPartySessionError.notReady
        }
        pendingHostOnlyRoomID = nil
    }

    private var preservePlayerAfterRoomExit = false
    private var lease: WatchPartyPlayerRuntime.Lease?
    private var browsingTask: Task<Void, Never>?
    private(set) var runtime: WatchPartyPlayerRuntime?
    private weak var authManager: AuthManager?
    private weak var profiles: ProfileViewModel?
    private var subscriptions: Set<AnyCancellable> = []
    private weak var observedRoom: WatchPartySession?
    private var roomObserverID: UUID?

    init() {}

    /// Injection keeps context-boundary tests independent of Auth/Keychain/network/player engines.
    init(service: WatchPartyService, contextChanges: AnyPublisher<Void, Never>) {
        configure(service: service, contextChanges: contextChanges)
    }

    func attach(authManager: AuthManager, profiles: ProfileViewModel) {
        guard WatchPartyConfiguration.isEnabled else {
            stop()
            return
        }
        if self.authManager === authManager, self.profiles === profiles, service != nil { return }
        stop()
        self.authManager = authManager
        self.profiles = profiles
        let service = WatchPartyService.authenticated(
            authManager: authManager, deviceID: SyncClientIdentity.current(),
            profile: { [weak profiles] in
                guard let profile = profiles?.activeProfile else { return nil }
                let avatarStore = AvatarCatalogStore.shared
                let avatarURL = avatarStore.imageURL(for: profile.avatarId)?.absoluteString
                let avatarColor = avatarStore.item(for: profile.avatarId)?.bgColor
                return WatchPartyProfileIdentity(
                    id: profile.id,
                    name: profile.name,
                    avatarURL: avatarURL,
                    avatarColor: avatarColor
                )
            }
        )
        configure(service: service, contextChanges: authManager.contextWillChange
            .merge(with: profiles.contextWillChange).eraseToAnyPublisher())
    }

    /// Explicit privacy gate (e.g. who's-watching on return) may revoke the same profile, too.
    func invalidateContext() { service?.invalidateContext() }

    /// Only after an explicit local source choice for this exact accepted room/media.
    func preparePlayback(media: WatchPartyMedia) throws -> Presentation {
        guard let service, let room = service.session, room.connection == .ready,
              let context = room.playbackContext, context.mediaKey == media.key,
              service.isCurrent(context.request), let runtime else {
            throw WatchPartyPlaybackRuntimeError.staleContext
        }
        finishPlayback(reportBrowsing: false)
        browsingTask?.cancel(); browsingTask = nil
        let lease = try runtime.beginPlayer(context: context)
        do {
            _ = try runtime.bindPlayback(lease, room: room)
            let id = UUID()
            let mount = try WatchPartyPlayerMount(runtime: runtime, lease: lease, onDetached: { [weak self] in
                guard self?.presentation?.id == id else { return }
                self?.finishPlayback()
            })
            let result = Presentation(id: id, mount: mount, context: context)
            self.lease = lease
            presentation = result
            message = nil
            return result
        } catch { runtime.finish(lease); throw error }
    }

    /// Create and adopt the player's current media without resolving or loading another source.
    /// An accepted room is deliberately retained if the player becomes stale during attachment.
    func createRoomForCurrentPlayback(
        using viewModel: PlayerViewModel,
        isCurrentPlayerSurface: @escaping @MainActor () -> Bool,
        hostOnly: Bool = true
    ) async {
        message = nil
        guard isCurrentPlayerSurface() else { return }
        guard let service, let runtime else {
            message = "Watch Party isn't available right now."
            return
        }
        guard presentation == nil, lease == nil, runtime.currentContext == nil else {
            message = "This player is already attached to a Watch Party."
            return
        }

        let initialSnapshot: WatchPartyRoomCreationSnapshot
        do {
            initialSnapshot = try viewModel.watchPartyRoomCreationSnapshot()
        } catch let error as WatchPartyRoomCreationError {
            message = error.message
            return
        } catch {
            message = "Playback isn't ready to host a Watch Party."
            return
        }

        var roomWasAccepted = false
        do {
            try await service.create(media: initialSnapshot.media)
            roomWasAccepted = true
            if let createdRoomID = service.session?.party?.id {
                requestedHostOnly = hostOnly
                pendingHostOnlyRoomID = createdRoomID
            }

            guard self.service === service,
                  isCurrentPlayerSurface(),
                  viewModel.isSameWatchPartyRoomCreationPlayback(initialSnapshot),
                  let room = service.session,
                  let context = room.playbackContext,
                  context.mediaKey == initialSnapshot.media.key,
                  room.party?.media.key == initialSnapshot.media.key,
                  service.isCurrent(context.request),
                  self.runtime === runtime else {
                throw WatchPartyRoomCreationError.stalePlayback
            }
            guard room.connection == .ready else {
                message = "Room created, but the connection isn't ready. The room remains open; playback isn't attached."
                return
            }

            // Do not publish host playback or expose an invitation while a
            // separate permission RPC has not acknowledged this exact room.
            try await confirmPendingHostOnly()

            // Use the latest transport sample after the room request, while retaining the exact
            // load/media identity captured when the user pressed Create.
            var snapshot = try viewModel.watchPartyRoomCreationSnapshot()
            guard snapshot.media.key == initialSnapshot.media.key,
                  viewModel.isSameWatchPartyRoomCreationPlayback(initialSnapshot) else {
                throw WatchPartyRoomCreationError.stalePlayback
            }

            // Publish before binding so the first host tick cannot reconcile against empty room
            // state. If local intent changes during a publish, refresh and publish again before
            // binding. Clock progression alone does not invalidate this snapshot.
            var publicationIsStable = false
            for attempt in 0..<3 {
                guard self.service === service, service.session === room,
                      isCurrentPlayerSurface(),
                      service.isCurrent(context.request), room.playbackContext == context,
                      room.connection == .ready, room.party?.media.key == snapshot.media.key,
                      viewModel.isSameWatchPartyRoomCreationPlayback(initialSnapshot),
                      self.runtime === runtime else {
                    throw WatchPartyRoomCreationError.stalePlayback
                }

                try await room.publish(
                    paused: snapshot.paused,
                    positionMs: snapshot.positionMs,
                    rate: snapshot.rate,
                    waiting: false
                )

                guard self.service === service, service.session === room,
                      isCurrentPlayerSurface(),
                      service.isCurrent(context.request), room.playbackContext == context,
                      room.connection == .ready, room.party?.media.key == snapshot.media.key,
                      viewModel.isSameWatchPartyRoomCreationPlayback(initialSnapshot),
                      self.runtime === runtime else {
                    throw WatchPartyRoomCreationError.stalePlayback
                }
                if viewModel.isCurrentWatchPartyRoomCreationSnapshot(snapshot) {
                    publicationIsStable = true
                    break
                }
                guard attempt < 2 else {
                    message = "Room created, but playback kept changing. The room remains open; playback isn't attached."
                    return
                }

                snapshot = try viewModel.watchPartyRoomCreationSnapshot()
                guard snapshot.media.key == initialSnapshot.media.key,
                      viewModel.isSameWatchPartyRoomCreationPlayback(initialSnapshot) else {
                    throw WatchPartyRoomCreationError.stalePlayback
                }
            }

            guard publicationIsStable else {
                message = "Room created, but playback kept changing. The room remains open; playback isn't attached."
                return
            }

            let lease = try runtime.begin(context: context) { viewModel }
            do {
                try runtime.markInitialLoadClaimed(lease)
                _ = try runtime.bindPlayback(lease, room: room)
                let id = UUID()
                let mount = try WatchPartyPlayerMount(runtime: runtime, lease: lease, onDetached: { [weak self] in
                    guard self?.presentation?.id == id else { return }
                    self?.finishPlayback()
                })
                viewModel.suspendNextEpisodeStateForWatchParty()
                self.lease = lease
                presentation = Presentation(id: id, mount: mount, context: context)
                message = nil
            } catch {
                runtime.abandon(lease)
                throw error
            }
        } catch let error as WatchPartyRoomCreationError {
            if roomWasAccepted {
                message = "Room created, but playback changed before it could attach. The room remains open; playback isn't attached."
            } else {
                message = error.message
            }
        } catch {
            if roomWasAccepted {
                message = pendingHostOnlyRoomID != nil
                    ? "Room created, but host-only permissions are unconfirmed. Retry before inviting anyone."
                    : "Room created, but playback couldn't attach. The room is still open in Watch Party."
            } else if service.membershipOutcomeUncertain {
                message = "Room status is uncertain. Check Watch Party before trying again."
            } else if service.failure == nil {
                message = "Could not create the room. Check your connection and try again."
            }
        }
    }

    func owns(_ coordinator: PlaybackSessionCoordinator?) -> Bool {
        guard let coordinator, let lease else { return false }
        return lease.resource.sessionCoordinator === coordinator
    }

    func restorePlayback(for coordinator: PlaybackSessionCoordinator?) -> Presentation? {
        guard owns(coordinator), let presentation, let runtime,
              (try? runtime.restore(context: presentation.context)) != nil,
              presentation.mount.isCurrent else { return nil }
        return presentation
    }

    func resumeAfterForeground() {
        guard let presentation, presentation.mount.isCurrent else { return }
        presentation.mount.viewModel.resumeWatchPartyAfterForeground()
    }

    func suspendForInactivity() {
        guard let presentation, presentation.mount.isCurrent else { return }
        presentation.mount.viewModel.suspendWatchPartyForLifecycle()
    }

    func finishPlayback(reportBrowsing: Bool = true) {
        let context = lease?.context
        let oldRuntime = runtime
        lease = nil
        presentation = nil
        browsingTask?.cancel(); browsingTask = nil
        oldRuntime?.invalidate()
        guard reportBrowsing, let context, let service, let room = service.session,
              service.isCurrent(context.request), room.playbackContext == context else { return }
        browsingTask = Task { [weak self, weak service, weak room] in
            guard !Task.isCancelled, let service, let room,
                  service.isCurrent(context.request), room.playbackContext == context,
                  self?.lease == nil else { return }
            do { try await room.setPresence(status: .browsing, mediaKey: nil, behindMs: nil) }
            catch { if !Task.isCancelled { self?.message = "Could not update your room status." } }
        }
    }

    /// Leave or end a room without shutting down the player that is already on screen.
    /// Abandoning the lease stops the room binding and removes Party controls, but preserves
    /// its PlayerViewModel so video, audio, and playback position continue locally.
    func leaveRoomPreservingPlayback(endForEveryone: Bool = false) async throws {
        guard let service else { throw WatchPartyServiceError.requestFailed }
        browsingTask?.cancel(); browsingTask = nil
        if let lease, let runtime, presentation?.context == lease.context {
            preservePlayerAfterRoomExit = true
            self.lease = nil
            presentation = nil
            runtime.abandon(lease)
            lease.resource.resumeNextEpisodeStateAfterWatchParty()
        } else {
            finishPlayback(reportBrowsing: false)
        }
        try await service.leave(endForEveryone: endForEveryone)
        locallySharedStreamRoomID = nil
        pendingHostOnlyRoomID = nil
    }

    /// Root consumes this when the presentation disappears after an explicit leave/end.
    func consumePreservePlayerAfterRoomExit() -> Bool {
        defer { preservePlayerAfterRoomExit = false }
        return preservePlayerAfterRoomExit
    }

    /// Explicit root teardown; never use an asynchronous deinit for resource cleanup.
    func stop() {
        subscriptions.removeAll()
        observeRoom(nil)
        finishPlayback(reportBrowsing: false)
        let oldRuntime = runtime
        let oldService = service
        pendingHostOnlyRoomID = nil
        locallySharedStreamRoomID = nil
        runtime = nil
        service = nil
        authManager = nil
        profiles = nil
        oldRuntime?.invalidate()
        oldService?.invalidateContext()
    }

    private func configure(service: WatchPartyService, contextChanges: AnyPublisher<Void, Never>) {
        self.service = service
        let runtime = WatchPartyPlayerRuntime.player { [weak service] context in
            guard let service, service.isCurrent(context.request) else { return false }
            return service.session?.playbackContext == context
        }
        self.runtime = runtime
        // Subjects are emitted synchronously by @MainActor AuthManager/ProfileViewModel.
        // No receive(on:) or Task: these must finish before credentials/store scope mutate.
        contextChanges.sink { [weak service] _ in
            MainActor.assumeIsolated { service?.invalidateContext() }
        }.store(in: &subscriptions)
        service.contextDidInvalidate.sink { [weak self] _ in
            MainActor.assumeIsolated { self?.finishPlayback(reportBrowsing: false) }
        }.store(in: &subscriptions)
        // @Published emits before the new pointer is installed. This also covers explicit
        // leave/replacement outside context invalidation. Do not adopt a new room implicitly.
        service.$session.dropFirst().sink { [weak self, weak service] next in
            MainActor.assumeIsolated {
                if service?.session !== next { self?.finishPlayback(reportBrowsing: false) }
                if next?.party?.id != self?.pendingHostOnlyRoomID {
                    self?.pendingHostOnlyRoomID = nil
                }
                if next?.party?.id != self?.locallySharedStreamRoomID {
                    self?.locallySharedStreamRoomID = nil
                }
                self?.observeRoom(next)
            }
        }.store(in: &subscriptions)
        observeRoom(service.session)
    }

    private func observeRoom(_ room: WatchPartySession?) {
        if let roomObserverID { observedRoom?.removeChangeObserver(roomObserverID) }
        roomObserverID = nil
        observedRoom = room
        guard let room else { return }
        roomObserverID = room.observeChanges { [weak self, weak room] in
            guard let self, let context = self.runtime?.currentContext else { return }
            if room?.playbackContext != context {
                // Membership/media changes close the old player; source resolution is a later,
                // explicit transition. No automatic reuse of its URL or host-provided link.
                self.finishPlayback(reportBrowsing: false)
                if room?.playbackContext != nil { self.message = "The room changed title. Choose your source again." }
            }
        }
    }
}
