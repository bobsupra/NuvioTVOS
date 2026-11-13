import SwiftUI

/// Private rooms; playback starts only after an explicit local source selection.
@MainActor
struct WatchPartyLobbyView: View {
    @ObservedObject var owner: WatchPartyAppOwner
    @ObservedObject var service: WatchPartyService
    var onChooseSharedSource: (WatchPartyStream) -> Void = { _ in }
    var onReturnToPlayer: () -> Void = {}
    let canUseAccount: Bool
    let isChoosing: Bool
    let onCreate: () -> Void
    let onChooseSource: (WatchPartyMedia) -> Void
    let onCancelSelection: () -> Void
    let onOpenProfile: () -> Void
    var detailsMedia: WatchPartyMedia? = nil
    var onRoomExited: (WatchPartyPlaybackContext) -> Void = { _ in }

    @State private var code = ""
    @State private var roomCodeIsEditing = false
    @State private var roomPreview: WatchPartyPreview?
    @State private var previewCode: String?
    @State private var previewRequestID = UUID()
    @State private var recentRoomPreview: WatchPartyRecentRoom?
    @State private var recentRoomPreviewMessage: String?
    @State private var reviewRoomID: String?
    @State private var reviewMediaKey: String?
    // Preserve the user's confirmed invitation until the server accepts the
    // membership; compare immediately when the room first becomes visible.
    @State private var pendingJoinMediaKey: String?
    @State private var pendingJoinCode: String?
    @State private var operation: Task<Void, Never>?
    @State private var endingRoom = false
    @State private var showingInvitation = false
    @FocusState private var focusedAction: String?
    @FocusState private var accountGateFocused: Bool
    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 30) {
                if !canUseAccount {
                    header
                    HStack(alignment: .top, spacing: 22) {
                        accountGateCard
                            .frame(maxWidth: .infinity)

                        Color.clear
                            .frame(maxWidth: .infinity)
                            .accessibilityHidden(true)
                    }
                } else if let room = service.session, let party = room.party {
                    roomContent(room, party: party)
                } else {
                    header
                    createAndJoinCards
                    recentRoomsSection
                }

                statusBlocks
            }
            .padding(.horizontal, 49) // Match LibraryGridMetrics.pageInset.
            .padding(.top, 56) // Match the Library page header inset.
            .padding(.bottom, 48)
        }
        .background {
            if canUseAccount, let media = service.session?.party?.media {
                roomBackdrop(WatchPartyDetailsPresentationPolicy.artwork(for: media, fallback: detailsMedia))
            } else {
                Color.nuvioBackground(amoled: amoled, body: bodyColor).ignoresSafeArea()
            }
        }
        .onAppear {
            if canUseAccount {
                focusedAction = preferredRoomFocus
            } else {
                accountGateFocused = true
            }
        }
        .onChange(of: code) { _, newValue in
            let normalized = String(WatchPartyCode.normalize(newValue).prefix(WatchPartyCode.length))
            if normalized != newValue { code = normalized }
            if previewCode != normalized {
                previewRequestID = UUID()
                roomPreview = nil
                previewCode = nil
            }
            if recentRoomPreview?.code != normalized {
                recentRoomPreview = nil
                recentRoomPreviewMessage = nil
            }
        }
        .onChange(of: service.session?.party?.code) { oldCode, newCode in
            guard oldCode == nil, newCode != nil, canUseAccount else { return }
            focusedAction = preferredRoomFocus
        }
        .sheet(isPresented: $showingInvitation) {
            if let party = service.session?.party, WatchPartyCode.isValid(party.code) {
                WatchPartyLobbyInvitation(code: WatchPartyCode.normalize(party.code))
            }
        }
        .onChange(of: service.session?.party?.id) { _, newID in
            showingInvitation = false
            // After join/leave/room replacement, a preview is no longer fresh.
            invalidateInvitationPreview()
            if reviewRoomID != newID {
                reviewRoomID = nil
                reviewMediaKey = nil
            }
            if let party = service.session?.party, let expected = pendingJoinMediaKey {
                // Check as soon as membership is published, not only after the
                // join RPC and realtime connection both finish.
                if WatchPartyMediaReviewPolicy.needsConfirmation(
                    previewKey: expected, joinedKey: party.media.key
                ) || WatchPartyCode.normalize(party.code) != pendingJoinCode {
                    reviewRoomID = party.id
                    reviewMediaKey = party.media.key
                    owner.message = "Room content changed since preview. Confirm the current title before choosing a source."
                }
            }
            pendingJoinMediaKey = nil
            pendingJoinCode = nil
            if canUseAccount { focusedAction = preferredRoomFocus }
        }
        .onChange(of: service.session?.party?.media.key) { oldKey, newKey in
            guard WatchPartyMediaReviewPolicy.changed(from: oldKey, to: newKey),
                  let party = service.session?.party, let newKey else { return }
            reviewRoomID = party.id
            reviewMediaKey = newKey
            focusedAction = preferredRoomFocus
        }
        .onChange(of: service.session?.connection) { _, _ in
            if canUseAccount { focusedAction = preferredRoomFocus }
        }
        .onChange(of: service.session?.membershipExit) { _, _ in
            if canUseAccount { focusedAction = preferredRoomFocus }
        }
        .onChange(of: canUseAccount) { _, allowed in
            accountGateFocused = !allowed
            if !allowed {
                invalidateInvitationPreview()
                reviewRoomID = nil
                reviewMediaKey = nil
                pendingJoinMediaKey = nil
                pendingJoinCode = nil
            }
            focusedAction = allowed ? preferredRoomFocus : nil
        }
        .onReceive(service.contextDidInvalidate) { _ in
            // An invitation preview belongs to one authenticated environment.
            // A profile/account/server switch must not leave an old preview
            // available for confirmation in a different context.
            invalidateInvitationPreview()
            reviewRoomID = nil
            reviewMediaKey = nil
            pendingJoinMediaKey = nil
            pendingJoinCode = nil
            showingInvitation = false
            focusedAction = nil
        }
        .onChange(of: service.busy) { _, busy in
            if !busy && canUseAccount && focusedAction == nil && operation == nil {
                focusedAction = preferredRoomFocus
            }
        }
        .onChange(of: owner.presentation?.id) { _, _ in
            if canUseAccount { focusedAction = preferredRoomFocus }
        }
        .confirmationDialog(L10n.string("party_end_room_everyone_desc", fallback: "End this room for everyone?"), isPresented: $endingRoom) {
            Button(L10n.string("party_end_room_confirm_title", fallback: "End room"), role: .destructive) {
                leaveRoom(endForEveryone: true)
            }
            Button(L10n.string("action_cancel", fallback: "Cancel"), role: .cancel) {}
        }
    }

    private func invalidateInvitationPreview() {
        previewRequestID = UUID()
        roomPreview = nil
        previewCode = nil
        recentRoomPreview = nil
        recentRoomPreviewMessage = nil
        roomCodeIsEditing = false
    }

    private var needsMediaReview: Bool {
        guard let party = service.session?.party else { return false }
        return reviewRoomID == party.id && reviewMediaKey == party.media.key
    }

    private var preferredRoomFocus: String? {
        let room = service.session
        return WatchPartyRoomFocusPolicy.initialAction(
            hasRoom: room?.party != nil,
            membershipEnded: room?.membershipExit != nil,
            connectionReady: room?.connection == .ready,
            playerAttached: owner.presentation?.mount.isCurrent == true,
            busy: service.busy || operation != nil,
            needsMediaReview: needsMediaReview
        )
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(TVTab.party.title)
                .font(.system(size: 42, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Text(L10n.string("party_lobby_header_subtitle", fallback: "Create a private room or join a friend with their room code."))
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 4)
    }

    private func activeRoomHeader(room: WatchPartySession, party: WatchPartyInfo) -> some View {
        let defaultHost = L10n.string("party_your_friends", fallback: "your friends")
        let hostName = room.members.first(where: { $0.id == party.hostMemberID })?.displayName ?? defaultHost
        return VStack(alignment: .leading, spacing: 8) {
            Text(L10n.string("party_title", fallback: "Watch party"))
                .font(.system(size: 52, weight: .regular))
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.format("party_hosted_by", fallback: "Hosted by %@", hostName))
                    .font(.system(size: 31, weight: .regular))
                    .foregroundStyle(.white.opacity(0.74))
                Text(L10n.format("party_seats_count", fallback: "%d of %d seats", room.members.count, party.maxMembers))
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
            }
        }
    }

    @ViewBuilder
    private func roomBackdrop(_ media: WatchPartyMedia) -> some View {
        GeometryReader { proxy in
            ZStack {
                Color.nuvioBackground(amoled: amoled, body: bodyColor)
                if let image = media.background ?? media.poster,
                   let url = URL(string: image.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    AsyncImage(url: url) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFill()
                        } else {
                            Color.nuvioBackground(amoled: amoled, body: bodyColor)
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
                }

                Color.black.opacity(0.24)
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.80), location: 0),
                        .init(color: .black.opacity(0.60), location: 0.38),
                        .init(color: .black.opacity(0.28), location: 0.72),
                        .init(color: .black.opacity(0.62), location: 1)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                LinearGradient(
                    colors: [.black.opacity(0.24), .clear, .black.opacity(0.42)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
    }

    private var createAndJoinCards: some View {
        HStack(alignment: .top, spacing: 22) {
            joinRoomCard
            createRoomCard
        }
    }

    private var recentRoomsSection: some View {
        let rooms = service.recentRooms()
        return VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string("party_recent_rooms", fallback: "Recent rooms"))
                .font(.system(size: 27, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            if rooms.isEmpty {
                Text(L10n.string("party_recent_rooms_empty", fallback: "Rooms you join or create will appear here."))
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
                    .padding(.vertical, 18)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 18) {
                        ForEach(rooms) { room in
                            Button {
                                selectRecentRoom(room)
                            } label: {
                                recentRoomTile(room)
                            }
                            .buttonStyle(PosterCardButtonStyle())
                            .focusEffectDisabledIfAvailable()
                            .focused($focusedAction, equals: recentRoomFocusID(room))
                            .disabled(service.busy || operation != nil)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    private func recentRoomTile(_ room: WatchPartyRecentRoom) -> some View {
        let isFocused = focusedAction == recentRoomFocusID(room)
        return HStack(alignment: .center, spacing: 16) {
            recentRoomArtwork(room.poster, title: room.title)

            VStack(alignment: .leading, spacing: 8) {
                Text(room.title.isEmpty ? L10n.string("party_untitled_room", fallback: "Untitled room") : room.title)
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if let episode = recentRoomEpisodeDescription(room) {
                    Text(episode)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(2)
                }

                Text(L10n.format("party_code_with_value", fallback: "Code · %@", WatchPartyCode.formatted(room.code)))
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.86))
                    .lineLimit(1)

                Text(L10n.format("party_members_count", fallback: "%d of %d members", room.memberCount, room.maxMembers))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.64))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(width: 390, height: 166, alignment: .leading)
        .modifier(LiquidGlassSurface(cornerRadius: 24))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(
                    isFocused ? AppFocusOutline.color : Color.clear,
                    lineWidth: isFocused ? AppFocusOutline.width : 0
                )
        }
        .scaleEffect(isFocused ? 1.035 : 1)
        .animation(.easeOut(duration: 0.14), value: isFocused)
    }

    @ViewBuilder
    private func recentRoomArtwork(_ poster: String?, title: String) -> some View {
        if let poster,
           let url = URL(string: poster.trimmingCharacters(in: .whitespacesAndNewlines)),
           url.scheme?.lowercased() == "https" {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    recentRoomArtworkFallback(title)
                }
            }
            .frame(width: 84, height: 126)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityHidden(true)
        } else {
            recentRoomArtworkFallback(title)
        }
    }

    private func recentRoomArtworkFallback(_ title: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(0.1))
            Image(systemName: "film")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.white.opacity(0.68))
        }
        .frame(width: 84, height: 126)
        .accessibilityLabel(title.isEmpty ? "Room artwork unavailable" : "Artwork for \(title)")
    }

    private func recentRoomEpisodeDescription(_ room: WatchPartyRecentRoom) -> String? {
        guard let season = room.season, let episode = room.episode else { return nil }
        let number = "Season \(season) · Episode \(episode)"
        guard let title = room.episodeTitle, !title.isEmpty else { return number }
        return "\(number) · \(title)"
    }

    private func recentRoomFocusID(_ room: WatchPartyRecentRoom) -> String {
        "recent-room-\(room.roomID)"
    }

    private func selectRecentRoom(_ room: WatchPartyRecentRoom) {
        invalidateInvitationPreview()
        let requestedCode = WatchPartyCode.normalize(room.code)
        let requestID = UUID()
        code = requestedCode
        previewCode = requestedCode
        previewRequestID = requestID
        recentRoomPreview = room
        recentRoomPreviewMessage = "Checking if this room is still active…"

        run {
            do {
                let result = try await service.preview(code: requestedCode)
                guard previewRequestID == requestID,
                      WatchPartyCode.normalize(code) == requestedCode else { return }
                guard result.error == nil, let media = result.media else {
                    recentRoomPreviewMessage = "Room preview unavailable. Showing saved room details."
                    focusedAction = "recent-room-preview-change"
                    return
                }
                try WatchPartyLaunchPolicy.validate(media)
                roomPreview = result
                recentRoomPreview = nil
                recentRoomPreviewMessage = nil
                focusedAction = "join"
            } catch {
                guard previewRequestID == requestID,
                      WatchPartyCode.normalize(code) == requestedCode else { return }
                recentRoomPreviewMessage = recentRoomPreviewFailureMessage(error)
                focusedAction = "recent-room-preview-change"
            }
        }
    }

    private func recentRoomPreviewFailureMessage(_ error: Error) -> String {
        guard let serviceError = error as? WatchPartyServiceError,
              case let .rejected(failure) = serviceError else {
            return L10n.string("party_saved_details_fallback", fallback: "Couldn't check this room. Showing saved room details.")
        }
        switch failure {
        case .ended:
            return L10n.string("party_recent_room_ended", fallback: "This room has ended. Showing saved session details.")
        case .notFound:
            return L10n.string("party_recent_room_not_found", fallback: "This room is no longer available. Showing saved session details.")
        case .full:
            return L10n.string("party_recent_room_full", fallback: "This room is full. Showing saved room details.")
        default:
            return L10n.string("party_saved_details_fallback", fallback: "Couldn't check this room. Showing saved room details.")
        }
    }

    private var createRoomCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardHeading(
                symbol: "plus.circle.fill",
                title: L10n.string("party_create_room_title", fallback: "Create a room"),
                subtitle: L10n.string("party_create_room_subtitle", fallback: "Choose a movie or episode, then invite everyone with your room code.")
            )

            Spacer(minLength: 20)

            Text(L10n.string("party_start_paused_hint", fallback: "Rooms start paused. Press Play when your source is ready."))
                .font(.system(size: 17))
                .foregroundStyle(.white.opacity(0.62))
                .padding(.bottom, 12)

            Button {
                owner.message = nil
                onCreate()
            } label: {
                primaryActionLabel(
                    symbol: "plus",
                    title: L10n.string("party_choose_title", fallback: "Choose a title"),
                    subtitle: L10n.string("party_start_private_room_subtitle", fallback: "Start a new private room"),
                    isFocused: focusedAction == "create",
                    emphasized: true
                )
            }
            .buttonStyle(PosterCardButtonStyle())
            .focusEffectDisabledIfAvailable()
            .focused($focusedAction, equals: "create")
            .onMoveCommand { direction in
                if direction == .left {
                    focusedAction = WatchPartyCode.isValid(code) ? "join" : "room-code"
                }
            }
            .disabled(service.busy || operation != nil || service.membershipOutcomeUncertain)
        }
        .padding(28)
        .frame(maxWidth: .infinity, minHeight: 360, alignment: .topLeading)
        .modifier(LiquidGlassSurface(cornerRadius: 30, prominent: true))
    }

    private var joinRoomCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardHeading(
                symbol: "person.2.fill",
                title: L10n.string("party_join_room_title", fallback: "Join a room"),
                subtitle: L10n.string("party_join_room_subtitle", fallback: "Enter the six-character code shared by the room's host.")
            )

            Spacer(minLength: 16)

            HStack {
                Text(L10n.string("party_room_code_header", fallback: "ROOM CODE · 6 CHARACTERS"))
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.66))
                Spacer()
                Text("\(code.count)/\(WatchPartyCode.length)")
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.bottom, 10)

            GeometryReader { geometry in
                Button {
                    roomCodeIsEditing = true
                } label: {
                    SettingsGlassTextField(
                        text: $code,
                        placeholder: L10n.string("party_room_code_placeholder", fallback: "Room Code"),
                        focused: focusedAction == "room-code",
                        isEditing: $roomCodeIsEditing,
                        fieldWidth: geometry.size.width,
                        centerDisplayText: true,
                        keyboardType: .asciiCapable,
                        onCommit: { roomCodeIsEditing = false }
                    )
                }
                .buttonStyle(PosterCardButtonStyle())
                .focusEffectDisabledIfAvailable()
                .accessibilityLabel(L10n.string("party_room_code_accessibility", fallback: "Six-character room code"))
                .focused($focusedAction, equals: "room-code")
                .onMoveCommand { direction in
                    if direction == .right { focusedAction = "create" }
                }
            }
            .frame(height: 48)

            Spacer(minLength: 12)

            if let preview = roomPreview, previewCode == WatchPartyCode.normalize(code),
               let media = preview.media {
                roomPreviewCard(preview, media: media)
            } else if let recentRoomPreview,
                      recentRoomPreview.code == WatchPartyCode.normalize(code) {
                recentRoomPreviewCard(recentRoomPreview)
            } else {
                Button {
                    let requestedCode = WatchPartyCode.normalize(code)
                    let requestID = UUID()
                    previewRequestID = requestID
                    run {
                        let result = try await service.preview(code: requestedCode)
                        guard previewRequestID == requestID,
                              WatchPartyCode.normalize(code) == requestedCode else { return }
                        guard result.error == nil, let media = result.media else {
                            owner.message = L10n.string("party_preview_unavailable", fallback: "Room preview unavailable. Check the invitation code.")
                            return
                        }
                        try WatchPartyLaunchPolicy.validate(media)
                        roomPreview = result
                        previewCode = requestedCode
                        focusedAction = "join"
                    }
                } label: {
                    primaryActionLabel(
                        symbol: "eye",
                        title: L10n.string("party_preview_room_title", fallback: "Preview room"),
                        subtitle: L10n.string("party_preview_room_subtitle", fallback: "Check the host and exact movie or episode before joining"),
                        isFocused: focusedAction == "preview"
                    )
                }
                .buttonStyle(PosterCardButtonStyle())
                .focusEffectDisabledIfAvailable()
                .focused($focusedAction, equals: "preview")
                .onMoveCommand { direction in
                    if direction == .right { focusedAction = "create" }
                }
                .disabled(service.busy || operation != nil || !WatchPartyCode.isValid(code)
                    || service.membershipOutcomeUncertain)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, minHeight: 360, alignment: .topLeading)
        .modifier(LiquidGlassSurface(cornerRadius: 30, prominent: true))
    }

    private func recentRoomPreviewCard(_ room: WatchPartyRecentRoom) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("party_saved_session_header", fallback: "SAVED SESSION DETAILS"))
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.65))

            HStack(alignment: .top, spacing: 14) {
                recentRoomArtwork(room.poster, title: room.title)

                VStack(alignment: .leading, spacing: 7) {
                    Text(room.title.isEmpty ? L10n.string("party_untitled_room", fallback: "Untitled room") : room.title)
                        .font(.system(size: 23, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    if let episode = recentRoomEpisodeDescription(room) {
                        Text(episode)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(2)
                    }
                    Text(L10n.format("party_hosted_by", fallback: "Hosted by %@", room.hostName))
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text(L10n.format("party_participants_when_last_joined", fallback: "%d of %d participants when last joined", room.memberCount, room.maxMembers))
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(2)
            Text(L10n.format("party_last_joined", fallback: "Last joined %@", room.lastUsed.formatted(date: .abbreviated, time: .shortened)))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))

            if let message = recentRoomPreviewMessage {
                Text(message)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.84))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                invalidateInvitationPreview()
                focusedAction = "room-code"
            } label: {
                primaryActionLabel(
                    symbol: "pencil",
                    title: L10n.string("party_enter_another_code_title", fallback: "Enter another room code"),
                    subtitle: L10n.string("party_enter_another_code_subtitle", fallback: "Use a different invitation code"),
                    isFocused: focusedAction == "recent-room-preview-change"
                )
            }
            .buttonStyle(PosterCardButtonStyle())
            .focusEffectDisabledIfAvailable()
            .focused($focusedAction, equals: "recent-room-preview-change")
        }
        .padding(18)
        .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 18))
    }

    private func roomPreviewCard(_ preview: WatchPartyPreview, media: WatchPartyMedia) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("party_invitation_preview_header", fallback: "INVITATION PREVIEW"))
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.65))
            HStack(alignment: .top, spacing: 14) {
                if let raw = media.poster, let url = URL(string: raw),
                   url.scheme?.lowercased() == "https" {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            Color.white.opacity(0.08)
                        }
                    }
                    .frame(width: 82, height: 122)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(media.title.isEmpty ? L10n.string("party_untitled_room", fallback: "Untitled room") : media.title)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    if let episode = episodeDescription(media) {
                        Text(episode).font(.system(size: 17))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    let hostName = preview.host.flatMap { $0.displayName.isEmpty ? nil : $0.displayName } ?? L10n.string("party_host_label", fallback: "Host")
                    Text(L10n.format("party_hosted_by", fallback: "Hosted by %@", hostName))
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
            Text(L10n.format("party_participants_count", fallback: "%d of %d participants", preview.members, preview.maxMembers))
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.7))
            Button {
                let expectedCode = WatchPartyCode.normalize(code)
                let expectedKey = media.key
                guard previewCode == expectedCode,
                      roomPreview?.media?.key == expectedKey else { return }
                pendingJoinMediaKey = expectedKey
                pendingJoinCode = expectedCode
                onCancelSelection()
                run {
                    do {
                        try await service.join(code: expectedCode)
                    } catch {
                        pendingJoinMediaKey = nil
                        pendingJoinCode = nil
                        throw error
                    }
                    if let joined = service.session?.party,
                       WatchPartyMediaReviewPolicy.needsConfirmation(
                           previewKey: expectedKey, joinedKey: joined.media.key
                       ) {
                        reviewRoomID = joined.id
                        reviewMediaKey = joined.media.key
                        owner.message = L10n.string("party_content_changed_notice", fallback: "Room content changed since preview. Confirm the current title before choosing a source.")
                        focusedAction = "review-room"
                    }
                }
            } label: {
                primaryActionLabel(symbol: "checkmark.circle", title: L10n.string("party_join_this_room_title", fallback: "Join this room"),
                                   subtitle: L10n.string("party_join_this_room_subtitle", fallback: "Confirm this movie or episode"),
                                   isFocused: focusedAction == "join")
            }
            .buttonStyle(PosterCardButtonStyle())
            .focusEffectDisabledIfAvailable()
            .focused($focusedAction, equals: "join")
            .disabled(service.busy || operation != nil || preview.isFull || service.membershipOutcomeUncertain)
            Button(L10n.string("party_change_room_code", fallback: "Change room code")) {
                previewRequestID = UUID()
                roomPreview = nil
                previewCode = nil
                focusedAction = "room-code"
            }
            .buttonStyle(PosterCardButtonStyle())
        }
        .padding(18)
        .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 18))
    }

    private var accountGateCard: some View {
        Button(action: onOpenProfile) {
            primaryActionLabel(
                symbol: "person.crop.circle.badge.checkmark",
                title: L10n.string("party_profile_gate_title", fallback: "Choose a profile to continue"),
                subtitle: L10n.string("party_profile_gate_subtitle", fallback: "Sign in to create or join a Watch Party."),
                isFocused: accountGateFocused
            )
        }
        .buttonStyle(PosterCardButtonStyle())
        .focusEffectDisabledIfAvailable()
        .focused($accountGateFocused)
    }

    private func roomContent(_ room: WatchPartySession, party: WatchPartyInfo) -> some View {
        HStack(alignment: .top, spacing: 56) {
            VStack(alignment: .leading, spacing: 30) {
                activeRoomHeader(room: room, party: party)
                roomSummaryCard(room, party: party)
            }
                .frame(maxWidth: .infinity, alignment: .leading)

            roomActions(room, party: party)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 14)
        .frame(minHeight: 600, alignment: .top)
    }

    private func roomSummaryCard(_ room: WatchPartySession, party: WatchPartyInfo) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            roomMediaLogo(WatchPartyDetailsPresentationPolicy.artwork(for: party.media, fallback: detailsMedia))

            if let episode = episodeDescription(party.media) {
                Text(episode)
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
            }

            if let description = party.media.description, !description.isEmpty {
                Text(description)
                    .font(.system(size: 23, weight: .regular))
                    .foregroundStyle(.white.opacity(0.76))
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }

            membersList(room, party: party)
            roomCodeDisplay(party.code)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func roomMediaLogo(_ media: WatchPartyMedia) -> some View {
        Group {
            if let rawURL = media.logo,
               let url = URL(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)) {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFit()
                    } else {
                        roomTitleFallback(media.title)
                    }
                }
            } else {
                roomTitleFallback(media.title)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 142, maxHeight: 142, alignment: .leading)
        .accessibilityLabel(media.title)
    }

    private func roomTitleFallback(_ title: String) -> some View {
        Text(title.isEmpty ? L10n.string("nav_watch_party", fallback: "Watch Party") : title)
            .font(.system(size: 58, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .lineLimit(2)
            .minimumScaleFactor(0.72)
            .shadow(color: .black.opacity(0.55), radius: 12, y: 5)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func roomCodeDisplay(_ code: String) -> some View {
        let characters = Array(WatchPartyCode.normalize(code))
        return VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string("party_code_label", fallback: "Party code"))
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(.white.opacity(0.68))
            HStack(spacing: 14) {
                ForEach(characters.indices, id: \.self) { index in
                    VStack(spacing: 12) {
                        Text(String(characters[index]))
                            .font(.system(size: 48, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Rectangle()
                            .fill(.white.opacity(0.68))
                            .frame(height: 3)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.format("party_code_accessibility", fallback: "Party code %@", WatchPartyCode.formatted(code)))
    }

    private func membersList(_ room: WatchPartySession, party: WatchPartyInfo) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if room.members.isEmpty {
                Text(L10n.string("party_waiting_viewers", fallback: "Waiting for viewers to join…"))
                    .font(.system(size: 17))
                    .foregroundStyle(.white.opacity(0.65))
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 18) {
                        ForEach(room.members, id: \.id) { member in
                            memberTile(member, room: room, party: party)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func memberAvatar(_ member: WatchPartyMember, size: CGFloat) -> some View {
        if let rawURL = member.avatarURL,
           let url = URL(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)) {
            AsyncImage(url: url) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    memberInitial(member, size: size)
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
        } else {
            memberInitial(member, size: size)
        }
    }

    private func memberInitial(_ member: WatchPartyMember, size: CGFloat) -> some View {
        Text(member.displayName.trimmingCharacters(in: .whitespacesAndNewlines).first.map { String($0).uppercased() } ?? "?")
            .font(.system(size: size * 0.4, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(.white.opacity(0.14), in: Circle())
    }

    private func memberTile(_ member: WatchPartyMember, room: WatchPartySession, party: WatchPartyInfo) -> some View {
        let isHost = member.id == party.hostMemberID
        return VStack(spacing: 10) {
            memberAvatar(member, size: 120)

            VStack(alignment: .center, spacing: 6) {
                HStack(spacing: 8) {
                    if isHost {
                        Image(systemName: "crown.fill")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(Color(red: 0.98, green: 0.76, blue: 0.28))
                    }
                    Text(member.displayName.isEmpty ? L10n.string("party_viewer_label", fallback: "Viewer") : member.displayName)
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                Text(presenceLabel(room.presence[member.id]?.status))
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .frame(width: 180, alignment: .top)
        .padding(.vertical, 8)
    }

    private func roomActions(_ room: WatchPartySession, party: WatchPartyInfo) -> some View {
        let actionColumns = [GridItem(.flexible()), GridItem(.flexible())]
        return VStack(alignment: .leading, spacing: 14) {
            let hostName = room.members.first(where: { $0.id == party.hostMemberID })?.displayName
            // Only a known guest can receive a host-stream status. An unknown
            // member/host ID is not enough to infer guest privileges.
            let isGuest = room.memberID != nil && party.hostMemberID != nil
                && room.memberID != party.hostMemberID
            if let notice = WatchPartySharedSourceNotice.text(
                hostName: hostName, stream: room.sharedStream,
                mediaKey: party.media.key, isGuest: isGuest,
                connected: room.connection == .ready && room.membershipExit == nil
            ) {
                statusRow(symbol: "antenna.radiowaves.left.and.right",
                          title: notice, tint: .white)
            }

            if needsMediaReview {
                let episodeSuffix = episodeDescription(party.media).map { " · " + $0 } ?? ""
                let changedTitle = "\(party.media.title)\(episodeSuffix)"
                statusRow(symbol: "exclamationmark.triangle.fill",
                          title: L10n.format("party_room_changed_status", fallback: "The room changed to %@. Confirm before choosing a source.", changedTitle),
                          tint: .orange)
            }

            LazyVGrid(columns: actionColumns, alignment: .leading, spacing: 12) {
                if isGuest, let stream = room.sharedStream, stream.mediaKey == party.media.key,
                   !needsMediaReview, room.connection == .ready, room.membershipExit == nil {
                    Button {
                        onChooseSharedSource(stream)
                    } label: {
                        roomActionLabel(
                            symbol: "play.fill",
                            title: L10n.string("party_use_host_source_title", fallback: "Use host's source · BETA"),
                            subtitle: L10n.string("party_use_host_source_subtitle", fallback: "Play the compatible source shared by the host"),
                            isFocused: focusedAction == "use-host-source"
                        )
                    }
                    .buttonStyle(PosterCardButtonStyle())
                    .focusEffectDisabledIfAvailable()
                    .focused($focusedAction, equals: "use-host-source")
                    .disabled(service.busy || operation != nil || isChoosing)
                }
                if isGuest, room.sharedStream == nil, !needsMediaReview,
                   room.connection == .ready, room.membershipExit == nil {
                    Button {
                        run {
                            let sent = try await room.requestHostStreamRefresh()
                            owner.message = sent
                                ? L10n.string("party_source_refresh_requested", fallback: "Source refresh requested. If the host is online and sharing, the source should appear shortly.")
                                : L10n.string("party_source_refresh_wait", fallback: "Please wait a few seconds before requesting the source again.")
                        }
                    } label: {
                        roomActionLabel(
                            symbol: "arrow.clockwise",
                            title: L10n.string("party_refresh_host_source_title", fallback: "Refresh host's shared source · BETA"),
                            subtitle: L10n.string("party_refresh_host_source_subtitle", fallback: "Ask the host to refresh the shared source"),
                            isFocused: focusedAction == "refresh-host-source"
                        )
                    }
                    .buttonStyle(PosterCardButtonStyle())
                    .focusEffectDisabledIfAvailable()
                    .focused($focusedAction, equals: "refresh-host-source")
                    .disabled(service.busy || operation != nil)
                }
                if needsMediaReview {
                    Button {
                        guard room.party?.id == reviewRoomID,
                              room.party?.media.key == reviewMediaKey,
                              room.connection == .ready, room.membershipExit == nil else { return }
                        reviewRoomID = nil
                        reviewMediaKey = nil
                        owner.message = nil
                        focusedAction = preferredRoomFocus
                    } label: {
                        roomActionLabel(
                            symbol: "checkmark.shield",
                            title: L10n.string("party_confirm_title_action", fallback: "Confirm current movie or episode"),
                            subtitle: L10n.string("party_confirm_title_subtitle", fallback: "Verify this title before selecting a source"),
                            isFocused: focusedAction == "review-room"
                        )
                    }
                    .buttonStyle(PosterCardButtonStyle())
                    .focusEffectDisabledIfAvailable()
                    .focused($focusedAction, equals: "review-room")
                    .disabled(service.busy || operation != nil || room.connection != .ready
                        || room.membershipExit != nil)
                } else {
                    primaryRoomAction(room, party: party)
                }

                Button {
                    showingInvitation = true
                } label: {
                    roomActionLabel(
                        symbol: "qrcode",
                        title: L10n.string("party_invite_friend", fallback: "Invite a friend"),
                        subtitle: L10n.string("party_invite_friend_subtitle", fallback: "Share this room's code with someone"),
                        isFocused: focusedAction == "invite"
                    )
                }
                .buttonStyle(PosterCardButtonStyle())
                .focused($focusedAction, equals: "invite")
                .disabled(service.busy || operation != nil || room.connection != .ready || room.membershipExit != nil || !WatchPartyCode.isValid(party.code))

                if room.connection != .ready, room.membershipExit == nil {
                    Button {
                        run { try await service.resume() }
                    } label: {
                        roomActionLabel(
                            symbol: "arrow.clockwise",
                            title: L10n.string("party_reconnect_title", fallback: "Reconnect"),
                            subtitle: L10n.string("party_reconnect_subtitle", fallback: "Restore the room connection"),
                            isFocused: focusedAction == "reconnect"
                        )
                    }
                    .buttonStyle(PosterCardButtonStyle())
                    .focusEffectDisabledIfAvailable()
                    .focused($focusedAction, equals: "reconnect")
                    .disabled(service.busy || operation != nil)
                }

                Button {
                    leaveRoom()
                } label: {
                    roomActionLabel(
                        symbol: "rectangle.portrait.and.arrow.right",
                        title: L10n.string("party_leave_room_title", fallback: "Leave room"),
                        subtitle: L10n.string("party_leave_room_subtitle", fallback: "Leave this Watch Party"),
                        isFocused: focusedAction == "leave"
                    )
                }
                .buttonStyle(PosterCardButtonStyle())
                .focusEffectDisabledIfAvailable()
                .focused($focusedAction, equals: "leave")
                .disabled(service.busy || operation != nil)

                if party.hostMemberID == room.memberID {
                    Button(role: .destructive) {
                        endingRoom = true
                    } label: {
                        roomActionLabel(
                            symbol: "xmark.circle",
                            title: L10n.string("party_end_room_everyone_title", fallback: "End room for everyone"),
                            subtitle: L10n.string("party_end_room_everyone_subtitle", fallback: "Close this room for all members"),
                            isFocused: focusedAction == "end"
                        )
                    }
                    .buttonStyle(PosterCardButtonStyle())
                    .focusEffectDisabledIfAvailable()
                    .focused($focusedAction, equals: "end")
                    .disabled(service.busy || operation != nil)
                }
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, minHeight: 320, alignment: .topLeading)
        .modifier(LiquidGlassSurface(cornerRadius: 32))
    }

    @ViewBuilder
    private func primaryRoomAction(_ room: WatchPartySession, party: WatchPartyInfo) -> some View {
        if owner.presentation?.mount.isCurrent == true {
            Button {
                onReturnToPlayer()
            } label: {
                roomActionLabel(
                    symbol: "play.rectangle.fill",
                    title: L10n.string("party_return_to_player_title", fallback: "Return to player"),
                    subtitle: L10n.string("party_return_to_player_subtitle", fallback: "Resume fullscreen playback"),
                    isFocused: focusedAction == "return-to-player"
                )
            }
            .buttonStyle(PosterCardButtonStyle())
            .focusEffectDisabledIfAvailable()
            .focused($focusedAction, equals: "return-to-player")
            .disabled(service.busy || operation != nil || room.membershipExit != nil)

            Button {
                guard let presentation = owner.presentation, presentation.mount.isCurrent else { return }
                presentation.mount.viewModel.catchUpWithWatchParty()
            } label: {
                roomActionLabel(
                    symbol: "arrow.down.to.line",
                    title: L10n.string("party_catch_up_title", fallback: "Catch up with room"),
                    subtitle: L10n.string("party_catch_up_subtitle", fallback: "Return to the shared playback position"),
                    isFocused: focusedAction == "catch-up"
                )
            }
            .buttonStyle(PosterCardButtonStyle())
            .focusEffectDisabledIfAvailable()
            .focused($focusedAction, equals: "catch-up")
            .disabled(service.busy || operation != nil || room.connection != .ready)
        } else {
            Button {
                onChooseSource(party.media)
            } label: {
                roomActionLabel(
                    symbol: "play.fill",
                    title: L10n.string("party_choose_my_source_title", fallback: "Choose my source"),
                    subtitle: L10n.string("party_choose_my_source_subtitle", fallback: "Pick any source you have for this title or episode"),
                    isFocused: focusedAction == "choose-source"
                )
            }
            .buttonStyle(PosterCardButtonStyle())
            .focusEffectDisabledIfAvailable()
            .focused($focusedAction, equals: "choose-source")
            .disabled(service.busy || operation != nil || room.connection != .ready || room.membershipExit != nil)
        }
    }

    @ViewBuilder
    private var statusBlocks: some View {
        if hasStatusContent {
            VStack(alignment: .leading, spacing: 14) {
                if service.busy || operation != nil {
                    HStack(spacing: 14) {
                        ProgressView()
                        Text(L10n.string("party_contacting_room", fallback: "Contacting room…"))
                            .font(.system(size: 19, weight: .medium))
                            .foregroundStyle(.white)
                    }
                }

                if let message = owner.message {
                    statusRow(symbol: "exclamationmark.triangle.fill", title: message, tint: .orange)
                }
                if let failure = service.failure {
                    statusRow(symbol: "exclamationmark.triangle.fill", title: failureText(failure), tint: .orange)
                }
                if service.session?.membershipExit != nil {
                    statusRow(
                        symbol: "person.crop.circle.badge.xmark",
                        title: membershipExitMessage,
                        tint: .orange
                    )
                }
                if service.membershipOutcomeUncertain {
                    statusRow(
                        symbol: "questionmark.circle.fill",
                        title: L10n.string("party_uncertain_outcome_message", fallback: "The server may have accepted the last request. Check the room with its host before trying again."),
                        tint: .yellow
                    )
                    Button {
                        service.acknowledgeUncertainMembershipOutcome()
                    } label: {
                        secondaryActionLabel(
                            symbol: "checkmark.circle",
                            title: L10n.string("party_uncertain_outcome_ack", fallback: "I checked — allow a new attempt"),
                            isFocused: focusedAction == "allow-retry"
                        )
                    }
                    .buttonStyle(PosterCardButtonStyle())
                    .focusEffectDisabledIfAvailable()
                    .focused($focusedAction, equals: "allow-retry")
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(LiquidGlassSurface(cornerRadius: 22))
        }
    }

    private var hasStatusContent: Bool {
        service.busy || operation != nil || owner.message != nil || service.failure != nil
            || service.session?.membershipExit != nil || service.membershipOutcomeUncertain
    }

    private func cardHeading(symbol: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 18) {
            Image(systemName: symbol)
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 17))
                    .foregroundStyle(.white.opacity(0.68))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func primaryActionLabel(
        symbol: String,
        title: String,
        subtitle: String,
        isFocused: Bool = false,
        emphasized: Bool = false
    ) -> some View {
        HStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 25, weight: .bold))
                .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                Text(subtitle)
                    .font(.system(size: 16, weight: .medium))
                    .opacity(0.78)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 17, weight: .bold))
        }
        .foregroundStyle(isFocused ? Color.black.opacity(0.92) : Color.white)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isFocused ? Color.white.opacity(0.98) : Color.white.opacity(emphasized ? 0.22 : 0.08))
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    isFocused ? AppFocusOutline.color : Color.white.opacity(emphasized ? 0.34 : 0.18),
                    lineWidth: isFocused ? AppFocusOutline.width : 1
                )
        }
        .scaleEffect(isFocused ? 1.035 : 1)
        .animation(.easeOut(duration: 0.14), value: isFocused)
    }

    private func secondaryActionLabel(symbol: String, title: String, isFocused: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(isFocused ? Color.black.opacity(0.92) : Color.white.opacity(0.9))
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, minHeight: 66)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isFocused ? Color.white.opacity(0.98) : Color.white.opacity(0.08))
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isFocused ? AppFocusOutline.color : Color.white.opacity(0.15), lineWidth: AppFocusOutline.width)
        }
        .scaleEffect(isFocused ? 1.035 : 1)
        .animation(.easeOut(duration: 0.14), value: isFocused)
    }

    @ViewBuilder
    private func roomActionLabel(
        symbol: String,
        title: String,
        subtitle: String,
        isFocused: Bool
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        let label = VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(isFocused ? Color.black.opacity(0.9) : Color.white.opacity(0.92))
                    .frame(width: 26)
                Text(title)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(isFocused ? Color.black.opacity(0.95) : Color.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
            }
            Text(subtitle)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isFocused ? Color.black.opacity(0.68) : Color.white.opacity(0.68))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 36)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 124, alignment: .leading)

        if #available(tvOS 26.0, *), AppleTVCapability.current.supportsLiquidGlass {
            label
                .background(
                    shape.fill(isFocused ? Color.white.opacity(0.08) : Color.black.opacity(0.22))
                )
                .glassEffect(
                    isFocused
                        ? Glass.regular.tint(.white.opacity(0.92))
                        : Glass.regular,
                    in: shape
                )
                .overlay {
                    shape.strokeBorder(
                        isFocused ? AppFocusOutline.color : Color.white.opacity(0.18),
                        lineWidth: isFocused ? AppFocusOutline.width : 1
                    )
                }
                .scaleEffect(isFocused ? 1.025 : 1)
                .animation(.easeOut(duration: 0.14), value: isFocused)
        } else {
            label
                .background {
                    ZStack {
                        shape.fill(.ultraThinMaterial)
                        shape.fill(isFocused ? Color.white.opacity(0.96) : Color.black.opacity(0.26))
                    }
                }
                .overlay {
                    shape.strokeBorder(
                        isFocused ? AppFocusOutline.color : Color.white.opacity(0.18),
                        lineWidth: isFocused ? AppFocusOutline.width : 1
                    )
                }
                .scaleEffect(isFocused ? 1.025 : 1)
                .animation(.easeOut(duration: 0.14), value: isFocused)
        }
    }

    private func statusRow(symbol: String, title: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26)
            Text(title)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func episodeDescription(_ media: WatchPartyMedia) -> String? {
        guard let season = media.season, let episode = media.episode else { return nil }
        let number = L10n.format("party_season_episode_format", fallback: "Season %1$d · Episode %2$d", season, episode)
        guard let title = media.episodeTitle, !title.isEmpty else { return number }
        return "\(number) · \(title)"
    }

    private var membershipExitMessage: String {
        if service.session?.party != nil {
            return L10n.string("party_membership_ended_leave", fallback: "This membership ended. Leave this room before joining again.")
        }
        return L10n.string("party_membership_ended_new_request", fallback: "Your previous room membership ended. Joining again requires a new request.")
    }

    private func presenceLabel(_ status: WatchPartyMemberStatus?) -> String {
        switch status ?? .browsing {
        case .browsing: return L10n.string("party_status_browsing", fallback: "Browsing")
        case .loading: return L10n.string("party_status_loading", fallback: "Choosing a source")
        case .buffering: return L10n.string("party_status_buffering", fallback: "Buffering")
        case .ready: return L10n.string("party_status_ready", fallback: "Ready to watch")
        case .behind: return L10n.string("party_status_behind", fallback: "Catching up")
        }
    }

    private func failureText(_ failure: WatchPartyFailure?) -> String {
        switch failure {
        case .invalidCode: return L10n.string("party_failure_invalid_code", fallback: "Enter a valid room code.")
        case .notFound: return L10n.string("party_failure_not_found", fallback: "Room not found. Check the invitation code.")
        case .full: return L10n.string("party_failure_full", fallback: "This room is full.")
        case .removed: return L10n.string("party_failure_removed", fallback: "You were removed from this room.")
        case .ended: return L10n.string("party_failure_ended", fallback: "This room has ended.")
        case .rateLimited: return L10n.string("party_failure_rate_limited", fallback: "Too many requests. Wait before trying again.")
        case .signInRequired: return L10n.string("party_failure_sign_in_required", fallback: "Sign in again to use Watch Party.")
        case .unavailable: return L10n.string("party_failure_unavailable", fallback: "Watch Party is unavailable on this server.")
        case .network, .none: return L10n.string("party_failure_network", fallback: "The room request failed. Check your connection and room status before trying again.")
        }
    }

    private func leaveRoom(endForEveryone: Bool = false) {
        guard !service.busy, operation == nil,
              let context = service.session?.playbackContext else { return }
        onCancelSelection()
        owner.finishPlayback()
        run {
            try await service.leave(endForEveryone: endForEveryone)
            guard !Task.isCancelled, service.isCurrent(context.request),
                  service.session?.party == nil else { return }
            onRoomExited(context)
        }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !service.busy, operation == nil else { return }
        owner.message = nil
        operation = Task { @MainActor in
            defer {
                operation = nil
                // The service can become idle before this local operation releases.
                if canUseAccount && focusedAction == nil {
                    focusedAction = preferredRoomFocus
                }
            }
            do { try await action() }
            catch {
                if !Task.isCancelled {
                    owner.message = L10n.string("party_error_room_request", fallback: "Could not complete the room request. Review the room status before trying again.")
                }
            }
        }
    }
}

