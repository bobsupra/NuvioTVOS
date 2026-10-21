import SwiftUI
import UIKit

/// Read-only room status for InSight. Management belongs to the dedicated
/// player transport button, not to this fixed-height bottom panel.
@MainActor
struct PlayerWatchPartyPanel: View {
    @ObservedObject var owner: WatchPartyAppOwner
    @ObservedObject var service: WatchPartyService
    @State private var roomCodeQR: UIImage?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 20) {
                if let room = service.session, let party = room.party {
                    invitationCard(room: room, party: party)
                    membersCard(room: room, party: party)
                    statusCard(room: room, party: party)
                }
            }
            .padding(.horizontal, 60)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .scrollClipDisabled()
        .onAppear { updateQR() }
        .onChange(of: service.session?.party?.code) { _, _ in updateQR() }
        .onChange(of: owner.pendingHostOnlyRoomID) { _, _ in updateQR() }
    }

    private func updateQR() {
        guard let party = service.session?.party,
              owner.pendingHostOnlyRoomID != party.id else {
            roomCodeQR = nil
            return
        }
        roomCodeQR = QRCode.image(from: party.code)
    }

    private func invitationCard(room: WatchPartySession, party: WatchPartyInfo) -> some View {
        statusCardShell("ROOM INVITATION", width: 390) {
            if owner.pendingHostOnlyRoomID == party.id {
                Label("Confirming host permissions", systemImage: "lock.shield")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.orange)
                Text("Room code hidden until setup succeeds.")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.76))
            } else {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(party.code)
                            .font(.system(size: 31, weight: .bold, design: .rounded))
                            .tracking(2)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        Text(connectionText(room.connection))
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white.opacity(0.8))
                        Text(party.media.title)
                            .font(.system(size: 15))
                            .lineLimit(2)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    Spacer(minLength: 0)
                    if let roomCodeQR {
                        Image(uiImage: roomCodeQR)
                            .resizable()
                            .interpolation(.none)
                            .frame(width: 94, height: 94)
                            .padding(8)
                            .background(.white, in: RoundedRectangle(cornerRadius: 12))
                            .accessibilityLabel("Invitation QR code")
                    }
                }
            }
        }
    }

    private func membersCard(room: WatchPartySession, party: WatchPartyInfo) -> some View {
        statusCardShell("MEMBERS · \(room.members.count)", width: 520) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 20) {
                    ForEach(Array(room.members.prefix(3)), id: \.id) { member in
                        VStack(spacing: 6) {
                            Text(String(member.displayName.prefix(1)).uppercased())
                                .font(.system(size: 28, weight: .bold))
                                .frame(width: 70, height: 70)
                                .background(.white.opacity(0.13), in: Circle())
                            Text(member.displayName)
                                .font(.system(size: 16, weight: .semibold))
                                .lineLimit(1)
                            Text(member.id == party.hostMemberID ? "Host" : "Guest")
                                .font(.system(size: 13))
                                .foregroundStyle(.white.opacity(0.65))
                            if member.id == room.memberID {
                                Text("You")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.8))
                            }
                        }
                        .frame(width: 112)
                        .accessibilityElement(children: .combine)
                    }
                }
                if room.members.count > 3 {
                    Text("+\(room.members.count - 3) more in the room")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
            .frame(height: 151, alignment: .topLeading)
        }
    }

    private func statusCard(room: WatchPartySession, party: WatchPartyInfo) -> some View {
        statusCardShell("ROOM STATUS", width: 485) {
            VStack(alignment: .leading, spacing: 14) {
                statusLine("Connection", value: connectionText(room.connection))
                statusLine("Playback control", value: party.hostOnly ? "Host only" : "Shared")
                statusLine("Your role", value:
                    room.memberID != nil && room.memberID == party.hostMemberID ? "Host" : "Guest")
                statusLine("Host source", value: owner.locallySharedStreamRoomID == party.id
                    ? "Sent · BETA" : room.sharedStream == nil ? "Not available" : "Available · BETA")
            }
        }
    }

    private func statusLine(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .foregroundStyle(.white.opacity(0.67))
            Spacer(minLength: 8)
            Text(value)
                .fontWeight(.semibold)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .font(.system(size: 17))
    }

    private func statusCardShell<Content: View>(
        _ title: String, width: CGFloat, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 15, weight: .heavy))
                .tracking(1.2)
            Rectangle().fill(Color.white.opacity(0.15)).frame(height: 1)
            content()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .frame(width: width, height: 256, alignment: .topLeading)
        .modifier(TvCardGlassBackground(
            isFocused: false, shape: RoundedRectangle(cornerRadius: 32, style: .continuous)
        ))
    }

    private func connectionText(_ value: WatchPartyConnectionState) -> String {
        switch value {
        case .ready: return "Connected"
        case .connecting, .reconciling: return "Synchronizing"
        case .recovering: return "Reconnecting"
        case .stopped: return "Disconnected"
        }
    }
}

