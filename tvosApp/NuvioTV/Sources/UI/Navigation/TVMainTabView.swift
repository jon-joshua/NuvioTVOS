import SwiftUI
import UIKit

/// The sidebar-adaptable tab view that hosts Home, Search, Library, Settings
/// and the profile switcher. Owned by `ContentView` in NuvioTVApp.swift.
struct TVMainTabView: View {
    @Binding var selectedTab: TVTab
    let activeProfile: Profile?
    @ObservedObject var searchViewModel: SearchViewModel
    @ObservedObject var libraryViewModel: LibraryViewModel
    @ObservedObject var homeStore: TVHomeStore
    let homeCatalogRevision: UInt
    let homeCollectionsRevision: UInt
    /// True while a pushed screen or the player covers the tab view.
    let isCovered: Bool
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
    var onLongPressCard: ((NuvioMeta) -> Void)? = nil
    /// Long press on a Continue Watching card, which gets its own resume-centric
    /// menu instead of the generic title actions.
    var onLongPressContinueWatching: ((ContinueWatchingItem) -> Void)? = nil
    let onOpenCloudLibrary: () -> Void
    let onPlayCloudFile: (URL, NuvioMeta) -> Void
    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue
    @AppStorage(SettingsKey.discoverLocation) private var discoverLocation = "Search"
    @AppStorage(SettingsKey.profileName) private var settingsProfileName = "Nuvio User"
    @StateObject private var profileTabAvatar = ProfileTabAvatarRenderer()
    @State private var showingReauthSheet = false
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
        sidebarTabs
            .tabViewStyle(.sidebarAdaptable)
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
                // Menu from Search returns to wherever it was opened from.
                if tab == .search, old != .search { tabBeforeSearch = old }
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

    /// The tvOS 18 sidebar: the system tab bar that collapses to icons and
    /// expands with labels on focus. Visited tabs stay mounted, so switching
    /// keeps each page's state.
    private var sidebarTabs: some View {
        TabView(selection: $selectedTab) {
            // Profile switching is an action, not a screen: selecting it fires
            // `onSwitchProfile` (see the onChange above) over empty content. The
            // label carries the profile name + avatar so the sidebar shows who is
            // signed in instead of a generic "Profile" entry.
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
                homePage
            }

            // The search role lets the sidebar integrate the system search field
            // instead of floating the tab pill over it.
            //
            // Menu policy: Home is the app's top level. On Home the system
            // handles Menu (sidebar, then the tvOS home screen); on every other
            // tab Menu goes back one level to Home, or for Search to the tab it
            // was opened from. Pages that own an overlay (Library's cloud item,
            // Settings pickers) handle Menu themselves first and only fall
            // through here when nothing is open.
            Tab(value: TVTab.search, role: .search) {
                searchTab
                    .onExitCommand { selectedTab = tabBeforeSearch }
            }

            Tab(TVTab.library.title, systemImage: TVTab.library.symbol, value: TVTab.library) {
                libraryPage
                    .onExitCommand { selectedTab = .home }
            }

            Tab(value: TVTab.settings) {
                settingsPage
                    .onExitCommand { selectedTab = .home }
            } label: {
                Label(
                    TVTab.settings.title,
                    systemImage: sessionNeedsReauthentication ? "exclamationmark.circle" : TVTab.settings.symbol
                )
            }
        }
    }



    private var homePage: some View {
        TVHomeView(
            store: homeStore,
            repository: CinemetaCatalogRepository(),
            isActive: selectedTab == .home,
            isCovered: isCovered,
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

    private var libraryPage: some View {
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

    private var settingsPage: some View {
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

    /// The system-keyboard search over a full-width poster grid.
    private var searchTab: some View {
        SearchView(
            viewModel: searchViewModel,
            showDiscover: discoverLocation == "Search",
            onContentClick: onNavigateToDetails,
            onLongPress: onLongPressCard
        )
    }
}