@MainActor
private struct WatchPartyLobbyInvitation: View {
    let code: String
    @Environment(\.dismiss) private var dismiss
    @FocusState private var doneFocused: Bool

    // Android ActiveParty.inviteLink uses the same URL scheme and room code.
    private var inviteLink: String { "nuvio://party/\(code)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(L10n.string("party_invite_friend", fallback: "Invite a friend"))
                .font(.system(size: 38, weight: .bold, design: .rounded))
            HStack(alignment: .center, spacing: 32) {
                if let qr = QRCode.image(from: inviteLink, scale: 12) {
                    Image(uiImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 260, height: 260)
                        .padding(12)
                        .background(.white, in: RoundedRectangle(cornerRadius: 16))
                        .accessibilityLabel(L10n.format("party_invite_qr_accessibility", fallback: "QR invitation for Watch Party room %@", code))
                }
                VStack(alignment: .leading, spacing: 14) {
                    Text(L10n.string("party_invite_scan_hint", fallback: "Scan with a compatible Nuvio app"))
                        .font(.system(size: 22, weight: .semibold))
                    Text(WatchPartyCode.formatted(code))
                        .font(.system(size: 37, weight: .bold, design: .monospaced))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text(L10n.string("party_invite_code_hint", fallback: "Or enter this code in Watch Party. Each guest selects a source before playback."))
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack {
                Spacer()
                Button(L10n.string("tvos_common_done", fallback: "Done")) { dismiss() }
                    .focused($doneFocused)
            }
        }
        .padding(44)
        .frame(width: 760)
        .onAppear { doneFocused = true }
        .onExitCommand { dismiss() }
    }
}
