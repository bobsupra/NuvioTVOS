import SwiftUI
import UIKit

/// Watch Party controls embedded in the player's InSight panel.
@MainActor
struct PlayerWatchPartyPanel: View {
    @ObservedObject var viewModel: PlayerViewModel
    @ObservedObject var owner: WatchPartyAppOwner
    @ObservedObject var service: WatchPartyService
    @FocusState.Binding var focusedControlID: String?
    let focusContext: ScenePanelWatchPartyFocusContext
    let isCurrentPlayerSurface: @MainActor () -> Bool
    let onOpenLobby: () -> Void

    @State private var operation: Task<Void, Never>?
    @State private var message: String?
    @State private var endingRoom = false
    @State private var showingStreamWarning = false
    @State private var pendingStreamShare: WatchPartyStream?
    @State private var hasSharedStream = false
    @State private var showingMemberRemovalConfirmation = false
    @State private var memberToRemove: WatchPartyMember?
    @State private var roomCodeQR: UIImage?
    @State private var chatToastsEnabled = ProfileSettings.current.object(forKey: SettingsKey.partyChatToastsEnabled) as? Bool ?? true

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 20) {
                if let room = service.session, let party = room.party {
                    invitationCard(room: room, party: party)
                    membersCard(room: room, party: party)
                    controlsCard(room: room, party: party)
                } else {
                    lobbyCard
                }
            }
            .padding(.horizontal, 60)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .scrollClipDisabled()
        .focusSection()
        .onExitCommand(perform: focusContext.dismissPanel)
        .onDisappear {
            pendingStreamShare = nil
            showingStreamWarning = false
        }
        .sheet(isPresented: $showingStreamWarning, onDismiss: {
            pendingStreamShare = nil
        }) {
            WatchPartyStreamRiskSheet { skipFutureWarning in
                guard let pending = pendingStreamShare else { return }
                showingStreamWarning = false
                if skipFutureWarning {
                    ProfileSettings.current.set(true, forKey: "nuvio.tv.party.hideStreamSharingWarning")
                }
                sendApprovedStream(pending)
            }
        }
        .onAppear {
            if let room = service.session {
                if let code = room.party?.code {
                    roomCodeQR = QRCode.image(from: code)
                } else {
                    roomCodeQR = nil
                }
                hasSharedStream = room.isSharingStream
            }
            normalizeEntryFocusIfNeeded()
        }
        .onChange(of: service.session?.party?.id) { oldID, newID in
            pendingStreamShare = nil
            showingStreamWarning = false
            hasSharedStream = false
            if oldID == nil, newID != nil {
                focusContext.focusTab(.watchParty)
            } else if oldID != nil, newID == nil {
                focusedControlID = "party.create"
            }
        }
        .onChange(of: owner.presentation?.id) { _, presentationID in
            guard presentationID != nil,
                  service.session?.party != nil else { return }
            focusContext.focusTab(.watchParty)
        }
        .onChange(of: service.session?.party?.code) { _, code in
            roomCodeQR = code.flatMap { QRCode.image(from: $0) }
        }
        .onChange(of: service.session?.isSharingStream) { _, isSharing in
            hasSharedStream = isSharing ?? false
        }
        .onChange(of: focusedControlID) { _, controlID in
            focusContext.onFocusChanged(controlID)
            guard let controlID else { return }
            if !enabledFocusTargets.contains(controlID) || (focusContext.entryLocked && controlID != effectiveEntryFocusTarget) {
                guard !enabledFocusTargets.isEmpty else {
                    focusContext.onMoveUpFromContent()
                    return
                }
                focusedControlID = effectiveEntryFocusTarget
                focusContext.onFocusChanged(effectiveEntryFocusTarget)
            }
        }
        .onChange(of: focusContext.entryLocked) { _, locked in
            if !locked { normalizeEntryFocusIfNeeded() }
        }
        .onChange(of: enabledFocusTargets) { _, available in
            guard !focusContext.entryLocked else { return }
            if let current = focusedControlID, available.contains(current) { return }
            normalizeEntryFocusIfNeeded()
        }
        .confirmationDialog("End this room for everyone?", isPresented: $endingRoom) {
            Button("End room", role: .destructive) {
                run { try await owner.leaveRoomPreservingPlayback(endForEveryone: true) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var lobbyCard: some View {
        glassCard(title: "WATCH PARTY", width: 380) {
            VStack(alignment: .leading, spacing: 14) {
                Text(service.membershipOutcomeUncertain
                     ? "Check the room status before trying again."
                     : "Create a room for this title. To join a room, use Watch Party in the sidebar.")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
                createRoomButton
                inlineStatus
            }
        }
    }

    private var createRoomButton: some View {
        let isFocused = focusedControlID == "party.create"
        return Button {
            run {
                await owner.createRoomForCurrentPlayback(
                    using: viewModel,
                    isCurrentPlayerSurface: isCurrentPlayerSurface
                )
            }
        } label: {
            actionLabel(
                title: "Create room for this title",
                subtitle: "Share the current playback state",
                symbol: "person.3.sequence.fill",
                isFocused: isFocused
            )
        }
        .buttonStyle(PosterCardButtonStyle())
        .focusEffectDisabledIfAvailable()
        .focused($focusedControlID, equals: "party.create")
        .onMoveCommand(perform: handleFocusMove)
        .disabled(service.busy || operation != nil || service.membershipOutcomeUncertain
            || (focusContext.entryLocked && "party.create" != effectiveEntryFocusTarget))
    }

    @ViewBuilder
    private func openLobbyButton(isTopRow: Bool) -> some View {
        let isFocused = focusedControlID == "party.lobby"
        let button = Button(action: onOpenLobby) {
            actionLabel(
                title: "Open Watch Party lobby",
                subtitle: "Create or join a room",
                symbol: "person.3.sequence.fill",
                isFocused: isFocused
            )
        }
        .buttonStyle(PosterCardButtonStyle())
        .focusEffectDisabledIfAvailable()
        .focused($focusedControlID, equals: "party.lobby")
        .disabled(operation != nil || (focusContext.entryLocked && "party.lobby" != effectiveEntryFocusTarget))

        if isTopRow {
            button.onMoveCommand(perform: handleFocusMove)
        } else {
            button
        }
    }

    private func invitationCard(room: WatchPartySession, party: WatchPartyInfo) -> some View {
        return glassCard(title: "ROOM INVITATION", width: 390) {
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(party.code)
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .tracking(2.5)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text(connectionText(room.connection))
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                    if !party.media.title.isEmpty {
                        Text(party.media.title)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.88))
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                if let roomCodeQR {
                    Image(uiImage: roomCodeQR)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: 104, height: 104)
                        .padding(8)
                        .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .accessibilityLabel("QR code for room \(party.code)")
                }
            }
        }
    }

    private func membersCard(room: WatchPartySession, party: WatchPartyInfo) -> some View {
        let isHost = party.hostMemberID == room.memberID
        return glassCard(title: "MEMBERS", trailingHeader: "\(room.members.count) in this room", width: 540) {
            ScrollView(.horizontal, showsIndicators: room.members.count > 3) {
                HStack(alignment: .top, spacing: 18) {
                    ForEach(room.members, id: \.id) { member in
                        let isYou = member.id == room.memberID
                        let isRoomHost = member.id == party.hostMemberID
                        let canRemove = isHost && !isYou
                        let isFocused = focusedControlID == "party.member.\(member.id)"
                        Button {
                            guard canRemove else { return }
                            memberToRemove = member
                            showingMemberRemovalConfirmation = true
                        } label: {
                            VStack(spacing: 7) {
                                ZStack(alignment: .topTrailing) {
                                    memberAvatar(member)
                                    if canRemove {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 18, weight: .bold))
                                            .foregroundStyle(isFocused ? Color.red : Color.white.opacity(0.78))
                                            .offset(x: 4, y: -3)
                                    }
                                }
                                Text(member.displayName)
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(isFocused ? .black : .white)
                                    .lineLimit(1)
                                    .frame(maxWidth: 112)
                                Text(memberStatus(room.presence[member.id]?.status))
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(isFocused ? Color.black.opacity(0.65) : Color.white.opacity(0.65))
                                    .lineLimit(1)
                                if isYou || isRoomHost {
                                    Text(isYou && isRoomHost ? "You · Host" : (isYou ? "You" : "Host"))
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(isFocused ? Color.black.opacity(0.72) : Color.white.opacity(0.8))
                                        .lineLimit(1)
                                }
                            }
                            .frame(width: 112)
                            .padding(8)
                            .background(
                                isFocused ? Color.white.opacity(0.96) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 22, style: .continuous)
                            )
                        }
                        .buttonStyle(PosterCardButtonStyle())
                        .focusEffectDisabledIfAvailable()
                        .focused($focusedControlID, equals: "party.member.\(member.id)")
                        .onMoveCommand(perform: handleFocusMove)
                        .disabled(service.busy || operation != nil
                            || (focusContext.entryLocked && "party.member.\(member.id)" != effectiveEntryFocusTarget))
                        .accessibilityLabel(canRemove
                            ? "Remove \(member.displayName) from the room"
                            : "\(member.displayName), \(memberStatus(room.presence[member.id]?.status))")
                    }
                }
            }
            .frame(height: 154, alignment: .top)
            if room.members.count > 3 {
                Text("← / → to browse members")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .confirmationDialog(
            "Remove \(memberToRemove?.displayName ?? "member") from this room?",
            isPresented: $showingMemberRemovalConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove member", role: .destructive) {
                guard let memberToRemove else { return }
                let memberID = memberToRemove.id
                self.memberToRemove = nil
                run { try await service.removeMember(memberID: memberID) }
            }
            Button("Cancel", role: .cancel) { memberToRemove = nil }
        }
    }

    private func controlsCard(room: WatchPartySession, party: WatchPartyInfo) -> some View {
        let isHost = party.hostMemberID == room.memberID
        let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
        return glassCard(title: "PLAYBACK & CONTROLS", width: 650) {
            VStack(alignment: .leading, spacing: 5) {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 5) {
                if isHost {
                    let focused = focusedControlID == "party.hostOnly"
                    Button {
                        run { try await service.setHostOnly(enabled: !party.hostOnly) }
                    } label: {
                        actionLabel(
                            title: "Host-only playback",
                            subtitle: party.hostOnly ? "Only you control playback" : "Shared room control",
                            symbol: party.hostOnly ? "lock.fill" : "lock.open",
                            value: party.hostOnly ? "On" : "Off",
                            isFocused: focused
                        )
                    }
                    .buttonStyle(PosterCardButtonStyle())
                    .focusEffectDisabledIfAvailable()
                    .focused($focusedControlID, equals: "party.hostOnly")
                    .onMoveCommand(perform: handleFocusMove)
                    .disabled(service.busy || operation != nil || room.connection != .ready
                        || (focusContext.entryLocked && "party.hostOnly" != effectiveEntryFocusTarget))

                    let isSharing = room.isSharingStream || hasSharedStream
                    let shareFocused = focusedControlID == "party.shareStream"
                    Button {
                        if isSharing {
                            run {
                                try await room.stopSharingStream()
                                hasSharedStream = false
                            }
                        } else {
                            do {
                                let source = try viewModel.watchPartyShareableStream(for: party.media)
                                pendingStreamShare = source
                                if ProfileSettings.current.bool(forKey: "nuvio.tv.party.hideStreamSharingWarning") {
                                    sendApprovedStream(source)
                                    pendingStreamShare = nil
                                } else {
                                    showingStreamWarning = true
                                }
                            } catch {
                                message = "This source can't be shared. Use a compatible HTTP source or let guests choose their own."
                            }
                        }
                    } label: {
                        actionLabel(
                            title: "Share my stream · BETA",
                            subtitle: isSharing
                                ? "Sharing this playback link with guests"
                                : "Share this playback link with guests (may expose Debrid tokens)",
                            symbol: "antenna.radiowaves.left.and.right",
                            value: isSharing ? "Sharing" : "Off",
                            isFocused: shareFocused
                        )
                    }
                    .buttonStyle(PosterCardButtonStyle())
                    .focusEffectDisabledIfAvailable()
                    .focused($focusedControlID, equals: "party.shareStream")
                    .onMoveCommand(perform: handleFocusMove)
                    .disabled(service.busy || operation != nil || room.connection != .ready
                        || owner.presentation?.mount.isCurrent != true
                        || (focusContext.entryLocked && "party.shareStream" != effectiveEntryFocusTarget))
                } else {
                    if room.sharedStream != nil {
                        PlayerPanelRow(title: "Host stream available · BETA",
                                       subtitle: "Return to Watch Party to choose the shared source.")
                    }
                    Text(party.hostOnly ? "Playback control is limited to the host." : "Playback control is shared with the room.")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                }

                if owner.presentation?.mount.isCurrent == true {
                    catchUpButton(room: room, isTopRow: !isHost)
                } else {
                    PlayerPanelRow(title: "Choose a source in the Watch Party lobby to start playback.")
                    openLobbyButton(isTopRow: !isHost)
                }

                let chatToastsFocused = focusedControlID == "party.chatToasts"
                let chatToastsButton = Button {
                    chatToastsEnabled.toggle()
                    ProfileSettings.current.set(chatToastsEnabled, forKey: SettingsKey.partyChatToastsEnabled)
                } label: {
                    actionLabel(
                        title: "Chat message toasts",
                        subtitle: chatToastsEnabled ? "Message bubbles appear during playback" : "Muted during playback",
                        symbol: chatToastsEnabled ? "bubble.left.fill" : "bubble.left",
                        value: chatToastsEnabled ? "On" : "Off",
                        isFocused: chatToastsFocused
                    )
                }
                .buttonStyle(PosterCardButtonStyle())
                .focusEffectDisabledIfAvailable()
                .focused($focusedControlID, equals: "party.chatToasts")
                .disabled(service.busy || operation != nil
                    || (focusContext.entryLocked && "party.chatToasts" != effectiveEntryFocusTarget))

                if !isHost {
                    chatToastsButton.onMoveCommand(perform: handleFocusMove)
                } else {
                    chatToastsButton
                }

                let leaveFocused = focusedControlID == "party.leave"
                Button {
                    run { try await owner.leaveRoomPreservingPlayback() }
                } label: {
                    actionLabel(
                        title: "Leave room",
                        subtitle: "Leave this room",
                        symbol: "rectangle.portrait.and.arrow.right",
                        isFocused: leaveFocused
                    )
                }
                .buttonStyle(PosterCardButtonStyle())
                .focusEffectDisabledIfAvailable()
                .focused($focusedControlID, equals: "party.leave")
                .disabled(service.busy || operation != nil
                    || (focusContext.entryLocked && "party.leave" != effectiveEntryFocusTarget))

                if isHost {
                    let endFocused = focusedControlID == "party.endRoom"
                    Button(role: .destructive) { endingRoom = true } label: {
                        actionLabel(
                            title: "End room for everyone",
                            subtitle: "Remove all members",
                            symbol: "xmark.circle.fill",
                            isFocused: endFocused
                        )
                    }
                    .buttonStyle(PosterCardButtonStyle())
                    .focusEffectDisabledIfAvailable()
                    .focused($focusedControlID, equals: "party.endRoom")
                    .disabled(service.busy || operation != nil
                        || (focusContext.entryLocked && "party.endRoom" != effectiveEntryFocusTarget))
                }
            }
                inlineStatus
            }
        }
    }

    @ViewBuilder
    private func catchUpButton(room: WatchPartySession, isTopRow: Bool) -> some View {
        let button = Button { viewModel.catchUpWithWatchParty() } label: {
            actionLabel(
                title: "Catch up with room",
                subtitle: "Jump to room position",
                symbol: "backward.end.fill",
                isFocused: focusedControlID == "party.catchUp"
            )
        }
        .buttonStyle(PosterCardButtonStyle())
        .focusEffectDisabledIfAvailable()
        .focused($focusedControlID, equals: "party.catchUp")
        .disabled(service.busy || room.connection != .ready
            || (focusContext.entryLocked && "party.catchUp" != effectiveEntryFocusTarget))

        if isTopRow {
            button.onMoveCommand(perform: handleFocusMove)
        } else {
            button
        }
    }

    private func memberAvatar(_ member: WatchPartyMember, size: CGFloat = 72) -> some View {
        let initials = String(member.displayName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)).uppercased()
        let background = avatarColor(member.avatarColor)
        return ZStack {
            Circle().fill(background)
            if let url = safeAvatarURL(member.avatarURL) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Text(initials.isEmpty ? "?" : initials)
                            .font(.system(size: size * 0.4, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
            } else {
                Text(initials.isEmpty ? "?" : initials)
                    .font(.system(size: size * 0.4, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.white.opacity(0.3), lineWidth: 1))
    }

    private func safeAvatarURL(_ rawValue: String?) -> URL? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              rawValue.count <= 2048,
              let url = URL(string: rawValue),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host != nil else { return nil }
        return url
    }

    private func avatarColor(_ value: String?) -> Color {
        guard let value,
              value.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil,
              let hex = UInt64(String(value.dropFirst()), radix: 16) else {
            return Color(red: 0.18, green: 0.34, blue: 0.54)
        }
        return Color(
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255
        )
    }

    private func glassCard<Content: View>(
        title: String,
        trailingHeader: String? = nil,
        width: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(.white)
                    .tracking(1.2)
                Spacer(minLength: 8)
                if let trailingHeader {
                    Text(trailingHeader)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                }
            }
            Rectangle()
                .fill(Color.white.opacity(0.14))
                .frame(height: 1)
                .padding(.bottom, 2)
            content()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .frame(width: width, height: 256, alignment: .topLeading)
        .modifier(TvCardGlassBackground(isFocused: false, shape: RoundedRectangle(cornerRadius: 32, style: .continuous)))
    }

    private func actionLabel(
        title: String,
        subtitle: String,
        symbol: String,
        value: String? = nil,
        isFocused: Bool,
        isEnabled: Bool = true
    ) -> some View {
        HStack(spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 21, weight: .semibold))
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(subtitle)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            Spacer(minLength: 2)
            if let value {
                Text(value)
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(1)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(isFocused ? Color.black.opacity(0.08) : Color.white.opacity(0.12)))
            }
        }
        .foregroundStyle(isFocused ? Color.black : Color.white.opacity(isEnabled ? 1 : 0.58))
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .modifier(TvDetailsGlassBackground(filled: isFocused, shape: RoundedRectangle(cornerRadius: 20, style: .continuous)))
    }

    @ViewBuilder
    private var inlineStatus: some View {
        Group {
            if service.busy || operation != nil {
                HStack(spacing: 9) {
                    ProgressView()
                    Text("Contacting room…")
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.82))
            } else if let message {
                statusText(message)
            } else if let message = owner.message {
                statusText(message)
            } else if let failure = service.failure {
                statusText(failureText(failure))
            } else if service.session?.membershipExit != nil {
                statusText("Your previous room membership ended. Joining again needs a new request.")
            } else {
                Color.clear.accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 34, alignment: .topLeading)
    }

    private func statusText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white.opacity(0.8))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sendApprovedStream(_ candidate: WatchPartyStream) {
        guard let room = service.session, let party = room.party,
              party.hostMemberID == room.memberID,
              owner.presentation?.mount.isCurrent == true else { return }
        // A source switch between warning and confirmation must not share the old URL.
        do {
            guard try viewModel.watchPartyShareableStream(for: party.media) == candidate else {
                message = "The source changed. Review the new source before sharing."
                return
            }
            let consent = try room.approveStreamSharing(candidate, origin: .directHTTP)
            run {
                try await room.shareStream(candidate, consent: consent)
                hasSharedStream = true
            }
        } catch {
            message = "This playback source is no longer shareable. Choose a compatible source."
        }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !service.busy, operation == nil else { return }
        message = nil
        operation = Task { @MainActor in
            defer { operation = nil }
            do { try await action() }
            catch { if !Task.isCancelled { message = "Could not complete the room request. Check its status before trying again." } }
        }
    }

    private func handleFocusMove(_ direction: MoveCommandDirection) {
        guard direction == .up else { return }
        focusContext.onMoveUpFromContent()
    }

    private var enabledFocusTargets: [String] {
        guard let room = service.session, let party = room.party else {
            return service.busy || operation != nil || service.membershipOutcomeUncertain ? [] : ["party.create"]
        }
        let requestBusy = service.busy || operation != nil
        var ids = requestBusy ? [] : room.members.map { "party.member.\($0.id)" }
        let isHost = party.hostMemberID == room.memberID
        if isHost {
            if !requestBusy && room.connection == .ready {
                ids.append("party.hostOnly")
                if owner.presentation?.mount.isCurrent == true {
                    ids.append("party.shareStream")
                }
            }
        }
        if owner.presentation?.mount.isCurrent == true {
            if !service.busy && room.connection == .ready { ids.append("party.catchUp") }
        } else if operation == nil {
            ids.append("party.lobby")
        }
        if !requestBusy {
            ids.append("party.chatToasts")
            ids.append("party.leave")
            if isHost { ids.append("party.endRoom") }
        }
        return ids
    }

    private var effectiveEntryFocusTarget: String {
        if enabledFocusTargets.contains(focusContext.entryFocusTarget) { return focusContext.entryFocusTarget }
        if enabledFocusTargets.contains(focusContext.entryFallbackTarget) { return focusContext.entryFallbackTarget }
        return enabledFocusTargets.first ?? ""
    }

    private func normalizeEntryFocusIfNeeded() {
        guard !focusContext.entryLocked else { return }
        let current = focusedControlID
        if let current, enabledFocusTargets.contains(current) { return }
        guard !enabledFocusTargets.isEmpty else {
            focusContext.onMoveUpFromContent()
            return
        }
        let target = effectiveEntryFocusTarget
        focusedControlID = target
        focusContext.onFocusChanged(target)
    }

    private func connectionText(_ state: WatchPartyConnectionState) -> String {
        switch state {
        case .ready: return "Connected"
        case .connecting, .reconciling: return "Synchronizing room…"
        case .recovering: return service.busy || operation != nil ? "Updating room…" : "Reconnecting…"
        case .stopped: return "Room disconnected"
        }
    }

    private func memberStatus(_ status: WatchPartyMemberStatus?) -> String {
        guard let status else { return "Connecting" }
        switch status {
        case .browsing: return "Browsing"
        case .loading: return "Loading"
        case .buffering: return "Buffering"
        case .ready: return "Watching"
        case .behind: return "Behind"
        }
    }

    private func failureText(_ failure: WatchPartyFailure) -> String {
        switch failure {
        case .invalidCode: return "Enter a valid room code."
        case .notFound: return "Room not found. Check the invitation code."
        case .full: return "This room is full."
        case .removed: return "You were removed from this room."
        case .ended: return "This room has ended."
        case .rateLimited: return "Too many requests. Wait before trying again."
        case .signInRequired: return "Sign in again to use Watch Party."
        case .unavailable: return "Watch Party is unavailable on this server."
        case .network: return "The room request failed. Check your connection and room status."
        }
    }
}

@MainActor
private struct WatchPartyStreamRiskSheet: View {
    let onApprove: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedCancel: Bool
    @State private var hideWarningNextTime = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Label("Share your stream? · EXPERIMENTAL BETA", systemImage: "exclamationmark.shield.fill")
                .font(.system(size: 30, weight: .bold))
            Text("This shares your current playback URL and required HTTP headers with room members. The URL may contain Debrid tokens or other private access information. Guests may copy or reuse it. Stopping sharing cannot revoke a link already received, and your provider may restrict simultaneous use.")
                .font(.system(size: 21))
                .fixedSize(horizontal: false, vertical: true)
            Text("Only share with people you trust. The link is not end-to-end encrypted by this feature. Some sources may fail on another device.")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)
            Toggle("Don't show this warning again", isOn: $hideWarningNextTime)
            HStack(spacing: 20) {
                Button("Cancel") { dismiss() }
                    .focused($focusedCancel)
                Button("I understand, share this source") {
                    onApprove(hideWarningNextTime)
                    dismiss()
                }
            }
        }
        .padding(48)
        .frame(width: 850)
        .onAppear { focusedCancel = true }
        .onExitCommand { dismiss() }
    }
}
