import SwiftUI
import Combine

/// Source management and live channel browsing for the active profile.
struct IPTVLiveView: View {
    let profileID: String
    let onPlay: (URL, NuvioMeta, [String: String]) -> Void

    @State private var sources: [IPTVSource] = []
    @State private var sourcesLoaded = false
    @State private var channels: [IPTVChannel] = []
    @State private var stalkerChannels: [IPTVStalkerChannel] = []
    @State private var stalkerClient: IPTVStalkerClient?
    @State private var selectedID: UUID?
    @State private var sourceName = ""
    @State private var editingID: UUID?
    @State private var sourceURL = ""
    @State private var sourceKind: IPTVSource.Kind = .m3u
    @State private var username = ""
    @State private var password = ""
    @State private var mac = ""
    @State private var xtreamOutput: IPTVXtreamOutput = .mpegTS
    @State private var errorMessage: String?
    @State private var loading = false
    @State private var loadTask: Task<Void, Never>?
    @State private var requestID = UUID()
    @State private var guideTask: Task<Void, Never>?
    @State private var guideByChannel: [String: [IPTVProgramme]] = [:]
    @State private var guideUnavailable = false
    @State private var guideNow = Date()
    @State private var selectedGuideURL: URL?
    @State private var selectedGuideNeedsSameOrigin = false
    @State private var searchText = ""
    @State private var selectedGroup: String?
    @State private var favorites: Set<String> = []
    @State private var favoritesOnly = false
    @State private var favoriteKeys: [String: String] = [:]
    @State private var recentChannelKey: String?

    private let store = IPTVSourceStore()
    private let loader = IPTVPlaylistLoader()
    private let xtream = IPTVXtreamClient()
    private let guideLoader = IPTVGuideLoader()
    private let guideClock = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text(L10n.string("nav_live_tv", fallback: "Live TV"))
                    .font(.largeTitle.bold())
                Text(editingID == nil ? L10n.string("iptv_add_source", fallback: "Add a source") : L10n.string("iptv_edit_source", fallback: "Edit source"))
                    .font(.title2)
                Picker(L10n.string("iptv_source_type", fallback: "Source type"), selection: $sourceKind) {
                    Text("M3U").tag(IPTVSource.Kind.m3u)
                    Text("Xtream Codes").tag(IPTVSource.Kind.xtream)
                    Text("Stalker").tag(IPTVSource.Kind.stalker)
                }
                TextField(L10n.string("iptv_source_name", fallback: "Source name"), text: $sourceName)
                SecureField(sourceKind == .m3u ? L10n.string("iptv_source_url", fallback: "Playlist URL") : (sourceKind == .stalker ? L10n.string("iptv_portal_endpoint", fallback: "Portal endpoint URL") : L10n.string("iptv_server_url", fallback: "Server URL")), text: $sourceURL)
                if sourceKind == .xtream {
                    TextField(L10n.string("iptv_username", fallback: "Username"), text: $username)
                    SecureField(L10n.string("iptv_password", fallback: "Password"), text: $password)
                    Picker(L10n.string("iptv_xtream_format", fallback: "Stream format"), selection: $xtreamOutput) {
                        Text("MPEG-TS").tag(IPTVXtreamOutput.mpegTS)
                        Text("HLS").tag(IPTVXtreamOutput.hls)
                    }
                }
                if sourceKind == .stalker {
                    TextField(L10n.string("iptv_stalker_mac", fallback: "MAC address"), text: $mac)
                }
                Button(editingID == nil ? L10n.string("iptv_add", fallback: "Add source") : L10n.string("iptv_save_source", fallback: "Save source")) { addSource() }
                    .disabled(!sourcesLoaded || loading || sourceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sourceURL.isEmpty || (sourceKind == .xtream && (username.isEmpty || password.isEmpty)) || (sourceKind == .stalker && mac.isEmpty))
                if editingID != nil {
                    Button(L10n.string("iptv_cancel_edit", fallback: "Cancel editing")) { clearEditor() }
                        .disabled(loading)
                }

