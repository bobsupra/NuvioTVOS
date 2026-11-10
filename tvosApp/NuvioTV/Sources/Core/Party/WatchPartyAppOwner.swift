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
    struct IncomingMediaTransition: Identifiable {
        let id: UUID
        let context: WatchPartyPlaybackContext
        let media: WatchPartyMedia
        let plan: WatchPartyIncomingEpisodePlan?
        let viewModel: PlayerViewModel
    }
    @Published private(set) var service: WatchPartyService?
    @Published private(set) var presentation: Presentation?
    @Published private(set) var incomingMediaTransition: IncomingMediaTransition?
    @Published var message: String?
    private var preservePlayerAfterRoomExit = false
    private var isChangingRoomMedia = false
    private var incomingMediaTransitionID: UUID?
    private var incomingMediaTransitionContext: WatchPartyPlaybackContext?
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
            preservePlayerAfterRoomExit = false
            message = nil
            return result
        } catch { runtime.finish(lease); throw error }
    }

    /// Create and adopt the player's current media without resolving or loading another source.
    /// An accepted room is deliberately retained if the player becomes stale during attachment.
    func createRoomForCurrentPlayback(
        using viewModel: PlayerViewModel,
        isCurrentPlayerSurface: @escaping @MainActor () -> Bool
    ) async {
        message = nil
        guard isCurrentPlayerSurface() else { return }
        guard let service, let runtime else {
            message = L10n.string("party_error_unavailable_now", fallback: "Watch Party isn't available right now.")
            return
        }
        guard presentation == nil, lease == nil, runtime.currentContext == nil else {
            message = L10n.string("party_error_already_attached", fallback: "This player is already attached to a Watch Party.")
            return
        }

        let initialSnapshot: WatchPartyRoomCreationSnapshot
        do {
            initialSnapshot = try viewModel.watchPartyRoomCreationSnapshot()
        } catch let error as WatchPartyRoomCreationError {
            message = error.message
            return
        } catch {
            message = L10n.string("party_error_playback_not_ready", fallback: "Playback isn't ready to host a Watch Party.")
            return
        }

        var roomWasAccepted = false
        do {
            try await service.create(media: initialSnapshot.media)
            roomWasAccepted = true

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
                message = L10n.string("party_error_connection_not_ready", fallback: "Room created, but the connection isn't ready. The room remains open; playback isn't attached.")
                return
            }

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
                    message = L10n.string("party_error_playback_kept_changing", fallback: "Room created, but playback kept changing. The room remains open; playback isn't attached.")
                    return
                }

                snapshot = try viewModel.watchPartyRoomCreationSnapshot()
                guard snapshot.media.key == initialSnapshot.media.key,
                      viewModel.isSameWatchPartyRoomCreationPlayback(initialSnapshot) else {
                    throw WatchPartyRoomCreationError.stalePlayback
                }
            }

            guard publicationIsStable else {
                message = L10n.string("party_error_playback_kept_changing", fallback: "Room created, but playback kept changing. The room remains open; playback isn't attached.")
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
                message = L10n.string("party_error_playback_changed_before_attach", fallback: "Room created, but playback changed before it could attach. The room remains open; playback isn't attached.")
            } else {
                message = error.message
            }
        } catch {
            if roomWasAccepted {
                message = L10n.string("party_error_playback_attach_failed", fallback: "Room created, but playback couldn't attach. The room is still open in Watch Party.")
            } else if service.membershipOutcomeUncertain {
                message = L10n.string("party_error_status_uncertain", fallback: "Room status is uncertain. Check Watch Party before trying again.")
            } else if service.failure == nil {
                message = L10n.string("party_error_create_failed", fallback: "Could not create the room. Check your connection and try again.")
            }
        }
    }

    func owns(_ coordinator: PlaybackSessionCoordinator?) -> Bool {
        guard let coordinator, let lease else { return false }
        return lease.resource.sessionCoordinator === coordinator
    }

    /// Host-selected episode changes invalidate the old media binding. Keep the player
    /// surface on screen while the caller prepares a fresh lease for the accepted episode.
    func updateRoomMedia(_ media: WatchPartyMedia) async throws {
        guard let service, let room = service.session,
              let presentation, presentation.mount.isCurrent,
              room.playbackContext == presentation.context,
              room.party?.media.key != media.key else {
            throw WatchPartyPlaybackRuntimeError.staleContext
        }
        let previousKey = presentation.context.mediaKey
        isChangingRoomMedia = true
        defer { isChangingRoomMedia = false }
        do {
            try await service.updateMedia(media)
        } catch {
            if room.party?.media.key == previousKey { preservePlayerAfterRoomExit = false }
            throw error
        }
        guard service.session === room, room.connection == .ready,
              room.party?.media.key == media.key else {
            throw WatchPartyPlaybackRuntimeError.staleContext
        }
    }

    func isCurrentIncomingMediaTransition(_ id: UUID, context: WatchPartyPlaybackContext) -> Bool {
        guard incomingMediaTransitionID == id,
              incomingMediaTransition?.id == id,
              incomingMediaTransitionContext == context,
              let service, service.isCurrent(context.request),
              let room = service.session, room.playbackContext == context,
              room.party?.media.key == context.mediaKey else { return false }
        return true
    }

    func completeIncomingMediaTransition(_ id: UUID, context: WatchPartyPlaybackContext) {
        guard isCurrentIncomingMediaTransition(id, context: context) else { return }
        let oldViewModel = incomingMediaTransition?.viewModel
        incomingMediaTransitionID = nil
        incomingMediaTransitionContext = nil
        incomingMediaTransition = nil
        preservePlayerAfterRoomExit = false
        oldViewModel?.shutdownForWatchParty()
    }

    /// Root invokes this after source resolution fails or the target is not the exact next episode.
    @discardableResult
    func showWatchPartyAfterIncomingMediaTransition(_ id: UUID) -> Bool {
        guard incomingMediaTransitionID == id,
              let transition = incomingMediaTransition, transition.id == id else { return false }
        incomingMediaTransitionID = nil
        incomingMediaTransitionContext = nil
        incomingMediaTransition = nil
        transition.viewModel.clearWatchPartyTransitionCallbacks()
        // Keep the player through the presentation-nil callback; it consumes this flag.
        guard transition.viewModel.isSceneEnabled else {
            message = L10n.string("party_error_room_changed_episodes", fallback: "The room changed episodes. Choose a source from the Watch Party lobby.")
            return false
        }
        transition.viewModel.openWatchPartyScene()
        return true
    }

    func cancelIncomingMediaTransition(_ id: UUID) {
        guard incomingMediaTransitionID == id else { return }
        let oldViewModel = incomingMediaTransition?.viewModel
        incomingMediaTransitionID = nil
        incomingMediaTransitionContext = nil
        incomingMediaTransition = nil
        preservePlayerAfterRoomExit = false
        oldViewModel?.shutdownForWatchParty()
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
            catch { if !Task.isCancelled { self?.message = L10n.string("party_error_update_status_failed", fallback: "Could not update your room status.") } }
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
            lease.resource.clearWatchPartyTransitionCallbacks()
            runtime.abandon(lease)
            lease.resource.resumeNextEpisodeStateAfterWatchParty()
        } else {
            finishPlayback(reportBrowsing: false)
        }
        try await service.leave(endForEveryone: endForEveryone)
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
        if let id = incomingMediaTransitionID { cancelIncomingMediaTransition(id) }
        finishPlayback(reportBrowsing: false)
        let oldRuntime = runtime
        let oldService = service
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
            MainActor.assumeIsolated {
                if let self, let id = self.incomingMediaTransitionID {
                    self.cancelIncomingMediaTransition(id)
                }
                self?.finishPlayback(reportBrowsing: false)
            }
        }.store(in: &subscriptions)
        // @Published emits before the new pointer is installed. This also covers explicit
        // leave/replacement outside context invalidation. Do not adopt a new room implicitly.
        service.$session.dropFirst().sink { [weak self, weak service] next in
            MainActor.assumeIsolated {
                if service?.session !== next { self?.finishPlayback(reportBrowsing: false) }
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
                if self.isChangingRoomMedia {
                    self.preservePlayerAfterRoomExit = true
                    self.finishPlayback(reportBrowsing: false)
                    return
                }
                if let nextContext = room?.playbackContext,
                   WatchPartyDetailsPresentationPolicy.sameMembership(context, nextContext),
                   nextContext.mediaKey != context.mediaKey,
                   let room, let lease = self.lease,
                   lease.context == context,
                   let presentation = self.presentation,
                   presentation.context == context,
                   let runtime = self.runtime,
                   let service = self.service,
                   service.session === room,
                   let media = room.party?.media,
                   media.key == nextContext.mediaKey {
                    self.beginIncomingMediaTransition(
                        from: context, to: nextContext, media: media,
                        service: service, room: room, lease: lease,
                        presentation: presentation, runtime: runtime
                    )
                    return
                }
                // Membership/media changes close the old player; source resolution is a later,
                // explicit transition. No automatic reuse of its URL or host-provided link.
                self.finishPlayback(reportBrowsing: false)
                if room?.playbackContext != nil { self.message = L10n.string("party_error_room_changed_title", fallback: "The room changed title. Choose your source again.") }
            }
        }
    }

    private func beginIncomingMediaTransition(
        from oldContext: WatchPartyPlaybackContext,
        to nextContext: WatchPartyPlaybackContext,
        media: WatchPartyMedia,
        service: WatchPartyService,
        room: WatchPartySession,
        lease: WatchPartyPlayerRuntime.Lease,
        presentation: Presentation,
        runtime: WatchPartyPlayerRuntime
    ) {
        let viewModel = lease.resource
        let plan = viewModel.incomingWatchPartyEpisodePlan(for: media)
        let transitionID = UUID()
        incomingMediaTransitionID = transitionID
        incomingMediaTransitionContext = nextContext

        // Detach synchronously before any source resolution. The old player remains alive,
        // but can no longer publish or apply room playback state for the previous episode.
        self.lease = nil
        preservePlayerAfterRoomExit = true
        runtime.abandon(lease)
        viewModel.pause(forBackground: true)
        viewModel.clearWatchPartyTransitionCallbacks()
        if self.presentation?.id == presentation.id { self.presentation = nil }
        incomingMediaTransition = IncomingMediaTransition(
            id: transitionID, context: nextContext, media: media,
            plan: plan, viewModel: viewModel
        )
    }
}
