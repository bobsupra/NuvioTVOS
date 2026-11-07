import SwiftUI

/// Live TV tab: Xtream login, channel groups and channel list.
struct LiveTVView: View {
    @StateObject private var store = LiveTVStore()
    @State private var isEditingAccount = false
    let onPlayChannel: (URL, NuvioMeta, [String: String]) -> Void

    var body: some View {
        Group {
            if !store.hasAccount || isEditingAccount {
                XtreamLoginForm(
                    store: store,
                    isEditing: store.hasAccount,
                    onDone: { isEditingAccount = false }
                )
            } else {
                channelBrowser
            }
        }
        .onAppear { store.reloadAccount() }
    }

    // MARK: Browser

    private var channelBrowser: some View {
        VStack(alignment: .leading, spacing: 24) {
            header
            HStack(alignment: .top, spacing: 40) {
                groupList
                    .frame(width: 460)
                channelList
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 60)
        .padding(.top, 30)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.string("livetv_title", fallback: "Live TV"))
                    .font(.system(size: 44, weight: .bold))
                accountSummary
                    .font(.system(size: 22))
                    .foregroundColor(.white.opacity(0.6))
            }
            Spacer()
            if store.state == .loading {
                ProgressView()
            }
            Button {
                store.refresh()
            } label: {
                Label(L10n.string("livetv_refresh", fallback: "Refresh"), systemImage: "arrow.clockwise")
            }
            .disabled(store.state == .loading)
            Button {
                isEditingAccount = true
            } label: {
                Label(L10n.string("livetv_account", fallback: "Account"), systemImage: "person.badge.key")
            }
        }
    }

    private var accountSummary: Text {
        var parts: [String] = []
        if let name = store.account?.name { parts.append(name) }
        if let info = store.userInfo {
            if let expires = info.expiresAt {
                parts.append(L10n.string("livetv_expires", fallback: "Expires") + " "
                    + expires.formatted(date: .abbreviated, time: .omitted))
            }
            if let max = info.maxConnections {
                parts.append(L10n.string("livetv_connections", fallback: "Connections")
                    + " \(info.activeConnections ?? 0)/\(max)")
            }
        }
        if case .failed(let message) = store.state {
            parts.append("⚠︎ " + message)
        }
        return Text(parts.joined(separator: "  ·  "))
    }

    private var groupList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(store.groups) { group in
                    Button {
                        store.selectedGroupID = group.id
                    } label: {
                        HStack {
                            Text(group.name)
                                .lineLimit(1)
                            Spacer()
                            Text("\(group.count)")
                                .foregroundColor(.secondary)
                        }
                        .font(.system(size: 24, weight: store.selectedGroupID == group.id ? .bold : .regular))
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(LiveTVRowButtonStyle(isSelected: store.selectedGroupID == group.id))
                }
            }
            .padding(.vertical, 20)
            .padding(.horizontal, 10)
        }
    }

    @ViewBuilder
    private var channelList: some View {
        let channels = store.visibleChannels
        if channels.isEmpty {
            VStack(spacing: 20) {
                if store.state == .loading {
                    ProgressView()
                    Text(L10n.string("livetv_loading", fallback: "Loading channels…"))
                } else {
                    Image(systemName: "tv.slash").font(.system(size: 60))
                    Text(L10n.string("livetv_no_channels", fallback: "No channels in this group."))
                }
            }
            .font(.system(size: 26))
            .foregroundColor(.white.opacity(0.7))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(channels) { channel in
                        Button {
                            play(channel)
                        } label: {
                            LiveTVChannelRow(channel: channel)
                        }
                        .buttonStyle(LiveTVRowButtonStyle(isSelected: false))
                    }
                }
                .padding(.vertical, 20)
                .padding(.horizontal, 10)
            }
            .id(store.selectedGroupID)
        }
    }

    private func play(_ channel: XtreamLiveChannel) {
        guard let item = store.playbackItem(for: channel) else { return }
        onPlayChannel(item.url, item.meta, item.headers)
    }
}

// MARK: - Rows

private struct LiveTVChannelRow: View {
    let channel: XtreamLiveChannel

