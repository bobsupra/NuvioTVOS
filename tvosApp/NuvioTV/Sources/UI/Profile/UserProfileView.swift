import SwiftUI
import Foundation
import UIKit

public struct UserProfileView: View {
    @StateObject private var viewModel: ProfileViewModel
    private let accountSyncError: String?
    private let onRetryAccountSync: (() -> Void)?
    private let onProfileCreated: (() -> Void)?
    @State private var showingAddProfile = false
    @State private var newProfileName = ""
    @State private var newProfilePin = ""
    @State private var newProfileAvatarId = ProfileAvatarCatalog.defaultId
    @State private var focusedColor = Color(hex: "#1E88E5")
    @State private var focusedBackgroundUrl: String? = nil
    @State private var focusedBackgroundId: String? = nil
    @FocusState private var focusedItem: String?

    private static let addProfileFocusId = "add_profile"
    private static let retryFocusId = "retry_account_sync"

    public init(
        viewModel: ProfileViewModel,
        accountSyncError: String? = nil,
        onRetryAccountSync: (() -> Void)? = nil,
        onProfileCreated: (() -> Void)? = nil
    ) {
        _viewModel = StateObject(wrappedValue: viewModel)
        self.accountSyncError = accountSyncError
        self.onRetryAccountSync = onRetryAccountSync
        self.onProfileCreated = onProfileCreated
    }

    public var body: some View {
        ZStack {
            ProfileBackground(
                targetColor: focusedColor,
                backgroundUrl: focusedBackgroundUrl,
                backgroundId: focusedBackgroundId
            )

            VStack(spacing: 0) {
                Spacer().frame(height: 162)

                Text(L10n.string("profile_selection_title", fallback: "Who's watching?"))
                    .font(.appFont(size: 62, weight: .bold))
                    .foregroundColor(.white)

                Spacer().frame(height: 14)

                Text(L10n.string("profile_selection_subtitle", fallback: "Select a profile to continue"))
                    .font(.appFont(size: 28, weight: .regular))
                    .foregroundColor(.white.opacity(0.6))

                if let profileCreationError = viewModel.profileCreationError {
                    Spacer().frame(height: 18)
                    Text(profileCreationError)
                        .font(.appFont(size: 20, weight: .regular))
                        .foregroundColor(.red.opacity(0.9))
                        .lineLimit(2)
                        .frame(maxWidth: 900)
                }

                if let accountSyncError, let onRetryAccountSync {
                    Spacer().frame(height: 18)
                    HStack(spacing: 18) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(accountSyncError)
                                .font(.appFont(size: 20, weight: .regular))
                                .foregroundColor(.orange.opacity(0.9))
                                .fixedSize(horizontal: false, vertical: true)

                            Text(L10n.string(
                                "profile_account_sync_compatibility_message",
                                fallback: "Update all Nuvio clients to their latest versions, then select Retry. Older clients cannot sync account data."
                            ))
                                .font(.appFont(size: 16, weight: .regular))
                                .foregroundColor(.white.opacity(0.72))
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Button(L10n.string("common_retry", fallback: "Retry"), action: onRetryAccountSync)
                            .buttonStyle(.bordered)
                            .focused($focusedItem, equals: Self.retryFocusId)
                    }
                    .frame(maxWidth: 900)
                }

                Spacer()

                // Centered single row of profiles.
                HStack(alignment: .top, spacing: 56) {
                    ForEach(viewModel.profiles, id: \.id) { profile in
                        ProfileCard(
                            profile: profile,
                            isFocused: focusedItem == profile.id
                        ) {
                            handleProfileSelection(profile)
                        }
                        .focused($focusedItem, equals: profile.id)
                    }

                    if viewModel.canAddProfile {
                        AddProfileButton(
                            isFocused: focusedItem == Self.addProfileFocusId
                        ) {
                            showingAddProfile = true
                        }
                        .focused($focusedItem, equals: Self.addProfileFocusId)
                    }
                }
                .padding(.horizontal, 80)
                .frame(maxWidth: .infinity)
                .defaultFocusIfAvailable($focusedItem, initialFocusTarget())

                Spacer()

                Spacer().frame(height: 56)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .disabled(viewModel.isPinEntryVisible || showingAddProfile)

            if viewModel.isPinEntryVisible {
                ProfilePinView(viewModel: viewModel)
            }

            if showingAddProfile {
                AddProfileView(
                    isPresented: $showingAddProfile,
                    name: $newProfileName,
                    pin: $newProfilePin,
                    avatarId: $newProfileAvatarId
                ) {
                    viewModel.createProfile(
                        name: newProfileName,
                        pin: newProfilePin.isEmpty ? nil : newProfilePin,
                        avatarId: newProfileAvatarId,
                        onCreated: onProfileCreated
                    )
                    newProfileName = ""
                    newProfilePin = ""
                    newProfileAvatarId = ProfileAvatarCatalog.defaultId
                }
                .transition(.opacity)
                .zIndex(2)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: showingAddProfile)
        .onAppear {
            AvatarCatalogStore.shared.loadIfNeeded()
            ProfileBackgroundCatalogStore.shared.loadIfNeeded()
            if accountSyncError != nil, onRetryAccountSync != nil {
                focusRetryIfNeeded()
            } else if focusedItem == nil {
                focusedItem = initialFocusTarget()
            }
            updateFocusedColor(for: focusedItem ?? initialFocusTarget())
        }
        .onChange(of: focusedItem) { _, newFocus in
            updateFocusedColor(for: newFocus)
        }
        .onChange(of: accountSyncError) { _, _ in
            focusRetryIfNeeded()
        }
        .onChange(of: viewModel.profiles) { _, newProfiles in
            if focusedItem == Self.addProfileFocusId && !viewModel.canAddProfile {
                focusedItem = newProfiles.last?.id ?? newProfiles.first?.id
            }
            updateFocusedColor(for: focusedItem ?? initialFocusTarget())
        }
        .onReceive(AvatarCatalogStore.shared.$items) { _ in
            updateFocusedColor(for: focusedItem ?? initialFocusTarget())
        }
        .onReceive(ProfileBackgroundCatalogStore.shared.$items) { _ in
            updateFocusedColor(for: focusedItem ?? initialFocusTarget())
        }
    }

    private func initialFocusTarget() -> String? {
        if accountSyncError != nil, onRetryAccountSync != nil {
            return Self.retryFocusId
        }
        let activeOrLastId = viewModel.activeProfile?.id
            ?? viewModel.lastActiveProfileId
            ?? UserDefaults.standard.string(forKey: "nuvio.lastActiveProfileId")
        if let activeOrLastId, viewModel.profiles.contains(where: { $0.id == activeOrLastId }) {
            return activeOrLastId
        }
        return viewModel.profiles.first?.id
    }

    private func updateFocusedColor(for itemId: String?) {
        guard let itemId else {
            if let first = viewModel.profiles.first {
                focusedColor = profileColor(for: first)
                focusedBackgroundUrl = first.profileBackgroundUrl
                focusedBackgroundId = first.profileBackgroundId
            }
            return
        }
        if itemId == Self.addProfileFocusId {
            focusedColor = Color(hex: "#555555")
            focusedBackgroundUrl = nil
            focusedBackgroundId = nil
            return
        }
        if let profile = viewModel.profiles.first(where: { $0.id == itemId }) {
            focusedColor = profileColor(for: profile)
            focusedBackgroundUrl = profile.profileBackgroundUrl
            focusedBackgroundId = profile.profileBackgroundId
        }
    }

    private func profileColor(for profile: Profile) -> Color {
        if let item = AvatarCatalogStore.shared.item(for: profile.avatarId),
           let bgHex = item.bgColor, !bgHex.isEmpty {
            return Color(hex: bgHex)
        }
        let palette = [
            Color(hex: "#1E88E5"),
            Color(hex: "#E53935"),
            Color(hex: "#43A047"),
            Color(hex: "#FB8C00"),
            Color(hex: "#8E24AA"),
            Color(hex: "#00ACC1")
        ]
        if let idx = viewModel.profiles.firstIndex(where: { $0.id == profile.id }) {
            return palette[idx % palette.count]
        }
        return Color(hex: "#1E88E5")
    }

    private func focusRetryIfNeeded() {
        guard accountSyncError != nil, onRetryAccountSync != nil else { return }
        // The profile cards are the only other focusable controls on this
        // screen. Explicitly target Retry when the account bootstrap fails so
        // the Siri Remote can activate recovery even when the cards are empty.
        DispatchQueue.main.async {
            focusedItem = Self.retryFocusId
        }
    }

    private func handleProfileSelection(_ profile: Profile) {
        viewModel.requestSwitch(to: profile)
    }
}

/// Dynamic background matching Android TV and Compose: shifts color based on the focused profile
/// using 4 dynamic radial mesh gradient patches, dual blended wash gradients, and optional
/// contributor animated GIF or custom image backdrops with contrast vignette overlay.
struct ProfileBackground: View {
    var targetColor: Color = Color(hex: "#1E88E5")
    var backgroundUrl: String? = nil
    var backgroundId: String? = nil