/// Watches the live service so the InSight tab appears and disappears with
/// actual room membership, including rooms entered from the sidebar.
@MainActor
struct PlayerWatchPartySceneBridge: View {
    @ObservedObject var sceneViewModel: SceneViewModel
    @ObservedObject var owner: WatchPartyAppOwner
    @ObservedObject var service: WatchPartyService
    let isAdvancing: Bool
    let onDismiss: () -> Void
    let onPlayNextEpisode: () -> Void

    private var hasAcceptedMembership: Bool {
        guard let room = service.session, let party = room.party,
              room.membershipExit == nil, let memberID = room.memberID else { return false }
        return !party.id.isEmpty && room.members.contains(where: { $0.id == memberID })
    }

    var body: some View {
        ScenePanelView(
            viewModel: sceneViewModel,
            isAdvancing: isAdvancing,
            onDismiss: onDismiss,
            onPlayNextEpisode: onPlayNextEpisode,
            watchPartyContent: hasAcceptedMembership
                ? { _, _ in
                    AnyView(PlayerWatchPartyPanel(owner: owner, service: service))
                } : nil
        )
    }
}

/// Full-screen menu mirrors the player's ellipsis Settings panel: same scrim,
/// native Siri Remote focus, safe-area padding and Menu-to-close behavior.
/// There is deliberately NO Join action; joining belongs to the sidebar.
@MainActor
struct PlayerWatchPartyMenu: View {
    @ObservedObject var viewModel: PlayerViewModel
    @ObservedObject var owner: WatchPartyAppOwner
    @ObservedObject var service: WatchPartyService
    let isCurrentPlayerSurface: @MainActor () -> Bool
    let onOpenLobby: () -> Void
    let onClose: () -> Void

    @State private var hostOnly = true
    @State private var shareLater = false
    @State private var operation: Task<Void, Never>?
    @State private var message: String?
    @State private var pendingStreamShare: WatchPartyStream?
    @State private var showingStreamWarning = false
    @State private var endingRoom = false
    @State private var memberToRemove: WatchPartyMember?
    @State private var memberRemovalRoomID: String?
    @State private var showingMemberRemovalConfirmation = false
    @FocusState private var focus: String?

