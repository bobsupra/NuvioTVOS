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

                if viewModel.isPinEntryVisible {
                    ProfilePinView(viewModel: viewModel)
                }
            }
            .onAppear { AvatarCatalogStore.shared.loadIfNeeded() }
            .sheet(isPresented: $showingAddProfile) {
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
            }
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
                    .shadow(color: isFocused ? Color.white.opacity(0.3) : .clear, radius: 24)

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
struct AvatarCatalogItem: Identifiable, Decodable {
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
        return URL(string: "\(AuthConfig.normalizedSupabaseURL)/storage/v1/object/public/avatars/\(path)")
    }

    /// Circle fill shown behind the (transparent-PNG) face while it loads and
    /// around its edges — the catalog ships a per-avatar accent color.
    var backgroundColor: Color {
        guard let bgColor, !bgColor.isEmpty else { return Color(red: 0.12, green: 0.30, blue: 0.55) }
        return Color(hex: bgColor)
    }
}

/// Fetches the shared avatar catalog once and caches it for the session. Loads
/// with the publishable key (no user session required), so avatars render on
/// who's-watching even before the account sync runs. Backed by a shared
/// singleton so every avatar surface resolves the same images.
@MainActor
final class AvatarCatalogStore: ObservableObject {
    static let shared = AvatarCatalogStore()

    @Published private(set) var items: [AvatarCatalogItem] = []
    private var byId: [String: AvatarCatalogItem] = [:]
    private var isLoading = false
    private var hasLoaded = false

    private init() {}

    func loadIfNeeded() {
        guard !hasLoaded, !isLoading, AuthConfig.isConfigured else { return }
        isLoading = true
        Task { await load() }
    }

    private func load() async {
        defer { isLoading = false }
        guard let url = URL(string: "\(AuthConfig.normalizedSupabaseURL)/rest/v1/rpc/get_avatar_catalog") else { return }
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
                return
            }
            let decoded = try JSONDecoder().decode([AvatarCatalogItem].self, from: data)
            let sorted = decoded.sorted { $0.sortOrder < $1.sortOrder }
            items = sorted
            byId = Dictionary(sorted.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            hasLoaded = true
            print("Avatar catalog loaded \(sorted.count) avatar(s).")
        } catch {
            print("Avatar catalog load failed: \(error.localizedDescription)")
        }
    }

    func item(for id: String?) -> AvatarCatalogItem? {
        guard let id, !id.isEmpty else { return nil }
        return byId[id]
    }

    func imageURL(for id: String?) -> URL? { item(for: id)?.imageURL }

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
/// or the brand gradient when no avatar is set / the catalog hasn't loaded.
struct ProfileAvatarView: View {
    let avatarId: String
    var size: CGFloat
    var isFocused: Bool = false

    @ObservedObject private var catalog = AvatarCatalogStore.shared

    var body: some View {
        ZStack {
            if let item = catalog.item(for: avatarId) {
                Circle().fill(item.backgroundColor)
                AsyncImage(url: item.imageURL) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color.clear
                    }
                }
            } else {
                Circle().fill(
                    LinearGradient(
                        colors: [Color(red: 0.98, green: 0.45, blue: 0.78),
                                 Color(red: 0.44, green: 0.32, blue: 0.94)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
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
        .shadow(color: isFocused ? Color.white.opacity(0.3) : .black.opacity(0.24),
                radius: isFocused ? 24 : 10, x: 0, y: 8)
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

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Profile Info")) {
                    TextField("Name", text: $name)
                    SecureField("PIN (Optional)", text: $pin)
                        .keyboardType(.numberPad)
                }

                Section(header: Text("Avatar")) {
                    AvatarPickerGrid(selectedAvatarId: $avatarId)
                }

                Button("Save") {
                    onSave()
                    isPresented = false
                }
                .disabled(name.isEmpty)
            }
            .navigationTitle("Add Profile")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }
            }
        }
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
    let onSave: (String) -> Void

    init(isPresented: Binding<Bool>, title: String, selectedAvatarId: String, onSave: @escaping (String) -> Void) {
        _isPresented = isPresented
        self.title = title
        _selectedAvatarId = State(initialValue: selectedAvatarId)
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

                AvatarPickerGrid(selectedAvatarId: $selectedAvatarId, scrollsGrid: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                HStack(spacing: 16) {
                    ProfileAvatarPickerButton(title: "Cancel", systemImage: "xmark") {
                        isPresented = false
                    }

                    ProfileAvatarPickerButton(
                        title: "Save",
                        systemImage: "checkmark",
                        prominent: true,
                        disabled: selectedAvatarId.isEmpty
                    ) {
                        onSave(selectedAvatarId)
                        isPresented = false
                    }
                }
            }
            .padding(.horizontal, 84)
            .padding(.vertical, 62)
            .frame(maxWidth: 1180, maxHeight: .infinity)
        }
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