    private static let background = Color(hex: "#0D0D0F")
    private static let backgroundElevated = Color(hex: "#1A1A1E")

    private var effectiveURL: URL? {
        ProfileBackgroundCatalogStore.shared.effectiveBackgroundURL(
            backgroundUrl: backgroundUrl,
            backgroundId: backgroundId
        )
    }

    private var isGIF: Bool {
        guard let url = effectiveURL else { return false }
        let ext = url.pathExtension.lowercased()
        if ext == "gif" { return true }
        if let query = url.query?.lowercased(),
           query.contains("format=gif") || query.contains("image/gif") {
            return true
        }
        return false
    }

    var body: some View {
        let gradientTop = Self.backgroundElevated.lerp(to: targetColor, fraction: 0.30)
        let gradientMid = Self.background.lerp(to: targetColor, fraction: 0.14)
        let halfFadeStrong = targetColor.opacity(0.26)
        let halfFadeSoft = targetColor.opacity(0.08)

        ZStack {
            // Base layer: deep dark background
            Self.background

            // 4-point dynamic radial mesh gradient patches reacting to profile targetColor
            GeometryReader { proxy in
                let w = proxy.size.width
                let h = proxy.size.height

                ZStack {
                    // Top-leading primary radial patch
                    RadialGradient(
                        colors: [targetColor.opacity(0.36), targetColor.opacity(0.12), .clear],
                        center: .topLeading,
                        startRadius: 20,
                        endRadius: max(w, h) * 0.72
                    )

                    // Top-trailing accent radial patch
                    RadialGradient(
                        colors: [targetColor.opacity(0.20), .clear],
                        center: .topTrailing,
                        startRadius: 10,
                        endRadius: max(w, h) * 0.55
                    )

                    // Bottom-leading soft radial glow
                    RadialGradient(
                        colors: [targetColor.opacity(0.15), .clear],
                        center: .bottomLeading,
                        startRadius: 20,
                        endRadius: max(w, h) * 0.65
                    )

                    // Bottom-trailing ambient depth patch
                    RadialGradient(
                        colors: [Self.backgroundElevated.opacity(0.85), .clear],
                        center: .bottomTrailing,
                        startRadius: 40,
                        endRadius: max(w, h) * 0.80
                    )
                }
            }

            // Android TV dual blended directional wash gradients
            LinearGradient(
                stops: [
                    .init(color: gradientTop, location: 0.0),
                    .init(color: gradientMid, location: 0.42),
                    .init(color: Self.background, location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            LinearGradient(
                stops: [
                    .init(color: halfFadeStrong, location: 0.0),
                    .init(color: halfFadeSoft, location: 0.45),
                    .init(color: .clear, location: 0.72),
                    .init(color: .clear, location: 1.0)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )

            // Contributor animated GIF or custom backdrop overlay
            if let url = effectiveURL {
                Group {
                    if isGIF {
                        AnimatedRemoteGIFView(
                            urlString: url.absoluteString,
                            contentMode: .scaleAspectFill,
                            maxPixelSize: 1920
                        )
                    } else {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            default:
                                Color.clear
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .transition(.opacity)

                // Contrast-protecting scrim and vignette over custom backdrop
                Color.black.opacity(0.48)

                LinearGradient(
                    stops: [
                        .init(color: Color.black.opacity(0.65), location: 0.0),
                        .init(color: .clear, location: 0.28),
                        .init(color: .clear, location: 0.72),
                        .init(color: Color.black.opacity(0.78), location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.45), value: effectiveURL)
        .animation(.easeInOut(duration: 0.52), value: targetColor)
    }
}

fileprivate extension Color {
    func lerp(to target: Color, fraction: CGFloat) -> Color {
        let clamped = max(0, min(1, fraction))
        let c1 = UIColor(self)
        let c2 = UIColor(target)

        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0

        guard c1.getRed(&r1, green: &g1, blue: &b1, alpha: &a1),
              c2.getRed(&r2, green: &g2, blue: &b2, alpha: &a2) else {
            return fraction > 0.5 ? target : self
        }

        return Color(
            red: Double(r1 + clamped * (r2 - r1)),
            green: Double(g1 + clamped * (g2 - g1)),
            blue: Double(b1 + clamped * (b2 - b1)),
            opacity: Double(a1 + clamped * (a2 - a1))
        )
    }
}

struct ProfileCard: View {
    let profile: Profile
    let isFocused: Bool
    let action: () -> Void

    private let avatarSize: CGFloat = 180

    var body: some View {
        Button(action: action) {
            VStack(spacing: 18) {
                ProfileAvatarView(
                    avatarId: profile.avatarId,
                    size: avatarSize,
                    isFocused: isFocused
                )
                .overlay(alignment: .bottomTrailing) { badge }

                VStack(spacing: 4) {
                    Text(profile.name)
                        .font(.appFont(size: 28, weight: .bold))
                        .foregroundColor(isFocused ? .white : Color.white.opacity(0.6))
                        .lineLimit(1)

                    if profile.isAdmin {
                        Text(L10n.string("profile_selection_primary_badge", fallback: "PRIMARY"))
                            .font(.appFont(size: 16, weight: .bold))
                            .tracking(1.5)
                            .foregroundColor(ProfileAvatarStyle.accent)
                    }
                }
            }
            .scaleEffect(isFocused ? 1.12 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
        }
        .buttonStyle(ProfilePlainButtonStyle())
        .focusEffectDisabled() // suppress tvOS default white halo; we draw our own ring
    }

    @ViewBuilder private var badge: some View {
        if profile.isAdmin {
            Image(systemName: "star.fill")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.white)
                .padding(11)
                .background(Circle().fill(ProfileAvatarStyle.accent))
                .offset(x: 4, y: 4)
        } else if profile.isPinProtected {
            Image(systemName: "lock.fill")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.white)
                .padding(12)
                .background(Circle().fill(Color.black.opacity(0.8)))
                .offset(x: 2, y: 2)
        }
    }
}

struct AddProfileButton: View {
    let isFocused: Bool
    let action: () -> Void

    private let avatarSize: CGFloat = 180

    var body: some View {
        Button(action: action) {
            VStack(spacing: 18) {
                Circle()
                    .fill(Color.white.opacity(isFocused ? 0.16 : 0.06))
                    .frame(width: avatarSize, height: avatarSize)
                    .overlay(
                        Image(systemName: "plus")
                            .font(.system(size: 62, weight: .light))
                            .foregroundColor(isFocused ? .white : Color.white.opacity(0.55))
                    )
                    .overlay(
                        Circle()
                            .stroke(isFocused ? AppFocusOutline.color : Color.white.opacity(0.3),
                                    lineWidth: isFocused ? AppFocusOutline.width : 2)
                    )

                Text(L10n.string("profile_add", fallback: "Add Profile"))
                    .font(.appFont(size: 28, weight: .bold))
                    .foregroundColor(isFocused ? .white : Color.white.opacity(0.6))
            }
            .scaleEffect(isFocused ? 1.12 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
        }
        .buttonStyle(ProfilePlainButtonStyle())
        .focusEffectDisabled() // suppress tvOS default white halo; we draw our own ring
    }
}

/// Renders only the button's label so tvOS doesn't draw its default focused
/// platter -- the avatar's own scale + white ring is the sole focus visual.
private struct ProfilePlainButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

// MARK: - Synced avatar catalog (mirrors the Android TV avatar system)

/// One avatar from the account's shared catalog (`get_avatar_catalog`). The
/// `id` is the server row referenced by `profiles.avatar_id`, so storing it
/// keeps profile pushes within the `fk_profiles_avatar_id` foreign key.
struct AvatarCatalogItem: Identifiable, Codable {
    let id: String
    let displayName: String
    let storagePath: String
    let category: String
    let sortOrder: Int
    let bgColor: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case storagePath = "storage_path"
        case category
        case sortOrder = "sort_order"
        case bgColor = "bg_color"
    }

    var imageURL: URL? {
        let path = storagePath.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !path.isEmpty else { return nil }
        return URL(string: "\(AuthConfig.normalizedAPIBaseURL)/storage/v1/object/public/avatars/\(path)")
    }

    /// Circle fill shown behind the (transparent-PNG) face while it loads and
    /// around its edges — the catalog ships a per-avatar accent color.
    var backgroundColor: Color {
        guard let bgColor, !bgColor.isEmpty else { return Color(red: 0.12, green: 0.30, blue: 0.55) }
        return Color(hex: bgColor)
    }
}

/// Fetches the shared avatar catalog and caches it. Loads with the publishable
/// key (no user session required), so avatars render on who's-watching even
/// before the account sync runs. Backed by a shared singleton so every avatar
/// surface resolves the same images.
///
/// The catalog is also persisted between launches. It is small, static
/// metadata, and without it a cold launch has no way to draw the active
/// profile's avatar until a network round-trip finishes — which is invisible on
/// who's-watching (the picker waits there anyway) but obvious when
/// auto-select-last goes straight to Home and the sidebar shows the fallback
/// person glyph.
@MainActor
final class AvatarCatalogStore: ObservableObject {
    static let shared = AvatarCatalogStore()

    @Published private(set) var items: [AvatarCatalogItem] = []
    private var byId: [String: AvatarCatalogItem] = [:]
    private var isLoading = false
    private var hasLoaded = false
    private var attempts = 0

    /// Shared (not profile-scoped): the catalog is account-wide and identical
    /// for every profile on the device.
    private static let cacheKey = "nuvio.tv.avatarCatalog.v1"
    private static let storageDirectoryName = "avatarCatalog"
    /// A cold launch competing with the account pull can be rate limited, and
    /// one silent failure used to mean no avatar for the rest of the session.
    private static let maxAttempts = 4

    private init() {
        hydrateFromCache()
    }

    private func hydrateFromCache() {
        let data: Data? = {
            if let fileData = LargePayloadStore.read(key: Self.cacheKey, directory: Self.storageDirectoryName) {
                return fileData
            }
            guard let legacy = UserDefaults.standard.data(forKey: Self.cacheKey) else { return nil }
            if LargePayloadStore.write(legacy, key: Self.cacheKey, directory: Self.storageDirectoryName) {
                UserDefaults.standard.removeObject(forKey: Self.cacheKey)
            }
            return legacy
        }()
        guard let data,
              let cached = try? JSONDecoder().decode([AvatarCatalogItem].self, from: data),
              !cached.isEmpty else { return }
        apply(cached)
    }

    func loadIfNeeded() {
        guard !hasLoaded, !isLoading, AuthConfig.isConfigured else { return }
        isLoading = true
        Task { await load() }
    }

    private func apply(_ catalog: [AvatarCatalogItem]) {
        let sorted = catalog.sorted { $0.sortOrder < $1.sortOrder }
        items = sorted
        byId = Dictionary(sorted.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func load() async {
        defer { isLoading = false }
        attempts += 1
        guard let url = URL(string: "\(AuthConfig.normalizedAPIBaseURL)/rest/v1/rpc/get_avatar_catalog") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(AuthConfig.apiKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(AuthConfig.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data("{}".utf8)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                scheduleRetry()
                return
            }
            let decoded = try JSONDecoder().decode([AvatarCatalogItem].self, from: data)
            apply(decoded)
            hasLoaded = true
            if let encoded = try? JSONEncoder().encode(items) {
                if LargePayloadStore.write(encoded, key: Self.cacheKey, directory: Self.storageDirectoryName) {
                    UserDefaults.standard.removeObject(forKey: Self.cacheKey)
                }
            }
        } catch {
            scheduleRetry()
        }
    }

    /// Retries a failed fetch with a widening delay. A cold launch fires the
    /// account pull, the Home catalogs and this within the same second, and the
    /// backend answers the loser with 429 — which is worth waiting out rather
    /// than leaving the profile without its picture until the app restarts.
    private func scheduleRetry() {
        guard attempts < Self.maxAttempts else {
            return
        }
        let delay = Double(attempts) * 2
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !self.hasLoaded else { return }
            self.isLoading = true
            await self.load()
        }
    }

    func item(for id: String?) -> AvatarCatalogItem? {
        guard let id, !id.isEmpty else { return nil }
        return byId[id]
    }

    /// Resolves both catalog ids and custom avatar URLs configured in the web
    /// panel. Custom URLs are stored directly in `avatarId`, so they are not
    /// present in `byId` and need to bypass the catalog lookup.
    func imageURL(for id: String?) -> URL? {
        guard let id = id?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty else { return nil }
        if let catalogURL = item(for: id)?.imageURL {
            return catalogURL
        }
        guard let url = URL(string: id),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else { return nil }
        return url
    }

    /// Categories shown as picker tabs: "All" first, then the marquee ones the
    /// Android app pins, then any remaining categories alphabetically.
    private static let pinnedCategories = ["anime", "animation", "tv", "movie", "gaming"]

    var categories: [String] {
        var seen = Set<String>()
        let ordered = items.map { $0.category.lowercased() }.filter { seen.insert($0).inserted }
        let pinned = Self.pinnedCategories.filter { ordered.contains($0) }
        let rest = ordered.filter { !Self.pinnedCategories.contains($0) }.sorted()
        return ["all"] + pinned + rest
    }

    func items(in category: String) -> [AvatarCatalogItem] {
        guard category != "all" else { return items }
        return items.filter { $0.category.caseInsensitiveCompare(category) == .orderedSame }
    }
}

/// Minimal shim kept so the tvOS tab bar (which can only show a system image,
/// not a remote avatar) and the "no avatar chosen" default keep compiling.
enum ProfileAvatarCatalog {
    /// Empty means "no avatar chosen yet" — the profile renders the brand
    /// gradient fallback until one is picked from the synced catalog. An empty
    /// id also pushes as a null `avatar_id`, staying within the FK constraint.
    static let defaultId = ""

    static func symbolName(for id: String?) -> String { "person.crop.circle" }
}

/// In-memory and persistent disk cache for avatar images matching Android's Glide/Coil behavior.
/// Eliminates CPU decoding spikes, redundant network queries, and socket allocations on screen appearance.
@MainActor
final class ProfileAvatarCache {
    static let shared = ProfileAvatarCache()
    nonisolated private static let tracker = NSCacheMemoryTracker(maxCost: 64 * 1024 * 1024)

    nonisolated static func telemetryMetrics() -> (count: Int, totalBytes: Int, maxCost: Int) {
        tracker.metrics()
    }

    private let cache = NSCache<NSURL, UIImage>()
    private let diskCacheDirectory: URL

    private init() {
        cache.countLimit = 200
        cache.totalCostLimit = Self.tracker.maxCost
        cache.delegate = Self.tracker
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        diskCacheDirectory = caches.appendingPathComponent("ProfileAvatars", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskCacheDirectory, withIntermediateDirectories: true)
    }

    private func diskFileURL(for url: URL) -> URL {
        let safeName = url.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? UUID().uuidString
        return diskCacheDirectory.appendingPathComponent(safeName)
    }

    func image(for url: URL) -> UIImage? {
        if let memory = cache.object(forKey: url as NSURL) {
            return memory
        }
        let diskURL = diskFileURL(for: url)
        if let data = try? Data(contentsOf: diskURL),
           let image = UIImage(data: data) {
            let cost = image.decodedByteCost
            cache.setObject(image, forKey: url as NSURL, cost: cost)
            Self.tracker.recordInsertion(cost: cost)
            return image
        }
        return nil
    }

    func setImage(_ image: UIImage, for url: URL) {
        let cost = image.decodedByteCost
        cache.setObject(image, forKey: url as NSURL, cost: cost)
        Self.tracker.recordInsertion(cost: cost)
        let diskURL = diskFileURL(for: url)
        if let data = image.pngData() {
            try? data.write(to: diskURL, options: .atomic)
        }
    }

    func fetchImage(for url: URL) async -> UIImage? {
        if let memory = cache.object(forKey: url as NSURL) {
            return memory
        }
        let diskURL = diskFileURL(for: url)
        if let diskData = try? Data(contentsOf: diskURL),
           let diskImage = UIImage(data: diskData) {
            let cost = diskImage.decodedByteCost
            cache.setObject(diskImage, forKey: url as NSURL, cost: cost)
            Self.tracker.recordInsertion(cost: cost)
            return diskImage
        }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let decoded = UIImage(data: data) else {
            return nil
        }
        let cost = decoded.decodedByteCost
        cache.setObject(decoded, forKey: url as NSURL, cost: cost)
        Self.tracker.recordInsertion(cost: cost)
        try? data.write(to: diskURL, options: .atomic)
        return decoded
    }
}

/// Renders a profile's avatar: the synced catalog image over its accent color,
/// a custom web image, or the brand gradient when no avatar is set.
struct ProfileAvatarView: View {
    let avatarId: String
    var size: CGFloat
    var isFocused: Bool = false
    var showsFocusOutline: Bool = true

    @ObservedObject private var catalog = AvatarCatalogStore.shared
    @State private var loadedImage: UIImage? = nil

    var body: some View {
        let catalogItem = catalog.item(for: avatarId)
        let imageURL = catalog.imageURL(for: avatarId)

        ZStack {
            if let catalogItem {
                Circle().fill(catalogItem.backgroundColor)
            } else {
                Circle().fill(
                    LinearGradient(
                        colors: [Color(red: 0.98, green: 0.45, blue: 0.78),
                                 Color(red: 0.44, green: 0.32, blue: 0.94)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            }

            if let displayImage = currentImage(for: imageURL) {
                Image(uiImage: displayImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if catalogItem == nil && imageURL == nil {
                Image(systemName: "sparkles")
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.18), radius: 5, x: 0, y: 3)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(
            Circle()
                .stroke(
                    (isFocused && showsFocusOutline) ? AppFocusOutline.color : Color.white.opacity(0.28),
                    lineWidth: (isFocused && showsFocusOutline) ? AppFocusOutline.width : 1
                )
        )
        .shadow(color: .black.opacity(0.24), radius: isFocused ? 24 : 10, x: 0, y: 8)
        .task(id: imageURL) {
            guard let imageURL else { return }
            if let img = await ProfileAvatarCache.shared.fetchImage(for: imageURL) {
                self.loadedImage = img
            }
        }
    }

    private func currentImage(for url: URL?) -> UIImage? {
        guard let url else { return nil }
        if let hit = ProfileAvatarCache.shared.image(for: url) {
            return hit
        }
        return loadedImage
    }
}

/// Stable accent used by the primary-profile star / label.
enum ProfileAvatarStyle {
    static let accent = Color(red: 0.98, green: 0.67, blue: 0.12) // primary star / label
}

struct AddProfileView: View {
    @Binding var isPresented: Bool
    @Binding var name: String
    @Binding var pin: String
    @Binding var avatarId: String
    var onSave: () -> Void

    @FocusState private var focusedField: Field?
    @State private var showingPinSheet = false

    fileprivate enum Field {
        case name
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (pin.isEmpty || pin.count == 4)
    }

    var body: some View {
        ZStack {
            ProfileBackground()
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .center, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.string("profile_add", fallback: "Add Profile"))
                            .font(.system(size: 42, weight: .bold))
                            .foregroundColor(.white)

                        Text(L10n.string(
                            "profile_create_for_another_viewer",
                            fallback: "Create a profile for another viewer"
                        ))
                            .font(.system(size: 22, weight: .medium))
                            .foregroundColor(.white.opacity(0.62))
                    }

                    Spacer()

                    ProfileAvatarView(avatarId: avatarId, size: 112)
                }

                VStack(alignment: .leading, spacing: 14) {
                    Text(L10n.string("profile_info", fallback: "Profile Info"))
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.white.opacity(0.62))

                    HStack(spacing: 18) {
                        AddProfileTextField(
                            placeholder: L10n.string("library_list_name_label", fallback: "Name"),
                            text: $name,
                            focusedField: $focusedField,
                            field: .name
                        )

                        AddProfilePinButton(pinIsSet: !pin.isEmpty) {
                            showingPinSheet = true
                        }
                    }
                }

                Text(L10n.string("profile_avatar_title", fallback: "Avatar"))
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white.opacity(0.62))

                AvatarPickerGrid(selectedAvatarId: $avatarId, scrollsGrid: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                HStack(spacing: 16) {
                    ProfileAvatarPickerButton(title: L10n.string("profile_cancel", fallback: "Cancel"), systemImage: "xmark") {
                        isPresented = false
                    }

                    ProfileAvatarPickerButton(
                        title: L10n.string("profile_save", fallback: "Save"),
                        systemImage: "checkmark",
                        prominent: true,
                        disabled: !canSave
                    ) {
                        onSave()
                        isPresented = false
                    }
                }
            }
            .padding(.horizontal, 84)
            .padding(.vertical, 62)
            .frame(maxWidth: 1180, maxHeight: .infinity)
            .disabled(showingPinSheet)

            if showingPinSheet {
                ProfilePinManagementView(
                    mode: .enable,
                    profileName: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "this profile"
                        : name.trimmingCharacters(in: .whitespacesAndNewlines),
                    onVerify: { _ in true },
                    onSave: { newPin, _ in
                        pin = newPin ?? ""
                        return true
                    },
                    onDismiss: {
                        showingPinSheet = false
                    }
                )
                .transition(.opacity)
                .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: showingPinSheet)
        .onExitCommand(perform: handleExitCommand)
        .onAppear {
            DispatchQueue.main.async { focusedField = .name }
        }
    }

    private func handleExitCommand() {
        if showingPinSheet {
            showingPinSheet = false
        } else {
            isPresented = false
        }
    }
}

private struct AddProfileTextField: View {
    let placeholder: String
    @Binding var text: String
    var focusedField: FocusState<AddProfileView.Field?>.Binding
    let field: AddProfileView.Field

    @State private var isEditing = false

    var body: some View {
        Button {
            isEditing = true
        } label: {
            SettingsGlassTextField(
                text: $text,
                placeholder: placeholder,
                focused: focusedField.wrappedValue == field,
                isEditing: $isEditing,
                fieldWidth: 490,
                centerDisplayText: true
            )
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused(focusedField, equals: field)
        .focusEffectDisabledIfAvailable()
    }
}

private struct AddProfilePinButton: View {
    let pinIsSet: Bool
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Label(
                pinIsSet ? "PIN Set" : "Set PIN (Optional)",
                systemImage: pinIsSet ? "lock.fill" : "lock"
            )
            .font(.system(size: 20, weight: .semibold))
            .foregroundColor(.white.opacity(pinIsSet ? 1 : 0.62))
            .frame(width: 490, height: 48)
            .modifier(GlassCapsule(focused: isFocused))
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($isFocused)
        .focusEffectDisabledIfAvailable()
    }
}

/// Category-tabbed grid of the synced avatar catalog, matching the Android TV
/// avatar picker. Selecting an item stores its server id in `selectedAvatarId`.
struct AvatarPickerGrid: View {
    @Binding var selectedAvatarId: String
    var onSelectAvatar: ((String) -> Void)? = nil
    var scrollsGrid = false

    @ObservedObject private var catalog = AvatarCatalogStore.shared
    @State private var selectedCategory = "all"

    private let columns = [GridItem(.adaptive(minimum: 118, maximum: 118), spacing: 18)]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if catalog.items.isEmpty {
                HStack {
                    Spacer()
                    ProgressView().tint(.white)
                    Spacer()
                }
                .padding(.vertical, 24)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(catalog.categories, id: \.self) { category in
                            AvatarCategoryTab(
                                label: categoryLabel(category),
                                isSelected: selectedCategory == category
                            ) {
                                selectedCategory = category
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 4)
                }

                grid
            }
        }
        .onAppear { catalog.loadIfNeeded() }
    }

    @ViewBuilder
    private var grid: some View {
        if scrollsGrid {
            ScrollView {
                gridContent
                    .padding(.vertical, 6)
            }
        } else {
            gridContent
        }
    }

    private var gridContent: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
            ForEach(catalog.items(in: selectedCategory)) { avatar in
                AvatarGridCell(
                    avatar: avatar,
                    isSelected: avatar.id == selectedAvatarId
                ) {
                    selectedAvatarId = avatar.id
                    onSelectAvatar?(avatar.id)
                }
            }
        }
    }

    private func categoryLabel(_ category: String) -> String {
        category == "all" ? "All" : category.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

private struct AvatarCategoryTab: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(isSelected || isFocused ? .black : .white.opacity(0.68))
                .padding(.horizontal, 20)
                .frame(height: 44)
                .loginGlassCapsule(highlighted: isSelected || isFocused)
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($isFocused)
        .focusEffectDisabledIfAvailable()
        .scaleEffect(isFocused ? 1.05 : 1)
        .animation(.easeOut(duration: 0.12), value: isFocused)
    }
}

private struct AvatarGridCell: View {
    let avatar: AvatarCatalogItem
    let isSelected: Bool
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    Circle().fill(avatar.backgroundColor)
                    AsyncImage(url: avatar.imageURL) { phase in
                        if let image = phase.image {
                            image.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Color.clear
                        }
                    }
                }
                .frame(width: 96, height: 96)
                .clipShape(Circle())
                .overlay(
                    Circle().stroke(
                        isSelected || isFocused ? Color.white : Color.white.opacity(0.12),
                        lineWidth: isFocused ? AppFocusOutline.width : (isSelected ? 3 : 1)
                    )
                )
                .scaleEffect(isFocused ? 1.1 : 1)
                .animation(.easeInOut(duration: 0.15), value: isFocused)

                Text(avatar.displayName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white.opacity(isFocused ? 1 : 0.7))
                    .lineLimit(1)
            }
            .frame(width: 118)
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($isFocused)
        .focusEffectDisabledIfAvailable()
    }
}

struct ProfileAvatarPickerSheet: View {
    @Binding var isPresented: Bool
    let title: String
    @State private var selectedAvatarId: String
    @State private var customAvatarURL: String
    @State private var isEditingCustomAvatarURL = false
    @FocusState private var isCustomAvatarFieldFocused: Bool
    let onSave: (String) -> Void

    init(isPresented: Binding<Bool>, title: String, selectedAvatarId: String, onSave: @escaping (String) -> Void) {
        _isPresented = isPresented
        self.title = title
        _selectedAvatarId = State(initialValue: selectedAvatarId)
        _customAvatarURL = State(initialValue: Self.validCustomAvatarURL(selectedAvatarId) ?? "")
        self.onSave = onSave
    }

    var body: some View {
        ZStack {
            ProfileBackground()
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .center, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.string("profile_choose_avatar", fallback: "Choose Avatar"))
                            .font(.system(size: 42, weight: .bold))
                            .foregroundColor(.white)

                        Text(title)
                            .font(.system(size: 22, weight: .medium))
                            .foregroundColor(.white.opacity(0.62))
                    }

                    Spacer()

                    ProfileAvatarView(avatarId: selectedAvatarId, size: 112)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.string("profile_custom_avatar_url_title", fallback: "Custom Avatar URL"))
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.white.opacity(0.72))

                    Button {
                        isEditingCustomAvatarURL = true
                    } label: {
                        SettingsGlassTextField(
                            text: $customAvatarURL,
                            placeholder: "https://example.com/avatar.jpg",
                            focused: isCustomAvatarFieldFocused,
                            isEditing: $isEditingCustomAvatarURL,
                            fieldWidth: 760,
                            onCommit: applyCustomAvatarURL
                        )
                    }
                    .buttonStyle(ProfilePlainButtonStyle())
                    .focused($isCustomAvatarFieldFocused)
                    .focusEffectDisabledIfAvailable()

                    Text(L10n.string(
                        "profile_custom_avatar_url_hint",
                        fallback: "Paste a direct image link, or choose an avatar below."
                    ))
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(.white.opacity(0.48))
                }

