import SwiftUI

/// Private rooms; playback starts only after an explicit local source selection.
@MainActor
struct WatchPartyLobbyView: View {
    @ObservedObject var owner: WatchPartyAppOwner
    @ObservedObject var service: WatchPartyService
    var onChooseSharedSource: (WatchPartyStream) -> Void = { _ in }
    let canUseAccount: Bool
    let isChoosing: Bool
    let onCreate: () -> Void
    let onChooseSource: (WatchPartyMedia) -> Void
    let onCancelSelection: () -> Void
    let onOpenProfile: () -> Void
    // This local gate is necessary because host-only is configured after
    // watch_party_create. Atomic create+permissions still needs backend support.
    var invitationSetupBlocked = false
    var onRetryInviteSetup: () -> Void = {}
    var detailsMedia: WatchPartyMedia? = nil
    var onRoomExited: (WatchPartyPlaybackContext) -> Void = { _ in }

    @State private var code = ""
    @State private var roomCodeIsEditing = false
    @State private var roomPreview: WatchPartyPreview?
    @State private var previewCode: String?
    @State private var previewRequestID = UUID()
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
                if canUseAccount, let room = service.session, let party = room.party {
                    activeRoomHeader(room: room, party: party)
                } else {
                    header
                }

                if !canUseAccount {
                    accountGateCard
                } else if let room = service.session, let party = room.party {
                    roomContent(room, party: party)
                } else {
                    createAndJoinCards
                }