    private var initialActionFocus: String {
        guard let room = service.session, let party = room.party else { return "create" }
        if room.memberID != party.hostMemberID,
           owner.presentation?.mount.isCurrent != true {
            return "leave"
        }
        return "firstRoomAction"
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: [.black.opacity(0.92), .black.opacity(0.55)],
                startPoint: .leading, endPoint: .trailing
            )
            .ignoresSafeArea()

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 32) {
                    Text("Watch Party")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 30)
                        .frame(height: 70)
                        .modifier(TvDetailsGlassBackground(filled: true, shape: Capsule()))

                    if let room = service.session, let party = room.party {
                        activeRoom(room: room, party: party)
                    } else {
                        newRoom
                    }
                    if operation != nil || service.busy {
                        HStack(spacing: 14) {
                            ProgressView()
                            Text("Updating Watch Party…")
                        }
                    }
                    if let message {
                        Text(message).foregroundStyle(.orange)
                    } else if let message = owner.message {
                        Text(message).foregroundStyle(.orange)
                    }
                }
                .padding(.horizontal, 90)
                .padding(.top, 64)
                .padding(.bottom, 55)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear {
            viewModel.setControlsAutoHideSuspended(true)
            focus = initialActionFocus
        }
        .onReceive(owner.$service) { currentService in
            if currentService !== service { onClose() }
        }
        .onDisappear {
            viewModel.setControlsAutoHideSuspended(false)
            pendingStreamShare = nil
        }
        .onChange(of: service.session?.party?.id) { _, _ in
            // A confirmation for one private room must not carry into another.
            pendingStreamShare = nil
            showingStreamWarning = false
            memberToRemove = nil
            memberRemovalRoomID = nil
            showingMemberRemovalConfirmation = false
            focus = initialActionFocus
        }
        .focusSection()
        .onExitCommand(perform: onClose)
        .sheet(isPresented: $showingStreamWarning, onDismiss: {
            pendingStreamShare = nil
        }) {
            WatchPartyStreamRiskSheet { skipFutureWarning in
                guard let pendingStreamShare else { return }
                showingStreamWarning = false
                if skipFutureWarning {
                    ProfileSettings.current.set(true, forKey: "nuvio.tv.party.hideStreamSharingWarning")
                }
                shareApprovedStream(pendingStreamShare)
            }
        }
        .confirmationDialog("End this room for everyone?", isPresented: $endingRoom) {
            Button("End room", role: .destructive) {
                run {
                    try await owner.leaveRoomPreservingPlayback(endForEveryone: true)
                    onClose()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Remove \(memberToRemove?.displayName ?? "member") from this room?",
            isPresented: $showingMemberRemovalConfirmation
        ) {
            Button("Remove member", role: .destructive) {
                guard let member = memberToRemove,
                      let expectedRoomID = memberRemovalRoomID else { return }
                memberToRemove = nil
                memberRemovalRoomID = nil
                run {
                    guard let currentRoom = service.session,
                          currentRoom.party?.id == expectedRoomID,
                          currentRoom.party?.hostMemberID == currentRoom.memberID,
                          currentRoom.memberID != member.id else {
                        throw WatchPartySessionError.notReady
                    }
                    try await service.removeMember(memberID: member.id)
                }
            }
            Button("Cancel", role: .cancel) {
                memberToRemove = nil
                memberRemovalRoomID = nil
            }
        }
    }

    private var newRoom: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("CREATE A ROOM FOR THIS TITLE")
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(.white.opacity(0.76))

            Toggle(isOn: $hostOnly) {
                Label("Host-only playback", systemImage: hostOnly ? "lock.fill" : "lock.open")
                    .font(.system(size: 23, weight: .semibold))
            }
            .frame(maxWidth: 780)
            .padding(18)
            .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 20))

            Toggle(isOn: $shareLater) {
                Label("Share my source later", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 23, weight: .semibold))
            }
            .frame(maxWidth: 780)
            .padding(18)
            .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 20))

            Text("The room is created without sharing your playback URL. If you choose to share, you'll approve the exact source separately. Links can expose provider credentials.")
                .font(.system(size: 18))
                .foregroundStyle(.white.opacity(0.76))
                .frame(maxWidth: 850, alignment: .leading)

            menuButton("Create room", icon: "plus.circle.fill", id: "create") {
                run {
                    await owner.createRoomForCurrentPlayback(
                        using: viewModel, isCurrentPlayerSurface: isCurrentPlayerSurface,
                        hostOnly: hostOnly
                    )
                    if let id = service.session?.party?.id,
                       owner.pendingHostOnlyRoomID != id, shareLater {
                        message = "Select Share my stream and approve the exact source when ready."
                    }
                }
            }
            .disabled(service.busy || operation != nil || service.membershipOutcomeUncertain)
        }
    }

    private func activeRoom(room: WatchPartySession, party: WatchPartyInfo) -> some View {
        let isHost = room.memberID != nil && party.hostMemberID != nil
            && room.memberID == party.hostMemberID
        return VStack(alignment: .leading, spacing: 22) {
            Text("\(isHost ? "HOST" : "GUEST") · \(party.media.title)")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white.opacity(0.86))
            Text(owner.pendingHostOnlyRoomID == party.id
                ? "Permission confirmation pending. Invitation remains hidden in InSight."
                : "Room connected: \(party.code)")
                .font(.system(size: 18))
                .foregroundStyle(.white.opacity(0.73))

            if isHost {
                if owner.pendingHostOnlyRoomID == party.id {
                    menuButton("Retry host permissions", icon: "arrow.clockwise", id: "firstRoomAction") {
                        run { try await owner.confirmPendingHostOnly() }
                    }
                } else {
                    menuButton(
                        party.hostOnly ? "Host-only playback · On" : "Host-only playback · Off",
                        icon: party.hostOnly ? "lock.fill" : "lock.open",
                        id: "firstRoomAction"
                    ) {
                        run { try await service.setHostOnly(enabled: !party.hostOnly) }
                    }
                }
                menuButton("Share my stream · BETA", icon: "antenna.radiowaves.left.and.right", id: "share") {
                    prepareShare(for: room, party: party)
                }
                .disabled(owner.pendingHostOnlyRoomID == party.id || service.busy || operation != nil
                    || room.connection != .ready || owner.presentation?.mount.isCurrent != true)
                if owner.locallySharedStreamRoomID == party.id {
                    menuButton("Stop sharing (does not revoke links)", icon: "xmark.shield", id: "stopShare") {
                        run {
                            try await room.stopSharingStream()
                            owner.clearLocalStreamShared(roomID: party.id)
                        }
                    }
                }
                if owner.presentation?.mount.isCurrent == true {
                    menuButton("Catch up with room", icon: "backward.end.fill", id: "catchUp") {
                        viewModel.catchUpWithWatchParty()
                    }
                } else {
                    menuButton("Choose source from Watch Party", icon: "play.rectangle", id: "lobby") {
                        onClose()
                        onOpenLobby()
                    }
                }
                if room.members.contains(where: { $0.id != room.memberID }) {
                    Text("MANAGE MEMBERS")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white.opacity(0.67))
                    ForEach(room.members.filter { $0.id != room.memberID }, id: \.id) { member in
                        menuButton("Remove \(member.displayName)", icon: "person.crop.circle.badge.xmark",
                                   id: "remove.\(member.id)") {
                            memberToRemove = member
                            memberRemovalRoomID = party.id
                            showingMemberRemovalConfirmation = true
                        }
                    }
                }
                menuButton("Leave room", icon: "rectangle.portrait.and.arrow.right", id: "leave") {
                    run {
                        try await owner.leaveRoomPreservingPlayback()
                        onClose()
                    }
                }
                menuButton("End room for everyone", icon: "xmark.circle.fill", id: "end") {
                    endingRoom = true
                }
            } else {
                if owner.presentation?.mount.isCurrent == true {
                    menuButton("Catch up with host", icon: "backward.end.fill", id: "firstRoomAction") {
                        viewModel.catchUpWithWatchParty()
                    }
                } else {
                    menuButton("Choose source from Watch Party", icon: "play.rectangle", id: "lobby") {
                        onClose()
                        onOpenLobby()
                    }
                }
                menuButton("Leave room", icon: "rectangle.portrait.and.arrow.right", id: "leave") {
                    run {
                        try await owner.leaveRoomPreservingPlayback()
                        onClose()
                    }
                }
                Text("To choose your own source or join a different room, use Watch Party in the sidebar.")
                    .font(.system(size: 17))
                    .foregroundStyle(.white.opacity(0.67))
            }
        }
    }

    private func menuButton(
        _ title: String, icon: String, id: String,
        action: @escaping () -> Void
    ) -> some View {
        let isFocused = focus == id
        return Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon).frame(width: 32)
                Text(title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .font(.system(size: 23, weight: .medium))
            .foregroundStyle(isFocused ? .black : .white)
            .padding(.horizontal, 24)
            .frame(height: 64)
            .modifier(TvDetailsGlassBackground(
                filled: isFocused, shape: RoundedRectangle(cornerRadius: 20)
            ))
        }
        .buttonStyle(PosterCardButtonStyle())
        .focusEffectDisabledIfAvailable()
        .focused($focus, equals: id)
        .frame(maxWidth: 860)
        .disabled(service.busy || operation != nil)
    }

    private func prepareShare(for room: WatchPartySession, party: WatchPartyInfo) {
        guard room.party?.id == party.id,
              owner.presentation?.mount.isCurrent == true else { return }
        do {
            let source = try viewModel.watchPartyShareableStream(for: party.media)
            pendingStreamShare = source
            if ProfileSettings.current.bool(forKey: "nuvio.tv.party.hideStreamSharingWarning") {
                shareApprovedStream(source)
                pendingStreamShare = nil
            } else {
                showingStreamWarning = true
            }
        } catch {
            message = "This source cannot be shared. Guests can select their own source."
        }
    }

    private func shareApprovedStream(_ source: WatchPartyStream) {
        guard let room = service.session, let party = room.party,
              room.memberID == party.hostMemberID,
              owner.presentation?.mount.isCurrent == true else { return }
        do {
            guard try viewModel.watchPartyShareableStream(for: party.media) == source else {
                message = "The source changed. Review the current one before sharing."
                return
            }
            let consent = try room.approveStreamSharing(source, origin: .directHTTP)
            run {
                try await room.shareStream(source, consent: consent)
                owner.markLocalStreamShared(roomID: party.id)
            }
        } catch {
            message = "The playback source is no longer shareable."
        }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard operation == nil, !service.busy else { return }
        message = nil
        operation = Task { @MainActor in
            defer { operation = nil }
            do { try await action() }
            catch {
                if !Task.isCancelled {
                    message = "Could not update Watch Party. Check the room status and retry."
                }
            }
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