                AvatarPickerGrid(
                    selectedAvatarId: $selectedAvatarId,
                    onSelectAvatar: { _ in customAvatarURL = "" },
                    scrollsGrid: true
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                HStack(spacing: 16) {
                    ProfileAvatarPickerButton(title: L10n.string("profile_cancel", fallback: "Cancel"), systemImage: "xmark") {
                        isPresented = false
                    }

                    ProfileAvatarPickerButton(
                        title: L10n.string("profile_save", fallback: "Save"),
                        systemImage: "checkmark",
                        prominent: true,
                        disabled: avatarToSave == nil
                    ) {
                        guard let avatarToSave else { return }
                        onSave(avatarToSave)
                        isPresented = false
                    }
                }
            }
            .padding(.horizontal, 84)
            .padding(.vertical, 62)
            .frame(maxWidth: 1180, maxHeight: .infinity)
        }
    }

    private var avatarToSave: String? {
        let customURL = customAvatarURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !customURL.isEmpty {
            return Self.validCustomAvatarURL(customURL)
        }
        return selectedAvatarId.isEmpty ? nil : selectedAvatarId
    }

    private func applyCustomAvatarURL() {
        guard let customURL = Self.validCustomAvatarURL(customAvatarURL) else { return }
        customAvatarURL = customURL
        selectedAvatarId = customURL
        isEditingCustomAvatarURL = false
    }

    private static func validCustomAvatarURL(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else { return nil }
        return trimmed
    }
}

