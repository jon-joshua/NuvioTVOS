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
    @State private var railIsFocused = false
    @State private var railFocusRequest = false
    /// Where the user came from when they opened Search; Menu returns there.
    @State private var tabBeforeSearch: TVTab = .home

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
        ZStack(alignment: .leading) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // One focus section for the whole page: Up/Down stay inside it,
                // only Left enters the rail, and Right from the rail lands on the
                // nearest content item.
                .focusSection()
                // The rail is a pure overlay: content lays out at full width and
                // slides right by the rail's width while it is open. An offset is a
                // transform, not a layout pass, so nothing is re-laid out.
                .offset(x: railIsFocused ? NavigationRailMetrics.openShift : 0)
                .animation(.spring(response: 0.34, dampingFraction: 0.86), value: railIsFocused)
                .environment(\.navigationRailShift, railIsFocused ? NavigationRailMetrics.openShift : 0)
            if selectedTab != .search {
                NavigationRail(
                    selection: $selectedTab,
                    isFocused: $railIsFocused,
                    focusRequest: $railFocusRequest,
                    title: { $0.title }
                ) { tab in
                    railIcon(for: tab)
                }
                    .zIndex(1)
                    .transition(.move(edge: .leading))
            }
        }
        // Menu: from content, open the rail. On the rail it is left unhandled so
        // tvOS exits the app: two presses from anywhere, like YouTube and Netflix.
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: selectedTab == .search)
        .onExitCommand(perform: railIsFocused ? nil : handleMenu)
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
        .onChange(of: selectedTab) { old, tab in
            if tab == .search, old != .search { tabBeforeSearch = old }
            // The rail is removed while searching, so its focus report can't
            // clear itself; do it here or the page stays slid and Menu exits.
            if tab == .search { railIsFocused = false }
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

    private func handleMenu() {
        if selectedTab == .search {
            selectedTab = tabBeforeSearch
            return
        }
        railFocusRequest = true
    }

    /// The rail's icon per destination. Profile shows the signed-in avatar,
    /// or a warning while re-authentication is needed.
    @ViewBuilder
    private func railIcon(for tab: TVTab) -> some View {
        switch tab {
        case .profile:
            if sessionNeedsReauthentication {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
            } else if let avatar = profileTabAvatar.image {
                Image(uiImage: avatar).resizable().scaledToFit().clipShape(Circle())
            } else {
                Image(systemName: ProfileAvatarCatalog.symbolName(for: displayedProfile?.avatarId))
            }
        case .settings:
            Image(systemName: sessionNeedsReauthentication ? "exclamationmark.circle" : TVTab.settings.symbol)
        default:
            Image(systemName: tab.symbol)
        }
    }

    /// The screen for the selected destination.
    @ViewBuilder
    private var content: some View {
        switch selectedTab {
        case .profile:
            // Profile switching is an action, not a screen: selecting it fires
            // `onSwitchProfile` (see the onChange above) over empty content.
            Color.clear
        case .home:
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
        case .search:
            searchTab
        case .library:
        LibraryView(
            viewModel: libraryViewModel,
            store: ProfileSettings.store(for: activeProfile?.id),
            onContentClick: onNavigateToDetails,
            onLongPress: onLongPressCard,
            onOpenCloudLibrary: onOpenCloudLibrary,
            onPlayCloudFile: onPlayCloudFile
        )
            .id(activeProfile?.id ?? "none")
        case .settings:
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
        }
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
}
