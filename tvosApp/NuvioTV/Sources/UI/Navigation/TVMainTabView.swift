import SwiftUI
import UIKit

/// The sidebar-adaptable tab view that hosts Home, Search, Library, Settings
/// and the profile switcher. Owned by `ContentView` in NuvioTVApp.swift.
struct TVMainTabView: View {
    @Binding var selectedTab: TVTab
    let activeProfile: Profile?
    @ObservedObject var searchViewModel: SearchViewModel
    @ObservedObject var netflixSearchViewModel: NetflixSearchViewModel
    @ObservedObject var libraryViewModel: LibraryViewModel
    @ObservedObject var homeStore: TVHomeStore
    let homeCatalogRevision: UInt
    let homeCollectionsRevision: UInt
    let isFullScreenOverlayPresented: Bool
    let detailsDidDisappearGeneration: UInt
    let accountEmail: String?
    let isAuthenticated: Bool
    let sessionNeedsReauthentication: Bool
    let isProfileSwitching: Bool
    let authManager: AuthManager
    let syncManager: NuvioSyncManager
    let onSwitchProfile: () -> Void
    let onChangeProfileAvatar: (String, String) -> Void
    let onChangeProfileName: (String, String) -> Void
    let onChangeProfilePin: (String, String?, String?) async -> Bool
    let onVerifyProfilePin: (String, String) async -> Bool
    let onSignIn: () -> Void
    let onSignOut: () -> Void
    let onNavigateToDetails: (String, String) -> Void
    let onRequestAccountRefresh: () -> Void
    let onOpenCollectionFolder: (TVCollectionFolderItem, String) -> Void
    let onResumePlayback: (ContinueWatchingItem) -> Void
    var onPlayContinueWatchingManually: ((ContinueWatchingItem) -> Void)? = nil
    var onStartContinueWatchingFromBeginning: ((ContinueWatchingItem) -> Void)? = nil
    var onRemoveFromContinueWatching: ((ContinueWatchingItem) -> Void)? = nil
    let onLongPressCard: (NuvioMeta) -> Void
    /// Long press on a Continue Watching card, which gets its own resume-centric
    /// menu instead of the generic title actions.
    let onLongPressContinueWatching: (ContinueWatchingItem) -> Void
    let onOpenCloudLibrary: () -> Void
    let onPlayCloudFile: (URL, NuvioMeta) -> Void
    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue
    @AppStorage(SettingsKey.discoverLocation) private var discoverLocation = "Search"
    @AppStorage(SettingsKey.searchStyle) private var searchStyle = "Netflix"
    @AppStorage(SettingsKey.profileName) private var settingsProfileName = "Nuvio User"
    @StateObject private var profileTabAvatar = ProfileTabAvatarRenderer()
    @State private var showingReauthSheet = false

    private var displayedProfile: Profile? {
        if isAuthenticated { return activeProfile }
        return activeProfile?.id == "guest" ? activeProfile : nil
    }

    /// Name shown on the profile tab, mirroring the sidebar header's
    /// display-name logic.
    private var profileTabTitle: String {
        guard let displayedProfile else { return "Nuvio Guest" }
        return ProfileDisplayName.resolve(profile: displayedProfile, settingsName: settingsProfileName)
    }

    var body: some View {
        tabs
            .tabViewStyle(.sidebarAdaptable)
    }

    /// Search screen chosen in Settings → Layout & Discovery → Search Style.
    @ViewBuilder
    private var searchTab: some View {
        if searchStyle == "Classic" {
            SearchView(
                viewModel: searchViewModel,
                showDiscover: discoverLocation == "Search",
                onContentClick: onNavigateToDetails,
                onLongPress: onLongPressCard
            )
        } else {
            NetflixSearchView(
                viewModel: netflixSearchViewModel,
                showDiscover: discoverLocation == "Search",
                onContentClick: onNavigateToDetails,
                onLongPress: onLongPressCard
            )
        }
    }