private struct ProfileAvatarPickerButton: View {
    let title: String
    let systemImage: String
    var prominent: Bool = false
    var disabled: Bool = false
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(foreground)
                .padding(.horizontal, 28)
                .frame(height: 58)
                .frame(minWidth: 190)
                .loginGlassCapsule(highlighted: isFocused, prominent: prominent)
                .opacity(disabled ? 0.5 : 1)
                .scaleEffect(isFocused && !disabled ? 1.03 : 1)
        }
        .buttonStyle(PosterCardButtonStyle())
        .disabled(disabled)
        .focused($isFocused)
        .focusEffectDisabledIfAvailable()
        .animation(.easeOut(duration: 0.12), value: isFocused)
    }

    private var foreground: Color {
        if isFocused { return .black }
        return prominent ? .black : .white
    }
}

// MARK: - Synced profile background catalog (supporter / contributor backgrounds)

struct ProfileBackgroundCatalogItem: Identifiable, Codable, Equatable {
    let id: String
    let displayName: String
    let storagePath: String
    let portraitStoragePath: String?
    let assetVersion: Int

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case storagePath = "storage_path"
        case portraitStoragePath = "portrait_storage_path"
        case assetVersion = "asset_version"
    }

    var imageURL: URL? {
        let path = storagePath.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !path.isEmpty else { return nil }
        return URL(string: "\(AuthConfig.normalizedAPIBaseURL)/storage/v1/object/public/membership-profile-backgrounds/\(path)")
    }
}