                statusBlocks
                footerNote
            }
            .padding(.horizontal, 64)
            .padding(.vertical, 48)
            .frame(maxWidth: 1500, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
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
        }
        .onChange(of: service.session?.party?.code) { oldCode, newCode in
            guard oldCode == nil, newCode != nil, canUseAccount else { return }
            focusedAction = preferredRoomFocus
        }
        .sheet(isPresented: $showingInvitation) {
            if !invitationSetupBlocked, let party = service.session?.party,
               WatchPartyCode.isValid(party.code) {
                WatchPartyLobbyInvitation(code: WatchPartyCode.normalize(party.code))
            }
        }
        .onChange(of: invitationSetupBlocked) { _, blocked in
            if blocked { showingInvitation = false }
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
        .confirmationDialog("End this room for everyone?", isPresented: $endingRoom) {
            Button("End room", role: .destructive) {
                leaveRoom(endForEveryone: true)
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func invalidateInvitationPreview() {
        previewRequestID = UUID()
        roomPreview = nil
        previewCode = nil
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
        HStack(spacing: 22) {
            Image(systemName: TVTab.party.symbol)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 82, height: 82)
                .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 24, style: .continuous))

            VStack(alignment: .leading, spacing: 8) {
                Text(TVTab.party.title)
                    .font(.system(size: 46, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text("Watch together in a private room. Choose your own source or a compatible link shared by the host.")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(.white.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 4)
    }

    private func activeRoomHeader(room: WatchPartySession, party: WatchPartyInfo) -> some View {
        let hostName = room.members.first(where: { $0.id == party.hostMemberID })?.displayName ?? "your friends"
        return VStack(alignment: .leading, spacing: 8) {
            Text("Watch party")
                .font(.system(size: 52, weight: .regular))
                .foregroundStyle(.white)
            Text("Hosted by \(hostName)")
                .font(.system(size: 31, weight: .regular))
                .foregroundStyle(.white.opacity(0.74))
        }
        .padding(.top, 8)
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
        HStack(alignment: .top, spacing: 24) {
            joinRoomCard
            createRoomCard
        }
    }

    private var createRoomCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardHeading(
                symbol: "plus.circle.fill",
                title: "Create a room",
                subtitle: "Choose a movie or episode, then invite everyone with your room code."
            )

            Spacer(minLength: 30)

            Text("Rooms start paused. Press Play when your source is ready.")
                .font(.system(size: 17))
                .foregroundStyle(.white.opacity(0.62))
                .padding(.bottom, 18)

            Button {
                owner.message = nil
                onCreate()
            } label: {
                primaryActionLabel(
                    symbol: "plus",
                    title: "Choose a title",
                    subtitle: "Start a new private room",
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
        .padding(32)
        .frame(maxWidth: .infinity, minHeight: 400, alignment: .topLeading)
        .modifier(LiquidGlassSurface(cornerRadius: 30, prominent: true))
    }

    private var joinRoomCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardHeading(
                symbol: "person.2.fill",
                title: "Join a room",
                subtitle: "Enter the six-character code shared by the room's host."
            )

            Spacer(minLength: 24)

            HStack {
                Text("ROOM CODE · 6 CHARACTERS")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.66))
                Spacer()
                Text("\(code.count)/\(WatchPartyCode.length)")
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.bottom, 10)

            Button {
                roomCodeIsEditing = true
            } label: {
                SettingsGlassTextField(
                    text: $code,
                    placeholder: "Room Code",
                    focused: focusedAction == "room-code",
                    isEditing: $roomCodeIsEditing,
                    fieldWidth: 580,
                    centerDisplayText: true,
                    keyboardType: .asciiCapable,
                    onCommit: { roomCodeIsEditing = false }
                )
            }
            .buttonStyle(PosterCardButtonStyle())
            .focusEffectDisabledIfAvailable()
            .accessibilityLabel("Six-character room code")
            .focused($focusedAction, equals: "room-code")
            .onMoveCommand { direction in
                if direction == .right { focusedAction = "create" }
            }

            Spacer(minLength: 20)

            if let preview = roomPreview, previewCode == WatchPartyCode.normalize(code),
               let media = preview.media {
                roomPreviewCard(preview, media: media)
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
                            owner.message = "Room preview unavailable. Check the invitation code."
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
                        title: "Preview room",
                        subtitle: "Check the host and exact movie or episode before joining",
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
        .padding(32)
        .frame(maxWidth: .infinity, minHeight: 400, alignment: .topLeading)
        .modifier(LiquidGlassSurface(cornerRadius: 30, prominent: true))
    }

    private func roomPreviewCard(_ preview: WatchPartyPreview, media: WatchPartyMedia) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("INVITATION PREVIEW")
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
                    Text(media.title.isEmpty ? "Untitled room" : media.title)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    if let episode = episodeDescription(media) {
                        Text(episode).font(.system(size: 17))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    Text("Hosted by \(preview.host.flatMap { $0.displayName.isEmpty ? nil : $0.displayName } ?? "Host")")
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
            Text("\(preview.members) of \(preview.maxMembers) participants")
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
                        owner.message = "Room content changed since preview. Confirm the current title before choosing a source."
                        focusedAction = "review-room"
                    }
                }
            } label: {
                primaryActionLabel(symbol: "checkmark.circle", title: "Join this room",
                                   subtitle: "Confirm this movie or episode",
                                   isFocused: focusedAction == "join")
            }
            .buttonStyle(PosterCardButtonStyle())
            .focusEffectDisabledIfAvailable()
            .focused($focusedAction, equals: "join")
            .disabled(service.busy || operation != nil || preview.isFull || service.membershipOutcomeUncertain)
            Button("Change room code") {
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
            HStack(alignment: .top, spacing: 20) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 64, height: 64)
                    .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 20, style: .continuous))

                VStack(alignment: .leading, spacing: 8) {
                    Text("Choose a profile to continue")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Sign in and choose a profile to create or join a Watch Party.")
                        .font(.system(size: 20))
                        .foregroundStyle(.white.opacity(0.7))
                }
                Spacer(minLength: 12)
                Image(systemName: "chevron.right")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white.opacity(0.72))
            }
            .padding(30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(LiquidGlassSurface(cornerRadius: 28, prominent: true))
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(accountGateFocused ? AppFocusOutline.color : Color.clear,
                                  lineWidth: accountGateFocused ? AppFocusOutline.width : 0)
            }
            .scaleEffect(accountGateFocused ? 1.025 : 1)
            .animation(.easeOut(duration: 0.14), value: accountGateFocused)
        }
        .buttonStyle(PosterCardButtonStyle())
        .focusEffectDisabledIfAvailable()
        .focused($accountGateFocused)
    }

    private func roomContent(_ room: WatchPartySession, party: WatchPartyInfo) -> some View {
        HStack(alignment: .center, spacing: 56) {
            roomSummaryCard(room, party: party)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 22) {
                membersCard(room, party: party)
                roomActions(room, party: party)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 14)
        .frame(minHeight: 600, alignment: .center)
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

            hostSeatSummary(room, party: party)
            if invitationSetupBlocked && party.hostMemberID == room.memberID {
                statusRow(
                    symbol: "lock.shield",
                    title: "Room code is hidden until playback permissions are confirmed.",
                    tint: .orange
                )
            } else {
                roomCodeDisplay(party.code)
            }
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
        Text(title.isEmpty ? "Watch Party" : title)
            .font(.system(size: 58, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .lineLimit(2)
            .minimumScaleFactor(0.72)
            .shadow(color: .black.opacity(0.55), radius: 12, y: 5)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func hostSeatSummary(_ room: WatchPartySession, party: WatchPartyInfo) -> some View {
        let host = room.members.first(where: { $0.id == party.hostMemberID })
            ?? room.members.first(where: { $0.id == room.memberID })
        let hostName: String
        if let displayName = host?.displayName.trimmingCharacters(in: .whitespacesAndNewlines), !displayName.isEmpty {
            hostName = displayName
        } else {
            hostName = "Host"
        }
        return HStack(spacing: 18) {
            if let host {
                memberAvatar(host, size: 62)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Hosted by \(hostName)")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.white.opacity(0.86))
                Text("\(room.members.count) of \(party.maxMembers) seats")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
            }
        }
    }

    private func roomCodeDisplay(_ code: String) -> some View {
        let characters = Array(WatchPartyCode.normalize(code))
        return VStack(alignment: .leading, spacing: 14) {
            Text("Party code")
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
        .accessibilityLabel("Party code \(WatchPartyCode.formatted(code))")
    }

    private func membersCard(_ room: WatchPartySession, party: WatchPartyInfo) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                Text("In this room")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
                connectionBadge(room.connection)
            }

            if room.members.isEmpty {
                Text("Waiting for viewers to join…")
                    .font(.system(size: 19))
                    .foregroundStyle(.white.opacity(0.65))
            } else {
                VStack(spacing: 14) {
                    ForEach(room.members, id: \.id) { member in
                        memberRow(member, room: room, party: party)
                    }
                }
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
        .background(.black.opacity(0.32), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
        }
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

    private func memberRow(_ member: WatchPartyMember, room: WatchPartySession, party: WatchPartyInfo) -> some View {
        HStack(spacing: 14) {
            memberAvatar(member, size: 56)

            VStack(alignment: .leading, spacing: 4) {
                Text(member.displayName.isEmpty ? "Viewer" : member.displayName)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(presenceLabel(room.presence[member.id]?.status))
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
            }

            Spacer(minLength: 8)

            if member.id == party.hostMemberID {
                roleBadge("HOST", isHost: true)
            }
            if member.id == room.memberID {
                roleBadge("YOU", isHost: false)
            }
        }
        .padding(.vertical, 2)
    }

    private func roomActions(_ room: WatchPartySession, party: WatchPartyInfo) -> some View {
        VStack(alignment: .leading, spacing: 16) {
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
            if isGuest, let stream = room.sharedStream, stream.mediaKey == party.media.key,
               !needsMediaReview, room.connection == .ready, room.membershipExit == nil {
                Button {
                    onChooseSharedSource(stream)
                } label: {
                    secondaryActionLabel(
                        symbol: "play.fill",
                        title: "Use host's source · BETA",
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
                            ? "Source refresh requested. If the host is online and sharing, the source should appear shortly."
                            : "Please wait a few seconds before requesting the source again."
                    }
                } label: {
                    secondaryActionLabel(
                        symbol: "arrow.clockwise",
                        title: "Refresh host's shared source · BETA",
                        isFocused: focusedAction == "refresh-host-source"
                    )
                }
                .buttonStyle(PosterCardButtonStyle())
                .focusEffectDisabledIfAvailable()
                .focused($focusedAction, equals: "refresh-host-source")
                .disabled(service.busy || operation != nil)
            }
            if invitationSetupBlocked, party.hostMemberID == room.memberID {
                statusRow(
                    symbol: "exclamationmark.shield.fill",
                    title: "Playback permissions were not confirmed by the server. Do not invite anyone yet.",
                    tint: .orange
                )
                Button(action: onRetryInviteSetup) {
                    secondaryActionLabel(
                        symbol: "arrow.clockwise",
                        title: "Retry playback permissions",
                        isFocused: focusedAction == "retry-invite-setup"
                    )
                }
                .buttonStyle(PosterCardButtonStyle())
                .focusEffectDisabledIfAvailable()
                .focused($focusedAction, equals: "retry-invite-setup")
                .disabled(service.busy || operation != nil || room.connection != .ready || room.membershipExit != nil)
            }
            if needsMediaReview {
                statusRow(symbol: "exclamationmark.triangle.fill",
                          title: "The room changed to \(party.media.title)\(episodeDescription(party.media).map { " · " + $0 } ?? ""). Confirm before choosing a source.",
                          tint: .orange)
                Button {
                    guard room.party?.id == reviewRoomID,
                          room.party?.media.key == reviewMediaKey,
                          room.connection == .ready, room.membershipExit == nil else { return }
                    reviewRoomID = nil
                    reviewMediaKey = nil
                    owner.message = nil
                    focusedAction = preferredRoomFocus
                } label: {
                    primaryActionLabel(symbol: "checkmark.shield",
                                       title: "Confirm current movie or episode",
                                       subtitle: "Verify this title before selecting a source",
                                       isFocused: focusedAction == "review-room")
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
                secondaryActionLabel(
                    symbol: "qrcode",
                    title: "Invite a friend",
                    isFocused: focusedAction == "invite"
                )
            }
            .buttonStyle(PosterCardButtonStyle())
            .focused($focusedAction, equals: "invite")
            .disabled(invitationSetupBlocked || service.busy || operation != nil || room.connection != .ready || room.membershipExit != nil || !WatchPartyCode.isValid(party.code))

            HStack(spacing: 14) {
                if room.connection != .ready, room.membershipExit == nil {
                    Button {
                        run { try await service.resume() }
                    } label: {
                        secondaryActionLabel(symbol: "arrow.clockwise", title: "Reconnect", isFocused: focusedAction == "reconnect")
                    }
                    .buttonStyle(PosterCardButtonStyle())
                    .focusEffectDisabledIfAvailable()
                    .focused($focusedAction, equals: "reconnect")
                    .disabled(service.busy || operation != nil)
                }

                Button {
                    leaveRoom()
                } label: {
                    secondaryActionLabel(
                        symbol: "rectangle.portrait.and.arrow.right",
                        title: "Leave room",
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
                        secondaryActionLabel(
                            symbol: "xmark.circle",
                            title: "End room for everyone",
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
        .padding(20)
        .background(.black.opacity(0.32), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func primaryRoomAction(_ room: WatchPartySession, party: WatchPartyInfo) -> some View {
        if owner.presentation?.mount.isCurrent == true {
            Button {
                guard let presentation = owner.presentation, presentation.mount.isCurrent else { return }
                presentation.mount.viewModel.catchUpWithWatchParty()
            } label: {
                primaryActionLabel(
                    symbol: "arrow.down.to.line",
                    title: "Catch up with room",
                    subtitle: "Return to the shared playback position",
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
                primaryActionLabel(
                    symbol: "play.fill",
                    title: "Choose my source",
                    subtitle: "Pick any source you have for this title or episode",
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
                        Text("Contacting room…")
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
                        title: "The server may have accepted the last request. Check the room with its host before trying again.",
                        tint: .yellow
                    )
                    Button {
                        service.acknowledgeUncertainMembershipOutcome()
                    } label: {
                        secondaryActionLabel(
                            symbol: "checkmark.circle",
                            title: "I checked — allow a new attempt",
                            isFocused: focusedAction == "allow-retry"
                        )
                    }
                    .buttonStyle(PosterCardButtonStyle())
                    .focusEffectDisabledIfAvailable()
                    .focused($focusedAction, equals: "allow-retry")
                }
                if isChoosing {
                    statusRow(
                        symbol: "sparkles",
                        title: "Choose the matching title and episode from your catalog. You can use any source available to you.",
                        tint: .white
                    )
                    Button(action: onCancelSelection) {
                        secondaryActionLabel(
                            symbol: "xmark",
                            title: "Cancel title/source selection",
                            isFocused: focusedAction == "cancel-selection"
                        )
                    }
                    .buttonStyle(PosterCardButtonStyle())
                    .focusEffectDisabledIfAvailable()
                    .focused($focusedAction, equals: "cancel-selection")
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
            || service.session?.membershipExit != nil || service.membershipOutcomeUncertain || isChoosing
    }

    private var footerNote: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle")
            Text("Episode changes and autoplay aren't included. Shared links depend on provider compatibility and aren't stored with the room.")
        }
        .font(.system(size: 16, weight: .medium))
        .foregroundStyle(.white.opacity(0.5))
    }

    private func cardHeading(symbol: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 18) {
            Image(systemName: symbol)
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 58, height: 58)
                .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 27, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 18))
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

    private func connectionBadge(_ state: WatchPartyConnectionState) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(connectionColor(state))
                .frame(width: 12, height: 12)
            Text(connectionText(state))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(.black.opacity(0.2), in: Capsule())
    }

    private func roleBadge(_ title: String, isHost: Bool) -> some View {
        let tint: Color = isHost ? .yellow : .white
        return Text(title)
            .font(.system(size: 14, weight: .heavy, design: .rounded))
            .tracking(0.6)
            .foregroundStyle(isHost ? Color.black.opacity(0.9) : Color.white.opacity(0.9))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(tint.opacity(isHost ? 0.92 : 0.15), in: Capsule())
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
        let number = "Season \(season) · Episode \(episode)"
        guard let title = media.episodeTitle, !title.isEmpty else { return number }
        return "\(number) · \(title)"
    }

    private var membershipExitMessage: String {
        if service.session?.party != nil {
            return "This membership ended. Leave this room before joining again."
        }
        return "Your previous room membership ended. Joining again requires a new request."
    }

    private func presenceLabel(_ status: WatchPartyMemberStatus?) -> String {
        switch status ?? .browsing {
        case .browsing: return "Browsing"
        case .loading: return "Choosing a source"
        case .buffering: return "Buffering"
        case .ready: return "Ready to watch"
        case .behind: return "Catching up"
        }
    }

    private func connectionColor(_ state: WatchPartyConnectionState) -> Color {
        switch state {
        case .ready: return .green
        case .connecting, .reconciling: return .yellow
        case .recovering, .stopped: return .orange
        }
    }

    private func connectionText(_ state: WatchPartyConnectionState) -> String {
        switch state {
        case .ready: return "Connected"
        case .connecting, .reconciling: return "Synchronizing room…"
        case .recovering: return "Connection lost — recovering this membership…"
        case .stopped: return "Room disconnected"
        }
    }

    private func failureText(_ failure: WatchPartyFailure?) -> String {
        switch failure {
        case .invalidCode: return "Enter a valid room code."
        case .notFound: return "Room not found. Check the invitation code."
        case .full: return "This room is full."
        case .removed: return "You were removed from this room."
        case .ended: return "This room has ended."
        case .rateLimited: return "Too many requests. Wait before trying again."
        case .signInRequired: return "Sign in again to use Watch Party."
        case .unavailable: return "Watch Party is unavailable on this server."
        case .network, .none: return "The room request failed. Check your connection and room status before trying again."
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
                    owner.message = "Could not complete the room request. Review the room status before trying again."
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
            Text("Invite a friend")
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
                        .accessibilityLabel("QR invitation for Watch Party room \(code)")
                }
                VStack(alignment: .leading, spacing: 14) {
                    Text("Scan with a compatible Nuvio app")
                        .font(.system(size: 22, weight: .semibold))
                    Text(WatchPartyCode.formatted(code))
                        .font(.system(size: 37, weight: .bold, design: .monospaced))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text("Or enter this code in Watch Party. Each guest selects a source before playback.")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .focused($doneFocused)
            }
        }
        .padding(44)
        .frame(width: 760)
        .background(Color.black.ignoresSafeArea())
        .onAppear { doneFocused = true }
        .onExitCommand { dismiss() }
    }
}
