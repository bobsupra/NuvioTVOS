import SwiftUI
import Foundation

public struct UserProfileView: View {
    @StateObject private var viewModel: ProfileViewModel
    private let accountSyncError: String?
    private let onRetryAccountSync: (() -> Void)?
    private let onProfileCreated: (() -> Void)?
    @State private var showingAddProfile = false
    @State private var newProfileName = ""
    @State private var newProfilePin = ""
    @State private var newProfileAvatarId = ProfileAvatarCatalog.defaultId
    @FocusState private var focusedItem: String?

    private static let addProfileFocusId = "add_profile"

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
        NavigationView {
            ZStack {
                ProfileBackground()

                VStack(spacing: 0) {
                    Spacer().frame(height: 162)

                    Text("Who's watching?")
                        .font(.custom("Inter-Bold", size: 62))
                        .foregroundColor(.white)

                    Spacer().frame(height: 14)

                    Text("Select a profile to continue")
                        .font(.custom("Inter-Regular", size: 28))
                        .foregroundColor(.white.opacity(0.6))

                    if let profileCreationError = viewModel.profileCreationError {
                        Spacer().frame(height: 18)
                        Text(profileCreationError)
                            .font(.custom("Inter-Regular", size: 20))
                            .foregroundColor(.red.opacity(0.9))
                            .lineLimit(2)
                            .frame(maxWidth: 900)
                    }

                    if let accountSyncError, let onRetryAccountSync {
                        Spacer().frame(height: 18)
                        HStack(spacing: 18) {
                            Text(accountSyncError)
                                .font(.custom("Inter-Regular", size: 20))
                                .foregroundColor(.orange.opacity(0.9))
                                .lineLimit(2)

                            Button("Retry", action: onRetryAccountSync)
                                .buttonStyle(.bordered)
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

                        AddProfileButton(
                            isFocused: focusedItem == Self.addProfileFocusId
                        ) {
                            showingAddProfile = true
                        }
                        .focused($focusedItem, equals: Self.addProfileFocusId)
                    }
                    .padding(.horizontal, 80)
                    .frame(maxWidth: .infinity)

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
            .onAppear { AvatarCatalogStore.shared.loadIfNeeded() }
        }
    }

    private func handleProfileSelection(_ profile: Profile) {
        viewModel.requestSwitch(to: profile)
    }
}

/// Dark navy base with a soft blue glow toward the top, matching the brand.
private struct ProfileBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.10, blue: 0.18),
                    Color(red: 0.02, green: 0.03, blue: 0.06),
                    Color.black
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            RadialGradient(
                colors: [Color(red: 0.12, green: 0.30, blue: 0.55).opacity(0.55), .clear],
                center: .top,
                startRadius: 0,
                endRadius: 950
            )
        }
        .ignoresSafeArea()
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
                        .font(.custom("Inter-Bold", size: 28))
                        .foregroundColor(isFocused ? .white : Color.white.opacity(0.6))
                        .lineLimit(1)

                    if profile.isAdmin {
                        Text("PRIMARY")
                            .font(.custom("Inter-Bold", size: 16))
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

                Text("Add Profile")
                    .font(.custom("Inter-Bold", size: 28))
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
    /// A cold launch competing with the account pull can be rate limited, and
    /// one silent failure used to mean no avatar for the rest of the session.
    private static let maxAttempts = 4

    private init() {
        hydrateFromCache()
    }

    private func hydrateFromCache() {
        guard let data = UserDefaults.standard.data(forKey: Self.cacheKey),
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
                print("Avatar catalog load failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                scheduleRetry()
                return
            }
            let decoded = try JSONDecoder().decode([AvatarCatalogItem].self, from: data)
            apply(decoded)
            hasLoaded = true
            if let encoded = try? JSONEncoder().encode(items) {
                UserDefaults.standard.set(encoded, forKey: Self.cacheKey)
            }
            print("Avatar catalog loaded \(items.count) avatar(s).")
        } catch {
            print("Avatar catalog load failed: \(error.localizedDescription)")
            scheduleRetry()
        }
    }

    /// Retries a failed fetch with a widening delay. A cold launch fires the
    /// account pull, the Home catalogs and this within the same second, and the
    /// backend answers the loser with 429 — which is worth waiting out rather
    /// than leaving the profile without its picture until the app restarts.
    private func scheduleRetry() {
        guard attempts < Self.maxAttempts else {
            print("Avatar catalog load gave up after \(attempts) attempt(s).")
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

/// Renders a profile's avatar: the synced catalog image over its accent color,
/// a custom web image, or the brand gradient when no avatar is set.
struct ProfileAvatarView: View {
    let avatarId: String
    var size: CGFloat
    var isFocused: Bool = false

    @ObservedObject private var catalog = AvatarCatalogStore.shared

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

            if let imageURL {
                AsyncImage(url: imageURL) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color.clear
                    }
                }
            } else if catalogItem == nil {
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
                .stroke(isFocused ? AppFocusOutline.color : Color.white.opacity(0.28), lineWidth: isFocused ? AppFocusOutline.width : 1)
        )
        .shadow(color: .black.opacity(0.24), radius: isFocused ? 24 : 10, x: 0, y: 8)
        .onAppear { catalog.loadIfNeeded() }
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
                        Text("Add Profile")
                            .font(.system(size: 42, weight: .bold))
                            .foregroundColor(.white)

                        Text("Create a profile for another viewer")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundColor(.white.opacity(0.62))
                    }

                    Spacer()

                    ProfileAvatarView(avatarId: avatarId, size: 112)
                }

                VStack(alignment: .leading, spacing: 14) {
                    Text("Profile Info")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.white.opacity(0.62))

                    HStack(spacing: 18) {
                        AddProfileTextField(
                            placeholder: "Name",
                            text: $name,
                            focusedField: $focusedField,
                            field: .name
                        )

                        AddProfilePinButton(pinIsSet: !pin.isEmpty) {
                            showingPinSheet = true
                        }
                    }
                }

                Text("Avatar")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white.opacity(0.62))

                AvatarPickerGrid(selectedAvatarId: $avatarId, scrollsGrid: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                HStack(spacing: 16) {
                    ProfileAvatarPickerButton(title: "Cancel", systemImage: "xmark") {
                        isPresented = false
                    }

                    ProfileAvatarPickerButton(
                        title: "Save",
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
                        Text("Choose Avatar")
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
                    Text("Custom Avatar URL")
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

                    Text("Paste a direct image link, or choose an avatar below.")
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
                    ProfileAvatarPickerButton(title: "Cancel", systemImage: "xmark") {
                        isPresented = false
                    }

                    ProfileAvatarPickerButton(
                        title: "Save",
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