@MainActor
final class ProfileBackgroundCatalogStore: ObservableObject {
    static let shared = ProfileBackgroundCatalogStore()

    @Published private(set) var items: [ProfileBackgroundCatalogItem] = []
    private var byId: [String: ProfileBackgroundCatalogItem] = [:]
    private var isLoading = false
    private var hasLoaded = false
    private var attempts = 0

    private static let cacheKey = "nuvio.tv.profileBackgroundCatalog.v1"
    private static let storageDirectoryName = "profileBackgroundCatalog"
    private static let maxAttempts = 3

    static let defaultPresets: [ProfileBackgroundCatalogItem] = [
        ProfileBackgroundCatalogItem(
            id: "open_road",
            displayName: "Open Road",
            storagePath: "open_road.png",
            portraitStoragePath: nil,
            assetVersion: 1
        ),
        ProfileBackgroundCatalogItem(
            id: "sunlit_coast",
            displayName: "Sunlit Coast",
            storagePath: "sunlit_coast.png",
            portraitStoragePath: nil,
            assetVersion: 1
        ),
        ProfileBackgroundCatalogItem(
            id: "teal_horizon",
            displayName: "Teal Horizon",
            storagePath: "teal_horizon.png",
            portraitStoragePath: nil,
            assetVersion: 1
        ),
        ProfileBackgroundCatalogItem(
            id: "neon_pulse",
            displayName: "Neon Pulse",
            storagePath: "neon_pulse.png",
            portraitStoragePath: nil,
            assetVersion: 1
        ),
        ProfileBackgroundCatalogItem(
            id: "midnight_nebula",
            displayName: "Midnight Nebula",
            storagePath: "midnight_nebula.png",
            portraitStoragePath: nil,
            assetVersion: 1
        )
    ]