    private var tabs: some View {
        TabView(selection: $selectedTab) {
            // Keep profile switching as a regular tab on every supported tvOS
            // version. This compiles with the tvOS 26.5 SDK and remains visible
            // when the app is sideloaded onto tvOS 27.
            // The tab label carries the profile name + avatar icon so the menu
            // shows who's signed in instead of a generic "Profile" entry. Its
            // content stays empty: selecting it goes straight to profile
            // switching, while editing now lives in Settings.
            Tab(value: TVTab.profile) {
                Color.clear
            } label: {
                Label {
                    Text(profileTabTitle)
                } icon: {
                    if sessionNeedsReauthentication {
                        Image(systemName: "person.crop.circle.badge.exclamationmark")
                    } else if let avatar = profileTabAvatar.image {
                        Image(uiImage: avatar).renderingMode(.original)
                    } else {
                        Image(systemName: ProfileAvatarCatalog.symbolName(for: displayedProfile?.avatarId))
                    }
                }
            }

            Tab(TVTab.home.title, systemImage: TVTab.home.symbol, value: TVTab.home) {
                TVHomeView(
                    store: homeStore,
                    repository: CinemetaCatalogRepository(),
                    isActive: selectedTab == .home,
                    isFullScreenOverlayPresented: isFullScreenOverlayPresented,
                    detailsDidDisappearGeneration: detailsDidDisappearGeneration,
                    isProfileSwitching: isProfileSwitching,
                    contentIdentity: TVHomeContentIdentity(
                        profileId: activeProfile?.id ?? "none",
                        catalogRevision: homeCatalogRevision
                    ),
                    collectionsRevision: homeCollectionsRevision,
                    sessionNeedsReauthentication: sessionNeedsReauthentication,
                    onNavigateToDetails: onNavigateToDetails,
                    onOpenCollectionFolder: onOpenCollectionFolder,
                    onResumePlayback: onResumePlayback,
                    onPlayContinueWatchingManually: onPlayContinueWatchingManually,
                    onStartContinueWatchingFromBeginning: onStartContinueWatchingFromBeginning,
                    onRemoveFromContinueWatching: onRemoveFromContinueWatching,
                    onLongPressCard: onLongPressCard,
                    onLongPressContinueWatching: onLongPressContinueWatching,
                    onRequestAccountRefresh: onRequestAccountRefresh,
                    onRequestReauth: { showingReauthSheet = true }
                )
                    .id(activeProfile?.id ?? "none")
            }

            // The search role lets the sidebar integrate the system search field
            // instead of floating the tab pill over it.
            Tab(value: TVTab.search, role: .search) {
                searchTab
            }

            Tab(TVTab.library.title, systemImage: TVTab.library.symbol, value: TVTab.library) {
                LibraryView(
                    viewModel: libraryViewModel,
                    store: ProfileSettings.store(for: activeProfile?.id),
                    onContentClick: onNavigateToDetails,
                    onLongPress: onLongPressCard,
                    onOpenCloudLibrary: onOpenCloudLibrary,
                    onPlayCloudFile: onPlayCloudFile
                )
                    .id(activeProfile?.id ?? "none")
            }

            Tab(value: TVTab.settings) {
                SettingsView(
                    activeProfile: displayedProfile,
                    accountEmail: accountEmail,
                    isAuthenticated: isAuthenticated,
                    sessionNeedsReauthentication: sessionNeedsReauthentication,
                    onChangeProfileName: onChangeProfileName,
                    onChangeProfileAvatar: onChangeProfileAvatar,
                    onChangeProfilePin: onChangeProfilePin,
                    onVerifyProfilePin: onVerifyProfilePin,
                    onSignIn: {
                        if sessionNeedsReauthentication {
                            showingReauthSheet = true
                        } else {
                            onSignIn()
                        }
                    },
                    onSignOut: onSignOut
                )
            } label: {
                Label(
                    TVTab.settings.title,
                    systemImage: sessionNeedsReauthentication ? "exclamationmark.circle" : TVTab.settings.symbol
                )
            }
        }
        .background(Color.nuvioBackground(amoled: amoled, body: bodyColor).ignoresSafeArea())
        .sheet(isPresented: $showingReauthSheet) {
            ReauthSheet(auth: authManager) {
                syncManager.beginPostLoginSync()
            }
        }
        .onAppear {
            AvatarCatalogStore.shared.loadIfNeeded()
            profileTabAvatar.refresh(avatarId: displayedProfile?.avatarId)
            if sessionNeedsReauthentication {
                showingReauthSheet = true
            }
        }
        .onChange(of: sessionNeedsReauthentication) { _, needsReauth in
            if needsReauth {
                showingReauthSheet = true
            }
        }
        .onChange(of: displayedProfile?.avatarId) { _, newValue in
            profileTabAvatar.refresh(avatarId: newValue)
        }
        .onChange(of: selectedTab) { _, tab in
            if tab == .profile {
                onSwitchProfile()
            }
        }
        // Re-attempt once the catalog finishes loading, since the first refresh
        // can't resolve the avatar image before then.
        .onReceive(AvatarCatalogStore.shared.$items) { _ in
            profileTabAvatar.refresh(avatarId: displayedProfile?.avatarId)
        }
    }
}