    var body: some View {
        HStack(spacing: 24) {
            Text(channel.number.map(String.init) ?? "")
                .font(.system(size: 22, weight: .semibold).monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .trailing)
            LiveTVLogo(url: channel.logoURL.flatMap(URL.init(string:)))
                .frame(width: 120, height: 68)
            Text(channel.name)
                .font(.system(size: 26, weight: .medium))
                .lineLimit(1)
            Spacer()
            if channel.archiveDays > 0 {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 6)
    }
}

struct LiveTVLogo: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url) { phase in
            if case .success(let image) = phase {
                image.resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "tv")
                    .font(.system(size: 30))
                    .foregroundColor(.white.opacity(0.3))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct LiveTVRowButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        LiveTVRowBody(configuration: configuration, isSelected: isSelected)
    }

    private struct LiveTVRowBody: View {
        let configuration: ButtonStyle.Configuration
        let isSelected: Bool
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundColor(isFocused ? .black : .white)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(isFocused ? Color.white : (isSelected ? Color.white.opacity(0.14) : Color.clear))
                )
                .scaleEffect(isFocused ? 1.02 : 1)
                .animation(.easeOut(duration: 0.12), value: isFocused)
        }
    }
}

// MARK: - Login

private struct XtreamLoginForm: View {
    @ObservedObject var store: LiveTVStore
    let isEditing: Bool
    let onDone: () -> Void

    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var format: XtreamStreamFormat = .auto
    @State private var isSigningIn = false
    @State private var errorMessage: String?
    @State private var showSignOutConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text(L10n.string("livetv_xtream_title", fallback: "Xtream Codes login"))
                .font(.system(size: 44, weight: .bold))
            Text(L10n.string(
                "livetv_xtream_hint",
                fallback: "Enter the server address, username and password from your IPTV provider."
            ))
            .font(.system(size: 24))
            .foregroundColor(.white.opacity(0.6))

            VStack(alignment: .leading, spacing: 18) {
                TextField(L10n.string("livetv_server", fallback: "Server (e.g. http://example.com:8080)"), text: $server)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField(L10n.string("livetv_username", fallback: "Username"), text: $username)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                SecureField(L10n.string("livetv_password", fallback: "Password"), text: $password)
                    .textContentType(.password)
            }
            .frame(maxWidth: 1100)

            HStack(spacing: 16) {
                Text(L10n.string("livetv_stream_format", fallback: "Stream format"))
                    .font(.system(size: 24))
                ForEach(XtreamStreamFormat.allCases) { option in
                    Button {
                        format = option
                    } label: {
                        HStack(spacing: 8) {
                            if format == option { Image(systemName: "checkmark") }
                            Text(option.title)
                        }
                    }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 24))
                    .foregroundColor(.red)
            }

            HStack(spacing: 24) {
                Button {
                    signIn()
                } label: {
                    HStack(spacing: 12) {
                        if isSigningIn { ProgressView() }
                        Text(L10n.string("livetv_sign_in", fallback: "Sign in"))
                    }
                }
                .disabled(isSigningIn || server.isEmpty || username.isEmpty || password.isEmpty)

                if isEditing {
                    Button(L10n.string("livetv_cancel", fallback: "Cancel"), action: onDone)
                    Button(role: .destructive) {
                        showSignOutConfirm = true
                    } label: {
                        Text(L10n.string("livetv_remove_account", fallback: "Remove account"))
                    }
                }
            }
        }
        .padding(80)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear(perform: fillFromAccount)
        .confirmationDialog(
            L10n.string("livetv_remove_account_confirm", fallback: "Remove this Xtream account from this profile?"),
            isPresented: $showSignOutConfirm
        ) {
            Button(L10n.string("livetv_remove_account", fallback: "Remove account"), role: .destructive) {
                store.signOut()
                onDone()
            }
        }
    }

    private func fillFromAccount() {
        guard let account = store.account else { return }
        server = account.server
        username = account.username
        password = store.password()
        format = account.streamFormat
    }

    private func signIn() {
        errorMessage = nil
        isSigningIn = true
        Task {
            defer { isSigningIn = false }
            do {
                try await store.signIn(server: server, username: username, password: password, format: format)
                onDone()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