    private init() {
        apply(Self.defaultPresets)
        hydrateFromCache()
    }

    private func hydrateFromCache() {
        let data: Data? = {
            if let fileData = LargePayloadStore.read(key: Self.cacheKey, directory: Self.storageDirectoryName) {
                return fileData
            }
            guard let legacy = UserDefaults.standard.data(forKey: Self.cacheKey) else { return nil }
            if LargePayloadStore.write(legacy, key: Self.cacheKey, directory: Self.storageDirectoryName) {
                UserDefaults.standard.removeObject(forKey: Self.cacheKey)
            }
            return legacy
        }()
        guard let data,
              let cached = try? JSONDecoder().decode([ProfileBackgroundCatalogItem].self, from: data),
              !cached.isEmpty else { return }
        apply(cached)
    }

    func loadIfNeeded() {
        guard !hasLoaded, !isLoading, AuthConfig.isConfigured else { return }
        isLoading = true
        Task { await load() }
    }

    private func apply(_ catalog: [ProfileBackgroundCatalogItem]) {
        var merged = Self.defaultPresets
        for item in catalog {
            if let idx = merged.firstIndex(where: { $0.id == item.id }) {
                merged[idx] = item
            } else {
                merged.append(item)
            }
        }
        items = merged
        byId = Dictionary(merged.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func load() async {
        defer { isLoading = false }
        attempts += 1
        guard let url = URL(string: "\(AuthConfig.normalizedAPIBaseURL)/rest/v1/rpc/get_member_profile_background_catalog") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(AuthConfig.apiKey, forHTTPHeaderField: "apikey")
        let sessionToken = SessionStore().load()?.accessToken
        let token = (sessionToken?.isEmpty == false) ? sessionToken! : AuthConfig.apiKey
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data("{}".utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                scheduleRetry()
                return
            }
            let decoded = try JSONDecoder().decode([ProfileBackgroundCatalogItem].self, from: data)
            apply(decoded)
            hasLoaded = true
            if let encoded = try? JSONEncoder().encode(items) {
                if LargePayloadStore.write(encoded, key: Self.cacheKey, directory: Self.storageDirectoryName) {
                    UserDefaults.standard.removeObject(forKey: Self.cacheKey)
                }
            }
        } catch {
            scheduleRetry()
        }
    }

    private func scheduleRetry() {
        guard attempts < Self.maxAttempts else { return }
        let delay = Double(attempts) * 2
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !self.hasLoaded else { return }
            self.isLoading = true
            await self.load()
        }
    }