                if loading { ProgressView() }
                if let errorMessage { Text(errorMessage).foregroundColor(.red) }
                if guideUnavailable { Text(L10n.string("iptv_guide_unavailable", fallback: "Program guide unavailable.")) }
                ForEach(sources) { source in
                    HStack {
                        Button(source.name) { load(source) }
                            .disabled(loading)
                        Button(L10n.string("iptv_edit", fallback: "Edit")) { edit(source) }
                            .disabled(loading)
                        Button(L10n.string("iptv_remove", fallback: "Remove"), role: .destructive) { remove(source) }
                            .disabled(loading)
                    }
                }
                if selectedID != nil && channels.isEmpty && stalkerChannels.isEmpty && !loading && errorMessage == nil {
                    Text(L10n.string("iptv_empty", fallback: "No playable channels found."))
                }
                if selectedID != nil && (!channels.isEmpty || !stalkerChannels.isEmpty) {
                    if let channel = recentChannel {
                        Button(L10n.format("iptv_last_channel", fallback: "Last channel: %@", channel.name)) {
                            recordRecent(channelID: channel.id)
                            play(url: channel.streamURL, id: channel.id, name: channel.name, logo: channel.logoURL?.absoluteString)
                        }
                        .disabled(loading)
                    } else if let channel = recentStalkerChannel {
                        Button(L10n.format("iptv_last_channel", fallback: "Last channel: %@", channel.name)) {
                            resolveStalker(channel)
                        }
                        .disabled(loading)
                    }
                    TextField(L10n.string("iptv_search", fallback: "Search channels"), text: $searchText)
                    Button(favoritesOnly ? L10n.string("iptv_show_all", fallback: "Show all channels") : L10n.string("iptv_show_favorites", fallback: "Show favorites")) {
                        favoritesOnly.toggle()
                    }
                    if !availableGroups.isEmpty {
                        Picker(L10n.string("iptv_group", fallback: "Group"), selection: $selectedGroup) {
                            Text(L10n.string("iptv_all_groups", fallback: "All groups")).tag(String?.none)
                            ForEach(availableGroups, id: \.self) { group in
                                Text(group).tag(Optional(group))
                            }
                        }
                    }
                    if filteredChannels.isEmpty && filteredStalkerChannels.isEmpty {
                        Text(L10n.string("iptv_no_matches", fallback: "No matching channels."))
                    }
                }
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(filteredChannels) { channel in
                        HStack {
                            Button {
                                recordRecent(channelID: channel.id)
                                play(url: channel.streamURL, id: channel.id, name: channel.name, logo: channel.logoURL?.absoluteString)
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(channel.name)
                                    if let group = channel.group { Text(group).font(.caption).foregroundColor(.secondary) }
                                    if let programme = currentProgramme(for: channel) {
                                        Text(programme.title).font(.caption).foregroundColor(.secondary)
                                    }
                                }
                            }
                            favoriteButton(channelID: channel.id)
                        }
                    }
                    ForEach(filteredStalkerChannels) { channel in
                        HStack {
                            Button {
                                resolveStalker(channel)
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(channel.name)
                                    if let group = channel.categoryName { Text(group).font(.caption).foregroundColor(.secondary) }
                                }
                            }
                            .disabled(loading)
                            favoriteButton(channelID: channel.id)
                        }
                    }
                }
            }
            .padding(70)
        }
        .onAppear(perform: restoreSources)
        .onReceive(guideClock) { guideNow = $0 }
        .onDisappear { requestID = UUID(); loadTask?.cancel(); loadTask = nil; guideTask?.cancel(); guideTask = nil; loading = false }
    }

    private var filteredChannels: [IPTVChannel] {
        channels.filter { IPTVChannelFilter.matches(name: $0.name, group: $0.group, query: searchText, selectedGroup: selectedGroup) && (!favoritesOnly || isFavorite(channelID: $0.id)) }
    }

    private var filteredStalkerChannels: [IPTVStalkerChannel] {
        stalkerChannels.filter { IPTVChannelFilter.matches(name: $0.name, group: $0.categoryName, query: searchText, selectedGroup: selectedGroup) && (!favoritesOnly || isFavorite(channelID: $0.id)) }
    }

    private var availableGroups: [String] {
        let groups = IPTVChannelFilter.groups(in: channels) + stalkerChannels.compactMap(\.categoryName)
        return Array(Set(groups)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var recentChannel: IPTVChannel? {
        guard let key = recentChannelKey else { return nil }
        return channels.first { favoriteKeys[$0.id] == key }
    }

    private var recentStalkerChannel: IPTVStalkerChannel? {
        guard let key = recentChannelKey else { return nil }
        return stalkerChannels.first { favoriteKeys[$0.id] == key }
    }

    private func restoreSources() {
        do {
            sources = try store.load(profileID: profileID)
            sourcesLoaded = true
            favorites = IPTVFavoritesStore(defaults: ProfileSettings.store(for: profileID)).load()
            let recent = IPTVRecentChannelStore(defaults: ProfileSettings.store(for: profileID))
            recentChannelKey = recent.load()
            // Restore the list only, never start playback automatically.
            if selectedID == nil, !loading, ProfileSettings.activeProfileID == profileID,
               let sourceID = recent.sourceID(), let source = sources.first(where: { $0.id == sourceID }) {
                load(source)
            }
            if let id = selectedID, let url = selectedGuideURL, guideByChannel.isEmpty {
                loadGuide(url: url, for: id, channels: channels, sameOrigin: selectedGuideNeedsSameOrigin)
            }
        }
        catch { sourcesLoaded = false; errorMessage = L10n.string("iptv_storage_read_error", fallback: "Could not read IPTV sources.") }
    }

    private func addSource() {
        let name = sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawURL = sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: rawURL) else {
            errorMessage = L10n.string("iptv_invalid_url", fallback: "Enter a valid playlist URL.")
            return
        }
        let source = IPTVSource(id: editingID ?? UUID(), name: name, playlistURL: rawURL, kind: sourceKind,
                                username: sourceKind == .xtream ? username : nil,
                                password: sourceKind == .xtream ? password : nil,
                                mac: sourceKind == .stalker ? mac : nil,
                                xtreamOutput: sourceKind == .xtream ? xtreamOutput : .mpegTS)
        beginLoad(source: source, url: url, saveAfterLoading: true)
    }

    private func load(_ source: IPTVSource) {
        guard let url = URL(string: source.playlistURL) else { return }
        beginLoad(source: source, url: url, saveAfterLoading: false)
    }

    private func beginLoad(source: IPTVSource, url: URL, saveAfterLoading: Bool) {
        loadTask?.cancel()
        let token = UUID()
        requestID = token
        loading = true
        errorMessage = nil
        loadTask = Task { @MainActor in
            do {
                var loaded: [IPTVChannel] = []
                var portalChannels: [IPTVStalkerChannel] = []
                var portalClient: IPTVStalkerClient?
                var guideURL: URL?
                var guideNeedsSameOrigin = false
                switch source.kind {
                case .m3u:
                    let playlist = try await loader.loadPlaylist(url: url, sourceID: source.id.uuidString)
                    loaded = playlist.channels
                    guideURL = playlist.guideURL
                case .xtream:
                    guard let username = source.username, let password = source.password else { throw IPTVSourceStoreError.invalidSource }
                    let credentials = IPTVXtreamCredentials(server: url, username: username, password: password, output: source.xtreamOutput)
                    loaded = try await xtream.loadChannels(credentials: credentials, sourceID: source.id.uuidString)
                    guideURL = IPTVXtreamClient.guideURL(credentials: credentials)
                    guideNeedsSameOrigin = true
                case .stalker:
                    guard let mac = source.mac else { throw IPTVSourceStoreError.invalidSource }
                    let client = try IPTVStalkerClient(portal: url, mac: mac)
                    portalChannels = try await client.loadChannels()
                    portalClient = client
                }
                guard !Task.isCancelled, requestID == token, ProfileSettings.activeProfileID == profileID else { return }
                if saveAfterLoading {
                    var updated = sources
                    if let index = updated.firstIndex(where: { $0.id == source.id }) {
                        updated[index] = source
                    } else {
                        updated.append(source)
                    }
                    try store.save(updated, profileID: profileID)
                    sources = updated
                    clearEditor()
                }
                channels = loaded
                guideTask?.cancel()
                guideByChannel = [:]
                guideUnavailable = false
                selectedGuideURL = guideURL
                selectedGuideNeedsSameOrigin = guideNeedsSameOrigin
                stalkerChannels = portalChannels
                stalkerClient = portalClient
                selectedID = source.id
                var keys: [String: String] = [:]
                for channel in loaded { keys[channel.id] = IPTVFavoritesStore.key(sourceID: source.id, channelID: channel.id) }
                for channel in portalChannels { keys[channel.id] = IPTVFavoritesStore.key(sourceID: source.id, channelID: channel.id) }
                favoriteKeys = keys
                searchText = ""
                selectedGroup = nil
                if let guideURL { loadGuide(url: guideURL, for: source.id, channels: loaded, sameOrigin: guideNeedsSameOrigin) }
            } catch {
                guard !Task.isCancelled, requestID == token, ProfileSettings.activeProfileID == profileID else { return }
                errorMessage = sourceErrorMessage(error)
            }
            if requestID == token { loading = false; loadTask = nil }
        }
    }

    private func remove(_ source: IPTVSource) {
        let updated = sources.filter { $0.id != source.id }
        do {
            try store.save(updated, profileID: profileID)
            sources = updated
            favorites = IPTVFavoritesStore.removingSource(source.id, from: favorites)
            IPTVFavoritesStore(defaults: ProfileSettings.store(for: profileID)).save(favorites)
            let recentStore = IPTVRecentChannelStore(defaults: ProfileSettings.store(for: profileID))
            recentStore.removeIfOwned(by: source.id)
            recentChannelKey = recentStore.load()
            if selectedID == source.id {
                selectedID = nil; channels = []; stalkerChannels = []; stalkerClient = nil
                favoriteKeys = [:]
                guideTask?.cancel(); guideTask = nil; guideByChannel = [:]; guideUnavailable = false; selectedGuideURL = nil; selectedGuideNeedsSameOrigin = false
                searchText = ""; selectedGroup = nil
            }
            if editingID == source.id { clearEditor() }
            errorMessage = nil
        } catch {
            errorMessage = L10n.string("iptv_storage_save_error", fallback: "Could not save IPTV sources.")
        }
    }

    private func edit(_ source: IPTVSource) {
        editingID = source.id
        sourceName = source.name
        sourceURL = source.playlistURL
        sourceKind = source.kind
        username = source.username ?? ""
        password = source.password ?? ""
        mac = source.mac ?? ""
        xtreamOutput = source.xtreamOutput
        errorMessage = nil
    }

    private func clearEditor() {
        editingID = nil
        sourceName = ""
        sourceURL = ""
        sourceKind = .m3u
        username = ""
        password = ""
        mac = ""
        xtreamOutput = .mpegTS
    }

    private func isFavorite(channelID: String) -> Bool {
        guard let key = favoriteKeys[channelID] else { return false }
        return favorites.contains(key)
    }

    private func recordRecent(channelID: String) {
        guard let key = favoriteKeys[channelID], ProfileSettings.activeProfileID == profileID else { return }
        recentChannelKey = key
        IPTVRecentChannelStore(defaults: ProfileSettings.store(for: profileID)).save(key)
    }

    private func sourceErrorMessage(_ error: Error) -> String {
        switch IPTVFailureKind.classify(error) {
        case .invalidAddress:
            return L10n.string("iptv_error_address", fallback: "Check the source address and account details.")
        case .authentication:
            return L10n.string("iptv_error_auth", fallback: "The provider rejected access. Check your account details.")
        case .invalidContent:
            return L10n.string("iptv_error_content", fallback: "The provider returned data that Live TV could not read.")
        case .tooLarge:
            return L10n.string("iptv_error_size", fallback: "This source is too large to load.")
        case .storage:
            return L10n.string("iptv_error_storage", fallback: "Could not save this source securely on this device.")
        case .network:
            return L10n.string("iptv_error_network", fallback: "Could not reach the provider. Check your connection and try again.")
        case .other:
            return L10n.string("iptv_load_error", fallback: "Could not load this source. Please try again.")
        }
    }

    private func favoriteButton(channelID: String) -> some View {
        let selected = isFavorite(channelID: channelID)
        return Button {
            guard selectedID != nil, let key = favoriteKeys[channelID], ProfileSettings.activeProfileID == profileID else { return }
            if favorites.contains(key) { favorites.remove(key) } else { favorites.insert(key) }
            IPTVFavoritesStore(defaults: ProfileSettings.store(for: profileID)).save(favorites)
        } label: {
            Image(systemName: selected ? "star.fill" : "star")
        }
        .accessibilityLabel(selected ? L10n.string("iptv_remove_favorite", fallback: "Remove favorite") : L10n.string("iptv_add_favorite", fallback: "Add favorite"))
        .disabled(loading)
    }

    private func currentProgramme(for channel: IPTVChannel) -> IPTVProgramme? {
        guard let id = channel.guideID else { return nil }
        return guideByChannel[id]?.first { $0.start <= guideNow && guideNow < $0.end }
    }

    private func loadGuide(url: URL, for sourceID: UUID, channels: [IPTVChannel], sameOrigin: Bool) {
        let ids = Set(channels.compactMap(\.guideID))
        guard !ids.isEmpty else { return }
        let now = Date()
        let window = now.addingTimeInterval(-6 * 3600)..<now.addingTimeInterval(48 * 3600)
        guideTask = Task { @MainActor in
            do {
                let reader = sameOrigin ? IPTVGuideLoader(session: IPTVAuthenticatedSession.shared) : guideLoader
                let programmes = try await reader.load(url: url, channelIDs: ids, window: window)
                guard !Task.isCancelled, selectedID == sourceID, ProfileSettings.activeProfileID == profileID else { return }
                guideByChannel = Dictionary(grouping: programmes, by: \.channelID)
                guideNow = Date()
                guideUnavailable = false
            } catch {
                guard !Task.isCancelled, selectedID == sourceID, ProfileSettings.activeProfileID == profileID else { return }
                guideUnavailable = true
            }
        }
    }

    private func resolveStalker(_ channel: IPTVStalkerChannel) {
        guard let client = stalkerClient, let sourceID = selectedID else { return }
        let token = UUID()
        requestID = token
        loading = true
        errorMessage = nil
        loadTask = Task { @MainActor in
            do {
                let playback = try await client.resolve(channel)
                guard !Task.isCancelled, requestID == token, selectedID == sourceID,
                      ProfileSettings.activeProfileID == profileID else { return }
                loading = false
                loadTask = nil
                recordRecent(channelID: channel.id)
                play(url: playback.url, id: "\(sourceID.uuidString):\(channel.id)", name: channel.name, logo: nil, headers: playback.headers)
            } catch {
                guard !Task.isCancelled, requestID == token, ProfileSettings.activeProfileID == profileID else { return }
                errorMessage = L10n.string("iptv_play_error", fallback: "Could not open this channel. Try loading the source again.")
                loading = false
                loadTask = nil
            }
        }
    }

    private func play(url: URL, id: String, name: String, logo: String?, headers: [String: String] = [:]) {
        onPlay(url, NuvioMeta(
            id: "iptv:\(id)", name: name, description: nil, posterUrl: logo, backgroundUrl: nil, logoUrl: nil,
            imdbId: nil, tmdbId: nil, type: "channel", year: nil, genres: nil,
            rating: nil, releaseInfo: nil, runtime: nil, cast: nil, director: nil,
            writer: nil, certification: nil, country: nil, released: nil
        ), headers)
    }
}