    func item(for id: String?) -> ProfileBackgroundCatalogItem? {
        guard let id = id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return nil }
        return byId[id]
    }

    func imageURL(for id: String?) -> URL? {
        guard let id = id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return nil }
        if let catalogURL = item(for: id)?.imageURL {
            return catalogURL
        }
        guard let url = URL(string: id),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else { return nil }
        return url
    }

    func effectiveBackgroundURL(backgroundUrl: String?, backgroundId: String?) -> URL? {
        if let urlStr = backgroundUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
           !urlStr.isEmpty,
           let url = URL(string: urlStr),
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https",
           url.host != nil {
            return url
        }
        if let bgId = backgroundId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !bgId.isEmpty {
            return imageURL(for: bgId)
        }
        return nil
    }
}

// MARK: - Profile Background Picker Sheet

struct ProfileBackgroundPickerSheet: View {
    @Binding var isPresented: Bool
    let title: String
    let standardColor: Color
    @State private var selectedBackgroundId: String?
    @State private var selectedBackgroundUrl: String?
    @State private var customURL: String
    @State private var isEditingCustomURL = false
    @FocusState private var isCustomURLFieldFocused: Bool
    @ObservedObject private var catalog = ProfileBackgroundCatalogStore.shared
    let onSave: (String?, String?) -> Void

    init(
        isPresented: Binding<Bool>,
        title: String,
        standardColor: Color,
        initialBackgroundId: String?,
        initialBackgroundUrl: String?,
        onSave: @escaping (String?, String?) -> Void
    ) {
        _isPresented = isPresented
        self.title = title
        self.standardColor = standardColor
        _selectedBackgroundId = State(initialValue: initialBackgroundId)
        _selectedBackgroundUrl = State(initialValue: initialBackgroundUrl)
        _customURL = State(initialValue: initialBackgroundUrl ?? "")
        self.onSave = onSave
    }

    private var previewURL: String? {
        let trimmed = customURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return selectedBackgroundUrl
    }

    private var previewID: String? {
        let trimmed = customURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty || selectedBackgroundUrl != nil { return nil }
        return selectedBackgroundId
    }

    private var isStandardSelected: Bool {
        selectedBackgroundId == nil && selectedBackgroundUrl == nil && customURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ZStack {
            ProfileBackground(
                targetColor: standardColor,
                backgroundUrl: previewURL,
                backgroundId: previewID
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 24) {
                // Header with live preview
                HStack(alignment: .center, spacing: 28) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.string("profile_background_title", fallback: "Profile Background"))
                            .font(.system(size: 42, weight: .bold))
                            .foregroundColor(.white)

                        Text(title)
                            .font(.system(size: 22, weight: .medium))
                            .foregroundColor(.white.opacity(0.62))
                    }

                    Spacer()

                    // Live preview box
                    ZStack {
                        ProfileBackground(
                            targetColor: standardColor,
                            backgroundUrl: previewURL,
                            backgroundId: previewID
                        )
                        .frame(width: 256, height: 144)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.white.opacity(0.35), lineWidth: 2)
                        )
                    }
                    .frame(width: 256, height: 144)
                }

                // Custom URL input
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.string("profile_custom_background_url_title", fallback: "Custom Image or Animated GIF URL"))
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.white.opacity(0.72))

                    Button {
                        isEditingCustomURL = true
                    } label: {
                        SettingsGlassTextField(
                            text: $customURL,
                            placeholder: "https://example.com/background.gif",
                            focused: isCustomURLFieldFocused,
                            isEditing: $isEditingCustomURL,
                            fieldWidth: 760,
                            onCommit: applyCustomURL
                        )
                    }
                    .buttonStyle(ProfilePlainButtonStyle())
                    .focused($isCustomURLFieldFocused)
                    .focusEffectDisabledIfAvailable()

                    Text(L10n.string(
                        "profile_custom_background_url_hint",
                        fallback: "Paste a direct link to an animated GIF or image, or choose a contributor preset below."
                    ))
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white.opacity(0.48))
                }

                // Presets
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.string("profile_background_presets_title", fallback: "Curated Presets"))
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.white.opacity(0.72))

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 20) {
                            // Standard mesh gradient
                            ProfileBackgroundGridCell(
                                title: L10n.string("profile_background_normal", fallback: "Standard"),
                                isSelected: isStandardSelected
                            ) {
                                selectStandard()
                            } preview: {
                                ProfileBackground(
                                    targetColor: standardColor,
                                    backgroundUrl: nil,
                                    backgroundId: nil
                                )
                            }

                            // Curated contributor presets
                            ForEach(catalog.items) { item in
                                ProfileBackgroundGridCell(
                                    title: item.displayName,
                                    isSelected: selectedBackgroundId == item.id && customURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ) {
                                    selectPreset(item)
                                } preview: {
                                    ProfileBackground(
                                        targetColor: standardColor,
                                        backgroundUrl: nil,
                                        backgroundId: item.id
                                    )
                                }
                            }
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 4)
                    }
                }

                HStack(spacing: 16) {
                    ProfileAvatarPickerButton(
                        title: L10n.string("profile_cancel", fallback: "Cancel"),
                        systemImage: "xmark"
                    ) {
                        isPresented = false
                    }

                    ProfileAvatarPickerButton(
                        title: L10n.string("profile_save", fallback: "Save"),
                        systemImage: "checkmark",
                        prominent: true
                    ) {
                        saveSelection()
                    }
                }
            }
            .padding(.horizontal, 84)
            .padding(.vertical, 54)
            .frame(maxWidth: 1180, maxHeight: .infinity)
        }
        .onAppear {
            catalog.loadIfNeeded()
        }
    }

    private func selectStandard() {
        selectedBackgroundId = nil
        selectedBackgroundUrl = nil
        customURL = ""
    }

    private func selectPreset(_ item: ProfileBackgroundCatalogItem) {
        selectedBackgroundId = item.id
        selectedBackgroundUrl = nil
        customURL = ""
    }

    private func applyCustomURL() {
        let trimmed = customURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            selectedBackgroundId = nil
            selectedBackgroundUrl = trimmed
        }
        isEditingCustomURL = false
    }

    private func saveSelection() {
        let trimmedCustom = customURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCustom.isEmpty {
            onSave(nil, trimmedCustom)
        } else if let bgId = selectedBackgroundId {
            onSave(bgId, nil)
        } else {
            onSave(nil, nil)
        }
        isPresented = false
    }
}

private struct ProfileBackgroundGridCell<Content: View>: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let preview: () -> Content
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                preview()
                    .frame(width: 176, height: 99)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(
                                isSelected || isFocused ? Color.white : Color.white.opacity(0.18),
                                lineWidth: isFocused ? AppFocusOutline.width : (isSelected ? 3 : 1)
                            )
                    )
                    .scaleEffect(isFocused ? 1.08 : 1)
                    .animation(.easeInOut(duration: 0.15), value: isFocused)

                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white.opacity(isFocused ? 1 : (isSelected ? 0.95 : 0.68)))
                    .lineLimit(1)
            }
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($isFocused)
        .focusEffectDisabledIfAvailable()
    }
}
