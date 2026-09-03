//
//  NuvioTVApp.swift
//  NuvioTV
//
//  Main SwiftUI app entry point with Master view coordinator
//

import SwiftUI
import Foundation
import UIKit
import ImageIO
import OSLog

@main
struct NuvioTVApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

/// Temporary Home performance tracing. Enabled only by DEBUG builds so the
/// release app does not pay for the timestamps or console formatting.
enum TVHomeDebugTrace {
    private static let enabled = true
    private static let logger = Logger(
        subsystem: "com.pyksel.nuviotvos",
        category: "TVTrace"
    )
    static func now() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    static func elapsedMilliseconds(since start: UInt64) -> String {
        String(format: "%.1f", Double(now() - start) / 1_000_000)
    }

    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let line = "[TVTrace] \(message())"
        logger.notice("\(line, privacy: .public)")
    }
}

enum TVScreen {
    case login
    case profileSelection
    case main
    case details(id: String, type: String)
    case player(url: URL, meta: NuvioMeta, subtitle: String, httpHeaders: [String: String], externalSubtitles: [NuvioSubtitle], resumeFrom: Double?)
    case cloudLibrary
    /// Browse titles inside one collection folder (catalogs grouped under it).
    case collectionFolder(TVCollectionFolderItem, collectionTitle: String)
    /// All titles from a production company or network.
    case productionBrowse(MetaCompany)
    /// Movies and series associated with a TMDB person.
    case personBrowse(TmdbPersonMetadata)
}

public enum PlaybackOrigin {
    case main
    case details
    case cloudLibrary
}

private enum DetailsReturnDestination {
    case main
    case collectionFolder(TVCollectionFolderItem, collectionTitle: String)
}

/// Main content view - entry point for the app with screen routing
struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var activeScreen: TVScreen = .login
    @State private var resolvedInitialScreen = false
    /// `nil` until tvOS has actually backgrounded the app, so the initial
    /// `.active` callback is never treated as a resume.
    @State private var backgroundedAt: Date?
    private static let profileSelectionBackgroundGracePeriod: TimeInterval = 10 * 60
    // Holds the who's-watching screen back until the post-sign-in profile pull
    // lands, so freshly imported profile names show instead of local stubs.
    @State private var awaitingPostLoginSync = false
    @State private var enterMainAfterPostLoginSync = false
    /// Covers the switch to a freshly picked profile until its Home is built.
    ///
    /// Home re-points every profile-scoped store, reloads its catalogs and
    /// rebuilds Continue Watching when the profile changes. Rendering through
    /// that shows rows arriving one by one under a moving focus; the Android
    /// client instead holds a full-screen loader and reveals a finished Home,
    /// which is both calmer and easier to reason about.
    @State private var isPreparingProfile = false
    @State private var profileGateTask: Task<Void, Never>?
    @State private var profileGateStartedAt: Date?
    /// Every switch shows the cover for at least this long, even when the new
    /// profile's rows are already cached and come back instantly. A cover that
    /// appears only sometimes reads as a stutter; a switch that always takes the
    /// same short beat reads as the app doing something deliberate — which is
    /// how the Android client behaves, and why its switches feel settled.
    private static let profileGateMinimumDuration: TimeInterval = 1.8
    /// Ceiling on the profile-switch cover, whatever Home ends up publishing.
    private static let profileGateTimeout: TimeInterval = 5
    @State private var selectedTab: TVTab = .home
    /// Series context for the current playback, captured at play time so the
    /// player can offer/auto-play the next episode. Empty for movies/trailers.
    @State private var playbackEpisodes: [NuvioVideo] = []
    @State private var playbackCurrentEpisode: NuvioVideo?
    @State private var playbackOrigin: PlaybackOrigin = .main
    @State private var playbackDidStart = false
    @State private var reopenStreamPickerOnDetails = false
    @State private var reopenStreamPickerEpisode: NuvioVideo?
    /// Title whose liquid-glass quick-actions menu is showing (long-press on a
    /// card). Presented as an overlay over the tab view, like Details/Player.
    @State private var cardMenuMeta: NuvioMeta?
    /// Where Details opened from the quick-actions menu should return. Collection
    /// cards keep their browser in the navigation chain instead of falling Home.
    @State private var cardMenuReturnDestination: DetailsReturnDestination = .main
    /// Continue Watching entry whose quick-actions menu is showing. Held apart
    /// from `cardMenuMeta` because a resume card offers resume actions (play
    /// manually / restart / remove) rather than the generic title actions.
    @State private var continueWatchingMenuItem: ContinueWatchingItem?
    /// URL-less Continue Watching entries (for example synced progress or Next
    /// Up) resolve their stream in place instead of opening Details first.
    @State private var isResolvingContinueWatchingStream = false
    @State private var resolvingContinueWatchingItem: ContinueWatchingItem?
    @State private var continueWatchingPlaybackTask: Task<Void, Never>?
    @State private var pendingDeepLinkURL: URL?
    /// Details title to restore when leaving a production company browse.
    @State private var productionBrowseReturn: (id: String, type: String)?
    /// Details title to restore when leaving a person browse.
    @State private var personBrowseReturn: (id: String, type: String)?
    /// Titles to walk back through when Details opened Details ("More like
    /// this"). Empty means the current Details is the root of its chain and back
    /// belongs to its recorded return destination.
    @State private var detailsBackStack: [(id: String, type: String)] = []
    /// Where the root Details screen should return. This is normally Home, but
    /// a title opened from a collection must return to that collection.
    @State private var detailsReturnDestination: DetailsReturnDestination = .main
    /// Bumped only after the Details view has actually left the hierarchy.
    /// Home uses this lifecycle signal to request focus at the first moment
    /// tvOS can accept it, instead of guessing with delayed timers.
    @State private var detailsDidDisappearGeneration: UInt = 0
    @StateObject private var authManager = AuthManager()
    @StateObject private var profileViewModel = ProfileViewModel()
    @StateObject private var syncManager = NuvioSyncManager()
    @StateObject private var searchViewModel = SearchViewModel()
    @StateObject private var libraryViewModel = LibraryViewModel()
    // Owned here (not inside TVHomeView) so the Home catalog + focused card
    // survive the details/player push, which tears TVHomeView down. Returning
    // then restores the exact card instead of reloading and jumping to the top.
    @StateObject private var homeStore = TVHomeStore()

    var body: some View {
        ZStack {
            ProfileScopedRootBackground()

            switch activeScreen {
            case .login:
                // `.login` is also the value this state starts at, before
                // `onAppear` has read the restored session — so it must not put
                // the login screen on screen yet. `LoginView` auto-continues the
                // moment it appears for an already-authenticated user, and that
                // continuation is the *post-login* path: it re-ran the account
                // bootstrap and raised the "Syncing your account" gate on every
                // single relaunch, not just on a real sign-in.
                if resolvedInitialScreen {
                    LoginView(auth: authManager) {
                        // Successful authentication owns the initial account pull.
                        // Profile selection remains a later, deliberate switch and
                        // is no longer needed to kick-start a missed bootstrap.
                        if authManager.isAuthenticated {
                            syncManager.beginPostLoginSync()
                        }
                        withAnimation(.easeInOut(duration: 0.28)) {
                            awaitingPostLoginSync = syncManager.isPullingAccountProfiles
                            activeScreen = .profileSelection
                        }
                    }
                    .transition(.opacity)
                } else {
                    // One frame at most: `onAppear` resolves the real screen
                    // immediately, and the root background is already drawn
                    // behind this.
                    Color.clear
                }

            case .profileSelection:
                if awaitingPostLoginSync && syncManager.isPullingAccountProfiles {
                    AccountSyncWaitView()
                        .transition(.opacity)
                } else {
                    UserProfileView(
                        viewModel: profileViewModel,
                        accountSyncError: syncManager.profileSyncError,
                        onRetryAccountSync: {
                            syncManager.retryInitialAccountPull()
                            awaitingPostLoginSync = syncManager.isPullingAccountProfiles
                        },
                        onProfileCreated: {
                            syncManager.syncProfilesAfterLocalEdit()
                        }
                    )
                        .transition(.opacity)
                        .onAppear {
                            // A failed owned bootstrap is recovered only through
                            // Retry, which re-arms the blocking gate. Do not start
                            // an ungated background pull behind the Guest card.
                            if syncManager.profileSyncError == nil {
                                syncManager.refreshProfilesForSelectionIfNeeded()
                            }
                        }
                        // Navigate only on an explicit pick. Listening to
                        // $activeProfile here would auto-enter a profile the
                        // moment the sync refreshes it mid-selection.
                        .onReceive(profileViewModel.profileChosen) { _ in
                            selectedTab = .home
                            beginProfileGate()
                            withAnimation(.easeInOut(duration: 0.28)) {
                                activeScreen = .main
                            }
                            resumePendingDeepLinkIfPossible()
                        }
                }

            case .main, .details, .player, .cloudLibrary, .collectionFolder, .productionBrowse, .personBrowse:
                // The tab view (Home included) stays mounted for the whole
                // session; Details and Player are presented as overlays on TOP
                // of it rather than replacing it. Returning therefore leaves
                // Home exactly as the user left it -- same scroll, same focused
                // card (tvOS focus memory) -- instead of rebuilding it from
                // scratch and snapping back to the first card.
                appContainer
                    .transition(.opacity)
            }
        }
        // Resolve every @AppStorage in the app against the active profile's
        // settings suite, so each profile keeps its own theme, layout, playback
        // preferences, etc. Falls back to the shared store before a profile is picked.
        .defaultAppStorage(ProfileSettings.store(for: profileViewModel.activeProfile?.id))
        // Apply selected app language (locale + L10n catalog) and refresh UI on change.
        .appliesAppLocale()
        .onChange(of: profileViewModel.activeProfile?.id) { _, _ in
            AppLocaleManager.shared.reloadFromProfileStore()
        }
        // Keep the profile cover up until the progressive catalog stream has
        // finished. Revealing Home when its first row arrived let the user page
        // that row while later catalog updates were still replacing it; if a
        // focused, paged-in card disappeared during the replacement, tvOS moved
        // focus to the row above. `hasLoaded` flips only after the final tree is
        // published, so the first interactive frame is stable.
        .onChange(of: homeStore.hasLoaded) { _, loaded in
            guard isPreparingProfile, loaded else { return }
            profileGateContentReady()
        }
        // Backing out of the switch must not leave the cover behind.
        .onChange(of: isOnProfileSelection) { _, isSelecting in
            if isSelecting, isPreparingProfile {
                liftProfileGate()
            }
        }
        .background(Color.black.ignoresSafeArea())
        // Safety net for the Menu button while an overlay is up. During the
        // overlay's insert animation focus is briefly in limbo (the tab view is
        // disabled, the overlay hasn't taken focus yet); a Menu press then finds
        // no `.onExitCommand` handler and tvOS quits the app. This root handler
        // catches those stray presses and dismisses the overlay instead. When
        // focus is settled inside Details/Player their own handler fires first,
        // so this only kicks in for the in-between frames. No handler is attached
        // on Home, so Menu there keeps its normal tab-level behaviour.
        .onExitCommand(perform: isOverlayPresented ? dismissOverlay : nil)
        .onOpenURL(perform: handleDeepLink)
        .onAppear {
            syncManager.attach(authManager: authManager, profileViewModel: profileViewModel)
            ICloudSettingsSyncManager.shared.start()
            setupPictureInPicture()
            guard !resolvedInitialScreen else { return }
            resolvedInitialScreen = true
            // Skip the login gate if a session was restored or the user has
            // previously chosen to continue without an account.
            if !authManager.shouldShowLoginGate {
                // Auto-select-last-profile (Settings → Profile) skips the
                // who's-watching stop on launch; navigation is otherwise
                // driven only by an explicit pick via `profileChosen`.
                let autoSelectLast = ProfileSettings.current.object(
                    forKey: SettingsKey.profileAutoSelectLast
                ) as? Bool ?? true
                // Signed in with the startup pull still running, so real
                // profiles are expected to land shortly and the local
                // placeholder must not be mistaken for the account.
                let awaitingRealProfiles = authManager.isAuthenticated
                    && AuthConfig.isConfigured
                    && syncManager.isPullingAccountProfiles
                if awaitingRealProfiles, hasOnlyLocalGuestPlaceholder {
                    // Nothing real to show or enter yet — a restored Keychain
                    // session can outlive missing/corrupt local profile data.
                    // Gate that startup pull exactly like a fresh login instead
                    // of auto-entering the local Guest.
                    awaitingPostLoginSync = true
                    enterMainAfterPostLoginSync = autoSelectLast
                    activeScreen = .profileSelection
                } else if autoSelectLast,
                          let activeProfile = profileViewModel.activeProfile,
                          !activeProfile.isPinProtected,
                          !(awaitingRealProfiles && isGuestPlaceholder(activeProfile)) {
                    beginProfileGate()
                    activeScreen = .main
                    resumePendingDeepLinkIfPossible()
                } else {
                    // Profiles are already on disk, so the picker can be shown
                    // right away and refreshes itself when the pull lands. This
                    // is the ordinary cold launch: waiting behind the sync
                    // screen every time taught nothing the picker didn't
                    // already know.
                    activeScreen = .profileSelection
                }
            }
        }
        .onReceive(authManager.$authState) { state in
            syncManager.authStateChanged(state)
            if state == .signedOut, profileViewModel.activeProfile?.id != "guest" {
                profileViewModel.resetForSignedOut()
            }
        }
        .onReceive(syncManager.$isPullingAccountProfiles) { pulling in
            if !pulling, awaitingPostLoginSync {
                let shouldEnterMain = enterMainAfterPostLoginSync
                    && authManager.isAuthenticated
                    && syncManager.profileSyncError == nil
                    && profileViewModel.activeProfile?.id != "guest"
                    && profileViewModel.activeProfile?.isPinProtected != true
                withAnimation(.easeInOut(duration: 0.28)) {
                    awaitingPostLoginSync = false
                    enterMainAfterPostLoginSync = false
                    if shouldEnterMain {
                        beginProfileGate()
                        activeScreen = .main
                        resumePendingDeepLinkIfPossible()
                    }
                }
            }
        }
        .onReceive(profileViewModel.$activeProfile) { profile in
            syncManager.activeProfileChanged(profile)
            guard profile != nil else { return }
            SMBServerStore.shared.reload()
            JellyfinServerStore.shared.reload()
            Task(priority: .utility) {
                await SMBSessionManager.shared.connectAll()
                await JellyfinSessionManager.shared.connectAll()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                backgroundedAt = Date()
            case .active:
                syncManager.refreshAccountIfIdle()
                presentProfileSelectionAfterBackgroundIfNeeded()
            default:
                break
            }
        }
    }

    /// Mirrors the cold-start profile decision when returning to the foreground.
    /// Normally, the who's-watching screen appears after a ten-minute background
    /// grace period. When remembering the last profile is disabled, the profile
    /// setting can instead require a choice on every return.
    private func presentProfileSelectionAfterBackgroundIfNeeded() {
        guard let backgroundedAt else { return }
        self.backgroundedAt = nil
        guard resolvedInitialScreen, !isOnProfileSelection else { return }
        if case .login = activeScreen { return }

        let autoSelectLast = ProfileSettings.current.object(
            forKey: SettingsKey.profileAutoSelectLast
        ) as? Bool ?? true
        let requireSelectionOnEveryReturn = ProfileSettings.current.object(
            forKey: SettingsKey.profileRequireSelectionAfterBackground
        ) as? Bool ?? false
        let hasExceededGracePeriod = Date().timeIntervalSince(backgroundedAt)
            >= Self.profileSelectionBackgroundGracePeriod
        let shouldRequireSelection = hasExceededGracePeriod
            || (!autoSelectLast && requireSelectionOnEveryReturn)
        guard shouldRequireSelection else { return }
        guard !(autoSelectLast && profileViewModel.activeProfile?.isPinProtected == false) else {
            return
        }

        continueWatchingPlaybackTask?.cancel()
        continueWatchingPlaybackTask = nil
        isResolvingContinueWatchingStream = false
        cardMenuMeta = nil
        continueWatchingMenuItem = nil
        withAnimation(.easeInOut(duration: 0.28)) {
            activeScreen = .profileSelection
        }
    }

    /// Whether Details, Player, or the card quick-actions menu is currently
    /// covering the tab view (drives `.disabled` and the Menu-button safety net).
    /// True when the profile list on disk holds nothing but the fresh-install
    /// placeholder, so there is no real profile to show or enter.
    ///
    /// This deliberately asks about the *list*, not about `activeProfile`. Having
    /// no active profile is the ordinary state on a cold launch — nothing has
    /// been picked yet — and blocking the who's-watching screen behind the
    /// account-sync gate for it made every relaunch wait on a pull whose result
    /// the picker was already showing from disk.
    private var hasOnlyLocalGuestPlaceholder: Bool {
        profileViewModel.profiles.allSatisfy(isGuestPlaceholder)
    }

    /// The placeholder profile a fresh install seeds, which account sync
    /// replaces with the real primary profile.
    private func isGuestPlaceholder(_ profile: Profile) -> Bool {
        if profile.id == "guest" { return true }
        let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return profile.id == "1" && !profile.isAdmin && profile.avatarId.isEmpty
            && name == "nuvio guest"
    }

    private var isOverlayPresented: Bool {
        if isResolvingContinueWatchingStream { return true }
        return fullScreenOverlayPresented
    }

    /// Full-screen overlays already hide Home with alpha zero. Propagating
    /// `.disabled` through that hidden tree changes `isEnabled` for every
    /// resident card and forces the shelves to lay themselves out again while
    /// Details is entering. Keep the environment lock for visible menus, where
    /// Home still needs to stay on screen but must not receive focus.
    private var shouldDisableHomeContent: Bool {
        isOverlayPresented && !fullScreenOverlayPresented
    }

    /// Details/Player fully replace Home, so the tab view fades to black under
    /// them. The card quick-actions menu is deliberately excluded — it keeps Home
    /// visible behind its glass panel.
    private var fullScreenOverlayPresented: Bool {
        if isResolvingContinueWatchingStream { return true }
        switch activeScreen {
        case .details, .player, .cloudLibrary, .collectionFolder, .productionBrowse, .personBrowse: return true
        default: return false
        }
    }

    /// Keep a collection browser mounted beneath the Details chain it opened.
    /// Its loaded rows, horizontal positions, focus memory, and watched badges
    /// then survive the round trip instead of being rebuilt on every Back press.
    private var presentedCollectionFolder: (
        folder: TVCollectionFolderItem,
        collectionTitle: String
    )? {
        if case let .collectionFolder(folder, collectionTitle) = activeScreen {
            return (folder, collectionTitle)
        }

        switch activeScreen {
        case .details, .player, .productionBrowse, .personBrowse:
            if case let .collectionFolder(folder, collectionTitle) = detailsReturnDestination {
                return (folder, collectionTitle)
            }
        default:
            break
        }
        return nil
    }

    private var isCollectionFolderActive: Bool {
        if case .collectionFolder = activeScreen { return true }
        return false
    }

    /// Dismisses the current overlay to the same destination its own back action
    /// would (Player returns to Details for series/trailers, otherwise Home).
    /// Used only by the root Menu-button safety net; changing `activeScreen`
    /// tears the overlay down, so Player's `onDisappear` cleanup still runs.
    private func dismissOverlay() {
        if isResolvingContinueWatchingStream {
            continueWatchingPlaybackTask?.cancel()
            continueWatchingPlaybackTask = nil
            resolvingContinueWatchingItem = nil
            isResolvingContinueWatchingStream = false
            return
        }
        switch activeScreen {
        case .details:
            leaveDetails()
        case let .player(_, meta, subtitle, _, _, _):
            dismissPlayer(meta: meta, subtitle: subtitle)
        case .cloudLibrary, .collectionFolder:
            withAnimation(.easeInOut(duration: 0.24)) {
                activeScreen = .main
            }
        case .productionBrowse:
            withAnimation(.easeInOut(duration: 0.24)) {
                if let ret = productionBrowseReturn {
                    activeScreen = .details(id: ret.id, type: ret.type)
                } else {
                    activeScreen = .main
                }
                productionBrowseReturn = nil
            }
        case .personBrowse:
            withAnimation(.easeInOut(duration: 0.24)) {
                if let ret = personBrowseReturn {
                    activeScreen = .details(id: ret.id, type: ret.type)
                } else {
                    activeScreen = .main
                }
                personBrowseReturn = nil
            }
        default:
            break
        }
    }

    /// Backs out of Details to the title it was opened from (a "More like this"
    /// chain), or to the screen that opened the root Details.
    private func leaveDetails() {
        TVHomeDebugTrace.log(
            "details.leave backStackRemaining=\(detailsBackStack.count) returnDest=\(detailsReturnDestination)"
        )
        withAnimation(.easeInOut(duration: 0.24)) {
            if let previous = detailsBackStack.popLast() {
                activeScreen = .details(id: previous.id, type: previous.type)
            } else {
                switch detailsReturnDestination {
                case .main:
                    activeScreen = .main
                case let .collectionFolder(folder, collectionTitle):
                    activeScreen = .collectionFolder(folder, collectionTitle: collectionTitle)
                }
                detailsReturnDestination = .main
            }
        }
    }

    /// Opens Details as a fresh navigation (Home, search, a card menu, a deep
    /// link). Any "More like this" chain belongs to the flow being left, so the
    /// back stack starts empty and back from here returns to Home.
    private func openDetailsRoot(
        id: String,
        type: String,
        returnDestination: DetailsReturnDestination = .main
    ) {
        TVHomeDebugTrace.log(
            "details.open.root id=\(id) type=\(type) returnDest=\(returnDestination)"
        )
        detailsBackStack.removeAll()
        detailsReturnDestination = returnDestination
        activeScreen = .details(id: id, type: type)
    }

    /// Handles Top Shelf, `nuvio://` / `nuvio-tv://` title open, and
    /// `stremio://` add-on install deep links. Deferred while login/profile gate
    /// is up so Top Shelf cold-launch still works.
    private func handleDeepLink(_ url: URL) {
        let scheme = (url.scheme ?? "").lowercased()

        // stremio://host/path/manifest.json → install add-on
        if scheme == "stremio" {
            handleStremioInstallDeepLink(url)
            return
        }

        // nuvio://meta?type=&id=  |  nuvio-tv://details?…  |  nuvio-tv://continue-watching?…
        // Also accepts com.nuvio.app.tv and path-style /meta/… /details/…
        guard ["nuvio", "nuvio-tv", "com.nuvio.app.tv"].contains(scheme) else { return }

        // Infuse returns here after its player closes. Keep this before the
        // generic id guard: callback URLs intentionally carry only a session
        // UUID, not a title id.
        if let callback = ExternalPlaybackCallback.parse(url) {
            switch activeScreen {
            case .login, .profileSelection:
                pendingDeepLinkURL = url
            default:
                handleExternalPlaybackCallback(callback)
            }
            return
        }

        switch activeScreen {
        case .login, .profileSelection:
            pendingDeepLinkURL = url
            return
        default:
            break
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let host = (url.host ?? "").lowercased()
        let pathParts = url.path.split(separator: "/").map(String.init)

        // Install: nuvio://addon?url=… or nuvio://install?manifest=…
        if host == "addon" || host == "install" || pathParts.first == "addon" {
            let manifest = components?.queryItems?.first(where: {
                $0.name == "url" || $0.name == "manifest"
            })?.value
            if let manifest, CommunityAddonCatalog.install(manifestURL: manifest) {
                withAnimation(.easeInOut(duration: 0.28)) {
                    selectedTab = .settings
                }
            }
            return
        }

        let id = components?.queryItems?.first(where: { $0.name == "id" })?.value
            ?? pathParts.dropFirst().first
        guard let id, !id.isEmpty else { return }
        let type = components?.queryItems?.first(where: { $0.name == "type" })?.value
            ?? (pathParts.count >= 3 ? pathParts[1] : nil)
            ?? "movie"

        if host == "continue-watching" || pathParts.first == "continue-watching",
           let item = ContinueWatchingStore.item(for: id) {
            resumePlayback(item)
            return
        }

        withAnimation(.easeInOut(duration: 0.28)) {
            openDetailsRoot(id: id, type: type)
        }
    }

    private func handleExternalPlaybackCallback(_ callback: ExternalPlaybackCallback) {
        let profileID = profileViewModel.activeProfile?.id ?? WatchedStore.activeProfileId
        guard let session = ExternalPlaybackSessionStore.consume(id: callback.id, profileID: profileID) else {
            return
        }
        // An Infuse error callback means the handoff failed. Consuming the
        // session still makes retries/idempotent duplicate callbacks harmless.
        guard !callback.isError else { return }

        let duration = session.duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let progress = callback.progress ?? callback.position.flatMap { position in
            guard let duration, position.isFinite, position >= 0 else { return nil }
            return position / duration
        }
        guard let progress, progress.isFinite, (0...1).contains(progress) else { return }

        let isEpisode = session.meta.isSeries && session.season != nil && session.episode != nil
        guard !session.meta.isSeries || isEpisode else { return }

        if RemoteTrackingState.isProgressSourceAuthenticated {
            // Keep the provider-backed path aligned with built-in playback:
            // optimistic local state plus one pause/stop report. A zero
            // fraction is an Infuse close-before-play signal, not playback.
            if progress > 0 {
                let reportDuration = duration ?? 100
                let reportPosition = duration.map { $0 * progress } ?? (100 * progress)
                let action: TraktScrobbleAction = progress >= WatchProgressLedger.completionFraction
                    ? .stop
                    : .pause
                let store = ProfileSettings.current
                if let duration {
                    TraktProgressService.recordLocalPlayback(
                        meta: session.meta,
                        position: reportPosition,
                        duration: duration,
                        season: session.season,
                        episode: session.episode,
                        notify: action == .stop
                    )
                }
                Task {
                    _ = await TraktProgressService.reportPlayback(
                        meta: session.meta,
                        position: reportPosition,
                        duration: reportDuration,
                        season: session.season,
                        episode: session.episode,
                        action: action,
                        store: store
                    )
                }
            }
            if progress >= WatchProgressLedger.completionFraction {
                _ = WatchedStore.markWatched(
                    session.meta,
                    season: session.season,
                    episode: session.episode
                )
            }
            return
        }

        if progress >= WatchProgressLedger.completionFraction {
            if let duration {
                ContinueWatchingStore.markPlaybackCompleted(
                    meta: session.meta,
                    duration: duration,
                    season: session.season,
                    episode: session.episode
                )
            }
            _ = WatchedStore.markWatched(
                session.meta,
                season: session.season,
                episode: session.episode
            )
        } else if let duration, progress > 0 {
            ContinueWatchingStore.save(
                meta: session.meta,
                streamUrl: session.sourceURL,
                position: duration * progress,
                duration: duration,
                season: session.season,
                episode: session.episode
            )
        }
    }

    /// `stremio://…/manifest.json` installs the add-on (same as pasting the URL).
    private func handleStremioInstallDeepLink(_ url: URL) {
        switch activeScreen {
        case .login, .profileSelection:
            pendingDeepLinkURL = url
            return
        default:
            break
        }
        let raw = url.absoluteString
        let ok = CommunityAddonCatalog.install(manifestURL: raw)
        if ok {
            withAnimation(.easeInOut(duration: 0.28)) {
                selectedTab = .settings
            }
        }
    }

    /// A Top Shelf action can launch the app before authentication/profile
    /// routing has finished. Preserve it through that gate, then consume it on
    /// the next main-actor turn after the active profile has been installed.
    private func resumePendingDeepLinkIfPossible() {
        guard pendingDeepLinkURL != nil else { return }
        Task { @MainActor in
            await Task.yield()
            guard let url = pendingDeepLinkURL else { return }
            pendingDeepLinkURL = nil
            handleDeepLink(url)
        }
    }

    private var isOnProfileSelection: Bool {
        if case .profileSelection = activeScreen { return true }
        return false
    }

    /// Covers Home while the picked profile's stores are re-pointed and its rows
    /// rebuilt, so the user waits once instead of watching Home assemble itself.
    ///
    /// The deadline is the important part: the gate lifts on Home's first
    /// sections, but a profile with no catalogs never publishes any, and a cover
    /// that outlives its own condition is worse than no cover at all.
    private func beginProfileGate() {
        profileGateTask?.cancel()
        isPreparingProfile = true
        profileGateStartedAt = Date()
        profileGateTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.profileGateTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            liftProfileGate()
        }
    }

    /// Home has rows for the new profile. Hold the cover for the remainder of the
    /// minimum anyway: a cached profile publishes within a frame, and lifting
    /// then would flash the cover rather than show it.
    private func profileGateContentReady() {
        guard isPreparingProfile else { return }
        let elapsed = Date().timeIntervalSince(profileGateStartedAt ?? Date())
        let remaining = max(0, Self.profileGateMinimumDuration - elapsed)
        profileGateTask?.cancel()
        profileGateTask = Task { @MainActor in
            if remaining > 0 {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            liftProfileGate()
        }
    }

    /// Unconditional: used by the deadline and by backing out, where the minimum
    /// no longer means anything.
    private func liftProfileGate() {
        profileGateTask?.cancel()
        profileGateTask = nil
        profileGateStartedAt = nil
        guard isPreparingProfile else { return }
        withAnimation(.easeInOut(duration: 0.22)) {
            isPreparingProfile = false
        }
    }

    /// Routes a chosen stream either to an installed external player (per the
    /// External Player setting) or the built-in mpv player. Trailers always use
    /// the built-in player since they are YouTube-resolved. If the external app
    /// isn't installed / declines to open, playback falls back to the built-in
    /// player so the user is never left on a dead end.
    /// Ordered episodes + the currently-resuming one for a Continue Watching /
    /// Next Up item, so Home-launched playback can also auto-advance.
    private static func episodeContext(for item: ContinueWatchingItem) -> (episodes: [NuvioVideo], current: NuvioVideo?) {
        guard item.meta.isSeries, let videos = item.meta.videos, !videos.isEmpty else { return ([], nil) }
        let sorted = videos.sorted {
            (seasonSortKey($0.season), $0.episode) < (seasonSortKey($1.season), $1.episode)
        }
        let numbers = item.episodeNumbers
        let current = sorted.first { $0.season == numbers?.season && $0.episode == numbers?.episode }
        return (sorted, current)
    }

    private static func resumePosition(for item: ContinueWatchingItem) -> Double? {
        let currentItem: ContinueWatchingItem
        if RemoteTrackingState.isProgressSourceAuthenticated,
           let latest = TraktProgressService.currentContinueWatchingItem(for: item.meta) {
            currentItem = latest
        } else {
            currentItem = item
        }

        if currentItem.meta.isSeries {
            // A Trakt card already carries the exact remote episode position.
            // Looking it up in Nuvio Sync's separate episode ledger can return
            // an older checkpoint for the same episode (or no checkpoint at
            // all), so never cross the two progress sources here.
            if RemoteTrackingState.isProgressSourceAuthenticated {
                return currentItem.isUpNextEntry ? nil : currentItem.resumePosition
            }
            guard let numbers = currentItem.episodeNumbers else { return nil }
            let episodeId = currentItem.meta.videos?.first {
                $0.season == numbers.season && $0.episode == numbers.episode
            }?.id
            return ContinueWatchingStore.resumePosition(
                for: currentItem.meta,
                season: numbers.season,
                episode: numbers.episode,
                episodeId: episodeId
            )
        }
        guard !WatchedStore.contains(meta: currentItem.meta) else { return nil }
        return currentItem.resumePosition
    }

    private static func resumePosition(for meta: NuvioMeta, episode: NuvioVideo?) -> Double? {
        if RemoteTrackingState.isProgressSourceAuthenticated {
            guard let item = TraktProgressService.currentContinueWatchingItem(for: meta),
                  !item.isUpNextEntry else { return nil }
            if meta.isSeries {
                guard let episode,
                      item.season == episode.season,
                      item.episode == episode.episode else { return nil }
            }
            return item.resumePosition
        }

        if meta.isSeries {
            guard let episode else { return nil }
            return ContinueWatchingStore.resumePosition(
                for: meta,
                season: episode.season,
                episode: episode.episode,
                episodeId: episode.id
            )
        }
        guard !WatchedStore.contains(meta: meta) else { return nil }
        return ContinueWatchingStore.item(for: meta.id)?.resumePosition
    }

    private static func seasonSortKey(_ season: Int) -> Int {
        season <= 0 ? Int.max : season
    }

    /// Starts a Continue Watching card immediately. Locally played entries use
    /// their last stream URL; synced and Next Up entries fetch and smart-select
    /// a stream in the background without opening Details first.
    ///
    /// `startFromBeginning` plays the same episode with no resume point, for the
    /// card menu's "Start from beginning".
    private func resumePlayback(_ item: ContinueWatchingItem, startFromBeginning: Bool = false) {
        continueWatchingPlaybackTask?.cancel()
        continueWatchingPlaybackTask = nil
        isResolvingContinueWatchingStream = false

        let item = RemoteTrackingState.isProgressSourceAuthenticated
            ? (TraktProgressService.currentContinueWatchingItem(for: item.meta) ?? item)
            : item
        let context = Self.episodeContext(for: item)
        playbackEpisodes = context.episodes
        playbackCurrentEpisode = context.current

        let profileId = profileViewModel.activeProfile?.id
        let storedStream = item.isUpNextEntry
            ? nil
            : LastPlaybackStreamStore.load(
                metaId: item.meta.id,
                season: item.season,
                episode: item.episode,
                profileId: profileId
            )
        let itemStreamURL = item.streamUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let streamURL = [itemStreamURL, storedStream?.url]
            .compactMap { $0 }
            .first { !$0.isEmpty } ?? ""
        let httpHeaders = streamURL == storedStream?.url ? (storedStream?.httpHeaders ?? [:]) : [:]
        if !streamURL.isEmpty, let url = URL(string: streamURL) {
            presentPlayback(
                url: url,
                meta: item.meta,
                subtitle: item.episodeSubtitle ?? "",
                externalSubtitles: [],
                resumeFrom: startFromBeginning ? nil : Self.resumePosition(for: item),
                httpHeaders: httpHeaders
            )
            return
        }

        resolvingContinueWatchingItem = item
        isResolvingContinueWatchingStream = true
        continueWatchingPlaybackTask = Task {
            let prepared: PreparedNextStream?
            if let episode = context.current {
                prepared = await Self.resolveNextEpisodeStream(episode: episode, profileId: profileId)
            } else if item.meta.isSeries, let numbers = item.episodeNumbers {
                prepared = await Self.resolveStream(
                    contentId: "\(item.meta.id):\(numbers.season):\(numbers.episode)",
                    type: "series",
                    subtitleLine: item.episodeSubtitle ?? "",
                    profileId: profileId
                )
            } else {
                prepared = await Self.resolveStream(
                    contentId: item.meta.id,
                    type: item.meta.type,
                    subtitleLine: item.episodeSubtitle ?? "",
                    profileId: profileId
                )
            }

            guard !Task.isCancelled else { return }
            isResolvingContinueWatchingStream = false
            resolvingContinueWatchingItem = nil
            continueWatchingPlaybackTask = nil

            if let prepared {
                presentPlayback(
                    url: prepared.url,
                    meta: item.meta,
                    subtitle: prepared.subtitleLine,
                    externalSubtitles: prepared.subtitles,
                    resumeFrom: startFromBeginning ? nil : Self.resumePosition(for: item),
                    httpHeaders: prepared.httpHeaders
                )
            } else {
                // Keep the manual picker available when no add-on returns a
                // playable stream automatically.
                withAnimation(.easeInOut(duration: 0.28)) {
                    openDetailsRoot(id: item.meta.id, type: item.meta.type)
                }
            }
        }
    }

    /// Opens Details with the stream picker already raised for the episode the
    /// card would resume, so the user chooses the source by hand instead of
    /// taking the smart-selected one that pressing the card plays. The resume
    /// point still applies — Details' play path looks it up per episode.
    private func playContinueWatchingManually(_ item: ContinueWatchingItem) {
        let episode = Self.manualPlaybackEpisode(for: item)
        withAnimation(.easeInOut(duration: 0.28)) {
            continueWatchingMenuItem = nil
            reopenStreamPickerOnDetails = true
            reopenStreamPickerEpisode = episode
            openDetailsRoot(id: item.meta.id, type: item.meta.type)
        }
    }

    /// Episode entry the stream picker should open on, or nil for a movie.
    /// Provider-backed rows often arrive without an episode guide, so fall back
    /// to the same `id:season:episode` video id the resume path already uses.
    private static func manualPlaybackEpisode(for item: ContinueWatchingItem) -> NuvioVideo? {
        guard item.meta.isSeries, let numbers = item.episodeNumbers else { return nil }
        if let current = episodeContext(for: item).current { return current }
        return NuvioVideo(
            id: "\(item.meta.id):\(numbers.season):\(numbers.episode)",
            title: item.episodeDisplayTitle ?? "Episode \(numbers.episode)",
            season: numbers.season,
            episode: numbers.episode,
            thumbnail: item.episodeArtworkURL,
            overview: item.episodeOverview,
            released: item.released,
            rating: nil
        )
    }

    /// Drops a card from Continue Watching for good.
    ///
    /// Local progress is deleted outright and retired on the account, since a
    /// pull would otherwise restore what the user just removed. Trakt/Simkl rows
    /// are owned by the provider and are rebuilt on every refresh, so the
    /// removal is also recorded on this device — that record is what makes the
    /// card stay gone until the title is watched again.
    private func removeFromContinueWatching(_ item: ContinueWatchingItem) {
        var keysToDelete = Set<String>()
        keysToDelete.insert(item.meta.id)
        let itemProgressKey = WatchProgressLedger.progressKey(
            contentId: item.meta.id,
            season: item.episodeNumbers?.season,
            episode: item.episodeNumbers?.episode
        )
        keysToDelete.insert(itemProgressKey)

        let ledgerKeys = WatchProgressLedger.records()
            .filter { $0.contentId == item.meta.id }
            .map(\.progressKey)
        for key in ledgerKeys {
            keysToDelete.insert(key)
        }

        ContinueWatchingDismissStore.dismiss(item)
        ContinueWatchingDismissStore.dismiss(contentId: item.meta.id)

        _ = WatchProgressLedger.removeContent(id: item.meta.id)
        ContinueWatchingStore.remove(metaId: item.meta.id)
        TraktProgressService.forgetLocalPlayback(meta: item.meta)
        // Simkl owns its paused rows, so the local dismiss only hides the card
        // on this device. Retire the row on the account as well; it no-ops
        // unless Simkl is the selected progress source.
        Task { await SimklProgressService.removePlayback(for: item) }

        let keysArray = Array(keysToDelete)
        if !keysArray.isEmpty {
            Task { await syncManager.deleteRemoteWatchProgress(keys: keysArray) }
        }
    }

    private func presentPlayback(
        url: URL,
        meta: NuvioMeta,
        subtitle: String,
        externalSubtitles: [NuvioSubtitle],
        resumeFrom: Double?,
        httpHeaders: [String: String] = [:],
        origin: PlaybackOrigin = .main,
        customPlayer: ExternalPlayer? = nil
    ) {
        let isTrailer = subtitle == PlaybackMarkers.trailerSubtitle
        let store = ProfileSettings.store(for: profileViewModel.activeProfile?.id)
        let defaultPlayer = ExternalPlayer.from(store.string(forKey: SettingsKey.externalPlayer))
        let player = customPlayer ?? defaultPlayer
        let forwardSubtitles = (store.object(forKey: SettingsKey.externalPlayerForwardSubtitles) as? Bool) ?? true
        let subtitleURLs = forwardSubtitles
            ? externalSubtitles.compactMap { URL(string: $0.url) }
            : []

        let externalSession: ExternalPlaybackSession?
        let successCallback: URL?
        let errorCallback: URL?
        if player == .infuse {
            let id = UUID().uuidString
            let numbers: (season: Int, episode: Int)?
            if let current = playbackCurrentEpisode, current.season > 0, current.episode > 0 {
                numbers = (current.season, current.episode)
            } else if let parsed = Self.episodeNumbers(fromSubtitle: subtitle) {
                numbers = parsed
            } else {
                let parsed = Self.seasonEpisode(fromContentId: url.deletingPathExtension().lastPathComponent)
                numbers = parsed.season.flatMap { season in
                    parsed.episode.map { (season: season, episode: $0) }
                }
            }
            let profileID = profileViewModel.activeProfile?.id ?? WatchedStore.activeProfileId
            externalSession = ExternalPlaybackSession(
                id: id,
                meta: meta.persistenceSnapshot,
                sourceURL: url.absoluteString,
                season: meta.isSeries ? numbers?.season : nil,
                episode: meta.isSeries ? numbers?.episode : nil,
                duration: Self.runtimeSeconds(meta.runtime),
                profileID: profileID
            )
            successCallback = URL(string: "nuvio-tv://external-playback/\(id)")
            errorCallback = URL(string: "nuvio-tv://external-playback/error/\(id)")
        } else {
            externalSession = nil
            successCallback = nil
            errorCallback = nil
        }

        // Hand off to the external app only when it is actually installed
        // (`canOpenURL` needs its scheme in LSApplicationQueriesSchemes); if it
        // isn't, fall through to the built-in player instead of a dead launch.
        if !isTrailer,
           url.scheme?.lowercased() != "smb",
           let launchURL = player.launchURL(
               for: url,
               subtitleURLs: subtitleURLs,
               successURL: successCallback,
               errorURL: errorCallback
           ),
           UIApplication.shared.canOpenURL(launchURL) {
            if let externalSession {
                ExternalPlaybackSessionStore.save(externalSession)
            }
            UIApplication.shared.open(launchURL, options: [:], completionHandler: nil)
            return
        }

        presentBuiltInPlayer(
            url: url,
            meta: meta,
            subtitle: subtitle,
            httpHeaders: httpHeaders,
            externalSubtitles: externalSubtitles,
            resumeFrom: resumeFrom,
            origin: origin
        )
    }

    private func presentBuiltInPlayer(
        url: URL,
        meta: NuvioMeta,
        subtitle: String,
        httpHeaders: [String: String],
        externalSubtitles: [NuvioSubtitle],
        resumeFrom: Double?,
        origin: PlaybackOrigin
    ) {
        if PictureInPictureManager.shared.isPictureInPictureActive,
           PictureInPictureManager.shared.activeContext?.url != url {
            PictureInPictureManager.shared.invalidateSession()
        }
        playbackOrigin = origin
        playbackDidStart = false
        withAnimation(.easeInOut(duration: 0.28)) {
            activeScreen = .player(
                url: url,
                meta: meta,
                subtitle: subtitle,
                httpHeaders: httpHeaders,
                externalSubtitles: externalSubtitles,
                resumeFrom: resumeFrom
            )
        }
    }

    private func setupPictureInPicture() {
        PictureInPictureManager.shared.onRestoreUI = { [self] context, completion in
            withAnimation(.easeInOut(duration: 0.24)) {
                self.playbackOrigin = context.playbackOrigin
                self.playbackEpisodes = context.episodes
                self.playbackCurrentEpisode = context.currentEpisode
                self.activeScreen = .player(
                    url: context.url,
                    meta: context.meta,
                    subtitle: context.subtitle,
                    httpHeaders: context.httpHeaders,
                    externalSubtitles: context.externalSubtitles,
                    resumeFrom: context.resumeFrom
                )
            }
            completion(true)
        }

        PictureInPictureManager.shared.onDidStopPiPWithoutRestoring = {
            PlaybackWakeLock.release()
        }
    }

    /// The persistent tab view plus any Details/Player overlay. Keeping the tab
    /// view here (never swapped out) is what preserves Home's state across the
    /// details push. The tab view is disabled while an overlay is up so focus
    /// can't bleed to the cards behind it; re-enabling on return hands focus
    /// back to the card the user left on.
    @ViewBuilder
    private var appContainer: some View {
        PosterChromeStyleProvider {
        ZStack {
            mainTabView
                .disabled(shouldDisableHomeContent)
                // `.disabled` stops the tab *content* from taking focus, but the
                // sidebar/tab bar itself can still attract the focus engine while
                // an overlay is settling; focus landing there un-highlights the
                // overlay's seeded item and makes the next Menu press suspend the
                // app (system behaviour for Menu on a root tab bar). Alpha-0
                // views are unfocusable, so fading the tab view out while it's
                // covered keeps focus inside the overlay. It stays mounted, so
                // Home's state and focus memory survive for the return trip.
                // The card quick-actions menu is the exception: it floats a
                // liquid-glass panel *over* a still-visible Home, so the tab view
                // stays on screen (fading it to black would leave the glass
                // nothing to refract) — it's only `.disabled` so its cards can't
                // steal focus, and the menu re-grabs focus if the engine drifts.
                .opacity(fullScreenOverlayPresented ? 0 : 1)

            if case .details(let contentId, let contentType) = activeScreen {
                detailsScreen(contentId: contentId, contentType: contentType)
                    .id("\(contentType):\(contentId)")
                    .transition(.opacity)
                    .onDisappear {
                        detailsDidDisappearGeneration &+= 1
                    }
                    .zIndex(1)
            }

            if case .player(let url, let meta, let subtitle, let httpHeaders, let externalSubtitles, let resumeFrom) = activeScreen {
                playerScreen(
                    url: url,
                    meta: meta,
                    subtitle: subtitle,
                    httpHeaders: httpHeaders,
                    externalSubtitles: externalSubtitles,
                    resumeFrom: resumeFrom
                )
                .transition(.opacity)
                .zIndex(2)
            }

            if case .cloudLibrary = activeScreen {
                cloudLibraryScreen()
                    .transition(.opacity)
                    .zIndex(1)
            }

            if let collectionContext = presentedCollectionFolder {
                let folder = collectionContext.folder
                let collectionTitle = collectionContext.collectionTitle
                CollectionFolderBrowseView(
                    folder: folder,
                    collectionTitle: collectionTitle,
                    repository: CinemetaCatalogRepository(),
                    onSelect: { meta in
                        withAnimation(.easeInOut(duration: 0.28)) {
                            openDetailsRoot(
                                id: meta.id,
                                type: meta.type,
                                returnDestination: .collectionFolder(
                                    folder,
                                    collectionTitle: collectionTitle
                                )
                            )
                        }
                    },
                    onLongPress: { meta in
                        cardMenuReturnDestination = .collectionFolder(
                            folder,
                            collectionTitle: collectionTitle
                        )
                        withAnimation(.easeInOut(duration: 0.2)) {
                            cardMenuMeta = meta
                        }
                    },
                    onBack: {
                        if ["STREAMING_SERVICE", "STUDIO_FRANCHISE"].contains(
                            folder.presentationStyle?.uppercased() ?? ""
                        ) {
                            var transaction = Transaction()
                            transaction.animation = nil
                            withTransaction(transaction) {
                                activeScreen = .main
                            }
                        } else {
                            withAnimation(.easeInOut(duration: 0.24)) {
                                activeScreen = .main
                            }
                        }
                    }
                )
                .disabled(!isCollectionFolderActive || cardMenuMeta != nil)
                .transition(.opacity)
                .zIndex(isCollectionFolderActive ? 1 : 0)
            }

            if case .productionBrowse(let company) = activeScreen {
                ProductionBrowseView(
                    company: company,
                    onSelect: { title in
                        withAnimation(.easeInOut(duration: 0.28)) {
                            if let ret = productionBrowseReturn {
                                // Keep the originating Details screen in the
                                // same navigation chain. Otherwise backing out
                                // of the selected title falls all the way home.
                                detailsBackStack.append((id: ret.id, type: ret.type))
                                activeScreen = .details(id: title.id, type: title.type)
                            } else {
                                openDetailsRoot(id: title.id, type: title.type)
                            }
                            productionBrowseReturn = nil
                        }
                    },
                    onBack: {
                        withAnimation(.easeInOut(duration: 0.24)) {
                            if let ret = productionBrowseReturn {
                                activeScreen = .details(id: ret.id, type: ret.type)
                            } else {
                                activeScreen = .main
                            }
                            productionBrowseReturn = nil
                        }
                    }
                )
                .transition(.opacity)
                .zIndex(1)
            }

            if case .personBrowse(let person) = activeScreen {
                PersonBrowseView(
                    person: person,
                    onSelect: { title in
                        withAnimation(.easeInOut(duration: 0.28)) {
                            if let ret = personBrowseReturn {
                                // Keep the originating Details screen in the
                                // same navigation chain. Otherwise backing out
                                // of the selected title falls all the way home.
                                detailsBackStack.append((id: ret.id, type: ret.type))
                                activeScreen = .details(id: title.id, type: title.type)
                            } else {
                                openDetailsRoot(id: title.id, type: title.type)
                            }
                            personBrowseReturn = nil
                        }
                    },
                    onBack: {
                        withAnimation(.easeInOut(duration: 0.24)) {
                            if let ret = personBrowseReturn {
                                activeScreen = .details(id: ret.id, type: ret.type)
                            } else {
                                activeScreen = .main
                            }
                            personBrowseReturn = nil
                        }
                    }
                )
                .transition(.opacity)
                .zIndex(1)
            }

            if isResolvingContinueWatchingStream, let item = resolvingContinueWatchingItem {
                PlayerLoadingOverlay(
                    backdropUrl: item.meta.backgroundUrl ?? item.meta.posterUrl,
                    logoUrl: item.meta.logoUrl,
                    title: item.meta.name,
                    message: L10n.string("player_status_starting_stream", fallback: "Starting stream")
                )
                .transition(.opacity)
                .zIndex(3)
            }

            // The adaptive tab sidebar is briefly expanded while its first
            // focus pass runs. Keep the full tab container covered while Home
            // loads so its loading/card default focus and native scroll state
            // can settle before the user sees it. This applies equally to an
            // automatic cold launch and a newly selected profile.
            if isPreparingProfile {
                ZStack {
                    ProfileScopedRootBackground()
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .scaleEffect(1.8)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .transition(.opacity)
                .zIndex(4)
            }
        }
        }
    }

    private var mainTabView: some View {
        TVMainTabView(
            selectedTab: $selectedTab,
            activeProfile: profileViewModel.activeProfile,
            searchViewModel: searchViewModel,
            libraryViewModel: libraryViewModel,
            homeStore: homeStore,
            homeCatalogRevision: syncManager.homeCatalogRevision,
            homeCollectionsRevision: syncManager.homeCollectionsRevision,
            isFullScreenOverlayPresented: fullScreenOverlayPresented,
            detailsDidDisappearGeneration: detailsDidDisappearGeneration,
            accountEmail: authManager.currentEmail,
            isAuthenticated: authManager.isAuthenticated,
            sessionNeedsReauthentication: authManager.sessionNeedsReauthentication,
            isProfileSwitching: isPreparingProfile,
            authManager: authManager,
            syncManager: syncManager,
            onSwitchProfile: {
                // A fresh profile should get a fresh Home (different Continue
                // Watching, etc.), so drop the cached catalog.
                homeStore.reset()
                withAnimation(.easeInOut(duration: 0.28)) {
                    profileViewModel.activeProfile = nil
                    activeScreen = .profileSelection
                }
            },
            onChangeProfileAvatar: { profileId, avatarId in
                profileViewModel.updateProfileAvatar(id: profileId, avatarId: avatarId)
                syncManager.syncProfilesAfterLocalEdit()
            },
            onChangeProfileName: { profileId, name in
                profileViewModel.updateProfileName(id: profileId, name: name)
                syncManager.syncProfilesAfterLocalEdit()
            },
            onChangeProfilePin: { profileId, pin, currentPin in
                if authManager.isAuthenticated {
                    return await syncManager.updateProfilePin(
                        profileId: profileId,
                        pin: pin,
                        currentPin: currentPin
                    )
                }
                return profileViewModel.updateProfilePin(id: profileId, pin: pin)
            },
            onVerifyProfilePin: { profileId, pin in
                if authManager.isAuthenticated {
                    return await syncManager.verifyProfilePin(profileId: profileId, pin: pin)
                }
                return profileViewModel.verifyProfilePin(id: profileId, pin: pin)
            },
            onSignIn: {
                authManager.requireLogin()
                homeStore.reset()
                withAnimation(.easeInOut(duration: 0.28)) {
                    selectedTab = .home
                    profileViewModel.activeProfile = nil
                    activeScreen = .login
                }
            },
            onSignOut: {
                // Order matters: signOut() flips auth state first so the sync
                // manager stops pushing before the local wipe below fires
                // store-changed notifications.
                authManager.signOut()
                profileViewModel.resetForSignedOut()
                homeStore.reset()
                searchViewModel.clear()
                searchViewModel.clearRecent()
                withAnimation(.easeInOut(duration: 0.28)) {
                    selectedTab = .home
                    profileViewModel.activeProfile = nil
                    activeScreen = .login
                }
            },
            onNavigateToDetails: { contentId, contentType in
                // Home defers its focus-restoration render until Details closes,
                // so every tab can now use the same presentation transaction.
                withAnimation(.easeInOut(duration: 0.28)) {
                    openDetailsRoot(id: contentId, type: contentType)
                }
            },
            onRequestAccountRefresh: {
                syncManager.refreshAccountIfIdle()
            },
            onOpenCollectionFolder: { folder, collectionTitle in
                if ["STREAMING_SERVICE", "STUDIO_FRANCHISE"].contains(
                    folder.presentationStyle?.uppercased() ?? ""
                ) {
                    // This template owns a full-bleed backdrop and several
                    // poster rails. Cross-fading it with the equally heavy Home
                    // tree makes entry hitch, so hand off in one transaction.
                    var transaction = Transaction()
                    transaction.animation = nil
                    withTransaction(transaction) {
                        activeScreen = .collectionFolder(folder, collectionTitle: collectionTitle)
                    }
                } else {
                    withAnimation(.easeInOut(duration: 0.28)) {
                        activeScreen = .collectionFolder(folder, collectionTitle: collectionTitle)
                    }
                }
            },
            onResumePlayback: { item in
                resumePlayback(item)
            },
            onPlayContinueWatchingManually: { item in
                playContinueWatchingManually(item)
            },
            onStartContinueWatchingFromBeginning: { item in
                resumePlayback(item, startFromBeginning: true)
            },
            onRemoveFromContinueWatching: { item in
                removeFromContinueWatching(item)
            },
            onLongPressCard: { meta in
                cardMenuReturnDestination = .main
                withAnimation(.easeInOut(duration: 0.2)) {
                    cardMenuMeta = meta
                }
            },
            onLongPressContinueWatching: { item in
                withAnimation(.easeInOut(duration: 0.2)) {
                    continueWatchingMenuItem = item
                }
            },
            onOpenCloudLibrary: {
                withAnimation(.easeInOut(duration: 0.28)) {
                    activeScreen = .cloudLibrary
                }
            },
            onPlayCloudFile: { url, meta in
                playbackEpisodes = []
                playbackCurrentEpisode = nil
                presentPlayback(
                    url: url,
                    meta: meta,
                    subtitle: "",
                    externalSubtitles: [],
                    resumeFrom: nil,
                    origin: .cloudLibrary
                )
            }
        )
    }

    private func detailsScreen(contentId: String, contentType: String) -> some View {
        DetailsScreen(
            id: contentId,
            type: contentType,
            repository: CinemetaCatalogRepository(),
            initiallyPresentStreamPicker: reopenStreamPickerOnDetails,
            initialStreamPickerEpisode: reopenStreamPickerEpisode,
            onInitialStreamPickerPresented: {
                reopenStreamPickerOnDetails = false
                reopenStreamPickerEpisode = nil
            },
            onPlayClick: { streamUrlString, httpHeaders, meta, subtitle, externalSubtitles, currentEpisode, episodes, player in
                if let url = URL(string: streamUrlString) {
                    let isTrailer = subtitle == PlaybackMarkers.trailerSubtitle
                    reopenStreamPickerOnDetails = false
                    reopenStreamPickerEpisode = nil
                    playbackEpisodes = episodes
                    playbackCurrentEpisode = currentEpisode
                    presentPlayback(
                        url: url,
                        meta: meta,
                        subtitle: subtitle,
                        externalSubtitles: externalSubtitles,
                        resumeFrom: isTrailer ? nil : Self.resumePosition(for: meta, episode: currentEpisode),
                        httpHeaders: httpHeaders,
                        origin: .details,
                        customPlayer: player
                    )
                }
            },
            onBack: { leaveDetails() },
            onOpenTitle: { nextId, nextType in
                detailsBackStack.append((id: contentId, type: contentType))
                withAnimation(.easeInOut(duration: 0.28)) {
                    activeScreen = .details(id: nextId, type: nextType)
                }
            },
            onOpenProduction: { company in
                productionBrowseReturn = (contentId, contentType)
                withAnimation(.easeInOut(duration: 0.28)) {
                    activeScreen = .productionBrowse(company)
                }
            },
            onOpenPerson: { person in
                personBrowseReturn = (contentId, contentType)
                withAnimation(.easeInOut(duration: 0.28)) {
                    activeScreen = .personBrowse(person)
                }
            }
        )
    }

    private func cloudLibraryScreen() -> some View {
        CloudLibraryView(
            store: ProfileSettings.store(for: profileViewModel.activeProfile?.id),
            onPlay: { url, meta in
                playbackEpisodes = []
                playbackCurrentEpisode = nil
                presentPlayback(
                    url: url,
                    meta: meta,
                    subtitle: "",
                    externalSubtitles: [],
                    resumeFrom: nil,
                    origin: .cloudLibrary
                )
            },
            onBack: {
                withAnimation(.easeInOut(duration: 0.24)) {
                    activeScreen = .main
                }
            }
        )
    }

    /// Resolves a next episode into a ready-to-play stream for the player's
    /// seamless auto-advance: fetches the episode's streams (concurrently) and
    /// applies the same smart selection the details screen uses. Returns nil when
    /// nothing real is available, so the player falls back to a normal end.
    private static func resolveNextEpisodeStream(episode: NuvioVideo, profileId: String?) async -> PreparedNextStream? {
        await resolveStream(
            contentId: episode.id,
            type: "series",
            subtitleLine: "S\(episode.season) · E\(episode.episode) · \(episode.title)",
            profileId: profileId
        )
    }

    /// Fetches a content id's streams (concurrently) and applies smart selection,
    /// returning a ready-to-play stream. Used both to advance to the next episode
    /// and to reload a fresh link for the current title when one expires or fails.
    /// `excludingURLs` skips sources already tried this session (failover).
    private static func resolveStream(
        contentId: String,
        type: String,
        subtitleLine: String,
        profileId: String?,
        excludingURLs: Set<String> = []
    ) async -> PreparedNextStream? {
        let streams = await StreamsRepository.shared.collectStreams(type: type, videoId: contentId)
        guard !streams.isEmpty else { return nil }

        let store = ProfileSettings.store(for: profileId)
        let quality = store.string(forKey: SettingsKey.smartStreamQuality) ?? "Highest"
        let matchSubtitles = store.object(forKey: SettingsKey.smartSubtitleMatching) as? Bool ?? true
        let languages = SubtitleLanguagePreferences.orderedFromDefaults(defaults: store)
        let cachedOnly = (store.object(forKey: SettingsKey.cachedOnlyStreams) as? Bool) ?? false
        // Prefer the series meta id for quality memory when content id is an episode.
        let metaIdForTags = contentId.split(separator: ":").first.map(String.init) ?? contentId
        let preferredTags = LastStreamQualityStore.load(metaId: metaIdForTags, profileId: profileId)
            ?? LastStreamQualityStore.load(metaId: contentId, profileId: profileId)

        let debrid = DebridResolver(store: store)
        let ranked = Self.rankedPlayableStreams(
            from: streams,
            qualityPreference: quality,
            subtitleLanguages: languages,
            shouldMatchSubtitles: matchSubtitles,
            includeDebrid: debrid.isEnabled,
            preferredTags: preferredTags,
            cachedOnly: cachedOnly
        )
        guard !ranked.isEmpty else { return nil }

        let (season, episode) = Self.seasonEpisode(fromContentId: contentId)
        for candidate in ranked {
            // Direct URL already known-bad this session.
            if let urlString = candidate.url?.trimmingCharacters(in: .whitespacesAndNewlines),
               !urlString.isEmpty,
               excludingURLs.contains(urlString) {
                continue
            }

            if candidate.isDebridResolvable {
                guard case let .success(url, _, _)? = await debrid.resolvedURL(
                    for: candidate,
                    season: season,
                    episode: episode
                ) else { continue }
                if excludingURLs.contains(url.absoluteString) { continue }
                LastStreamQualityStore.save(
                    metaId: metaIdForTags,
                    stream: candidate,
                    profileId: profileId
                )
                return PreparedNextStream(
                    url: url,
                    httpHeaders: candidate.httpHeaders ?? [:],
                    subtitleLine: subtitleLine,
                    subtitles: candidate.subtitles,
                    streamName: candidate.name,
                    streamDescription: candidate.description,
                    filename: candidate.filename,
                    addonName: candidate.addonName,
                    videoSize: candidate.videoSize,
                    provider: debrid.selectedKind.rawValue
                )
            }

            guard let urlString = candidate.url, let url = URL(string: urlString) else { continue }
            LastStreamQualityStore.save(
                metaId: metaIdForTags,
                stream: candidate,
                profileId: profileId
            )
            return PreparedNextStream(
                url: url,
                httpHeaders: candidate.httpHeaders ?? [:],
                subtitleLine: subtitleLine,
                subtitles: candidate.subtitles,
                streamName: candidate.name,
                streamDescription: candidate.description,
                filename: candidate.filename,
                addonName: candidate.addonName,
                videoSize: candidate.videoSize,
                provider: "Direct"
            )
        }
        return nil
    }

    /// All playable sources for the Sources side panel, in the same order the
    /// Details stream picker lists them. `collectStreams` already returns the
    /// add-on groups flattened in configured order, so running the picker's own
    /// derivation (playable filter + Default sort) reproduces that list exactly
    /// — smart-best-first ranking here would have shown a different order for
    /// the same content.
    private static func fetchSources(
        contentId: String,
        type: String,
        profileId: String?
    ) async -> [NuvioStream] {
        let streams = await StreamsRepository.shared.collectStreams(type: type, videoId: contentId)
        let store = ProfileSettings.store(for: profileId)
        let debrid = DebridResolver(store: store)
        let cachedOnly = (store.object(forKey: SettingsKey.cachedOnlyStreams) as? Bool) ?? false
        let sortRaw = store.string(forKey: SettingsKey.streamSortOption)
        let sortOption = sortRaw.flatMap(StreamSortOption.init(rawValue:)) ?? .quality
        return StreamPickerListBuilder.displayedStreams(
            streams: streams,
            groups: [],
            selectedAddonId: nil,
            sortOption: sortOption,
            includeDebrid: debrid.isEnabled,
            cachedOnly: cachedOnly
        )
    }

    /// Resolves one user-picked source (direct URL or debrid) for mid-playback switch.
    private static func resolveChosenStream(
        _ stream: NuvioStream,
        contentId: String,
        subtitleLine: String,
        profileId: String?
    ) async -> PreparedNextStream? {
        let store = ProfileSettings.store(for: profileId)
        let debrid = DebridResolver(store: store)
        let (season, episode) = seasonEpisode(fromContentId: contentId)
        let metaIdForTags = contentId.split(separator: ":").first.map(String.init) ?? contentId

        if stream.isDebridResolvable {
            guard case let .success(url, _, _)? = await debrid.resolvedURL(
                for: stream,
                season: season,
                episode: episode
            ) else { return nil }
            LastStreamQualityStore.save(
                metaId: metaIdForTags,
                stream: stream,
                profileId: profileId
            )
            return PreparedNextStream(
                url: url,
                httpHeaders: stream.httpHeaders ?? [:],
                subtitleLine: subtitleLine,
                subtitles: stream.subtitles,
                streamName: stream.name,
                streamDescription: stream.description,
                filename: stream.filename,
                addonName: stream.addonName,
                videoSize: stream.videoSize,
                provider: debrid.selectedKind.rawValue
            )
        }

        guard let urlString = stream.url, let url = URL(string: urlString) else { return nil }
        LastStreamQualityStore.save(
            metaId: metaIdForTags,
            stream: stream,
            profileId: profileId
        )
        return PreparedNextStream(
            url: url,
            httpHeaders: stream.httpHeaders ?? [:],
            subtitleLine: subtitleLine,
            subtitles: stream.subtitles,
            streamName: stream.name,
            streamDescription: stream.description,
            filename: stream.filename,
            addonName: stream.addonName,
            videoSize: stream.videoSize,
            provider: "Direct"
        )
    }

    /// Ordered candidates for playback / failover: smart-best first (including
    /// last-watched DV/HDR/Atmos match), then remaining playable streams.
    private static func rankedPlayableStreams(
        from streams: [NuvioStream],
        qualityPreference: String,
        subtitleLanguages: [String],
        shouldMatchSubtitles: Bool,
        includeDebrid: Bool,
        preferredTags: StreamQualityTags? = nil,
        cachedOnly: Bool = false
    ) -> [NuvioStream] {
        SmartPlaybackSelector.rankedStreams(
            from: streams,
            qualityPreference: qualityPreference,
            subtitleLanguages: subtitleLanguages,
            shouldMatchSubtitles: shouldMatchSubtitles,
            includeDebrid: includeDebrid,
            preferredTags: preferredTags,
            cachedOnly: cachedOnly
        )
    }

    /// Parses the season/episode out of a Stremio series content id of the form
    /// `tt1234567:2:5` (imdb-id : season : episode). Returns `(nil, nil)` for
    /// movies or ids without the trailing numbers.
    private static func seasonEpisode(fromContentId contentId: String) -> (season: Int?, episode: Int?) {
        let parts = contentId.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3, let season = Int(parts[parts.count - 2]), let episode = Int(parts[parts.count - 1]) else {
            return (nil, nil)
        }
        return (season, episode)
    }

    private static func episodeNumbers(fromSubtitle subtitle: String) -> (season: Int, episode: Int)? {
        let pattern = #"S(\d+)\s*[·.\-–—]?\s*E(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(
                  in: subtitle,
                  range: NSRange(subtitle.startIndex..., in: subtitle)
              ),
              let seasonRange = Range(match.range(at: 1), in: subtitle),
              let episodeRange = Range(match.range(at: 2), in: subtitle),
              let season = Int(subtitle[seasonRange]),
              let episode = Int(subtitle[episodeRange]) else { return nil }
        return (season, episode)
    }

    private static func runtimeSeconds(_ runtime: String?) -> Double? {
        guard let runtime = runtime?.lowercased(), !runtime.isEmpty else { return nil }
        let hours = firstRuntimeNumber(runtime, pattern: #"(\d+)\s*h"#) ?? 0
        let minutes = firstRuntimeNumber(runtime, pattern: #"(\d+)\s*m(?:in)?"#)
            ?? (hours == 0 ? firstRuntimeNumber(runtime, pattern: #"^\s*(\d+)\s*$"#) : 0)
        let seconds = (hours * 60 + (minutes ?? 0)) * 60
        return seconds > 0 ? Double(seconds) : nil
    }

    private static func firstRuntimeNumber(_ value: String, pattern: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range(at: 1), in: value) else { return nil }
        return Int(value[range])
    }

    @ViewBuilder
    private func playerScreen(
        url: URL,
        meta: NuvioMeta,
        subtitle: String,
        httpHeaders: [String: String],
        externalSubtitles: [NuvioSubtitle],
        resumeFrom: Double?
    ) -> some View {
        let isTrailer = subtitle == PlaybackMarkers.trailerSubtitle
        let store = ProfileSettings.store(for: profileViewModel.activeProfile?.id)
        let autoPlayNext = store.object(forKey: SettingsKey.autoPlayNext) as? Bool ?? true
        let autoPlayNextCountdown = store.object(forKey: SettingsKey.autoPlayNextCountdown) as? Int ?? 10
        PlayerView(
            url: url,
            meta: meta,
            subtitle: subtitle,
            httpHeaders: httpHeaders,
            externalSubtitles: externalSubtitles,
            resumeFrom: resumeFrom,
            playbackOrigin: playbackOrigin,
            episodes: isTrailer ? [] : playbackEpisodes,
            currentEpisode: isTrailer ? nil : playbackCurrentEpisode,
            autoPlayNextEnabled: autoPlayNext,
            autoPlayNextCountdownSeconds: autoPlayNextCountdown,
            resolveNextStream: (isTrailer || !meta.isSeries) ? nil : { episode in
                await Self.resolveNextEpisodeStream(episode: episode, profileId: profileViewModel.activeProfile?.id)
            },
            reloadCurrentStream: isTrailer ? nil : { excludedURLs in
                let profileId = profileViewModel.activeProfile?.id
                let excluded = Set(excludedURLs)
                if let episode = playbackCurrentEpisode {
                    return await Self.resolveStream(
                        contentId: episode.id,
                        type: "series",
                        subtitleLine: "S\(episode.season) · E\(episode.episode) · \(episode.title)",
                        profileId: profileId,
                        excludingURLs: excluded
                    )
                }
                return await Self.resolveStream(
                    contentId: meta.id,
                    type: meta.type,
                    subtitleLine: subtitle,
                    profileId: profileId,
                    excludingURLs: excluded
                )
            },
            fetchPlaybackSources: isTrailer ? nil : { contentId, type in
                await Self.fetchSources(
                    contentId: contentId,
                    type: type,
                    profileId: profileViewModel.activeProfile?.id
                )
            },
            resolvePlaybackStream: isTrailer ? nil : { stream, contentId, subtitleLine in
                await Self.resolveChosenStream(
                    stream,
                    contentId: contentId,
                    subtitleLine: subtitleLine,
                    profileId: profileViewModel.activeProfile?.id
                )
            },
            onFinished: isTrailer ? {
                withAnimation(.easeInOut(duration: 0.24)) {
                    activeScreen = .details(id: meta.id, type: meta.type)
                }
            } : nil,
            onPlaybackStarted: {
                playbackDidStart = true
            },
            onPlayRecommendation: { recMeta, playManually in
                dismissPlayer(meta: meta, subtitle: subtitle)
                playRecommendedTitle(meta: recMeta, playManually: playManually)
            },
            onOpenRecommendationDetails: { recMeta in
                dismissPlayer(meta: meta, subtitle: subtitle)
                withAnimation(.easeInOut(duration: 0.28)) {
                    openDetailsRoot(id: recMeta.id, type: recMeta.type)
                }
            }
        ) {
            dismissPlayer(meta: meta, subtitle: subtitle)
        }
    }

    private func playRecommendedTitle(meta: NuvioMeta, playManually: Bool) {
        if playManually || meta.isSeries {
            withAnimation(.easeInOut(duration: 0.28)) {
                openDetailsRoot(id: meta.id, type: meta.type)
            }
            return
        }

        let profileId = profileViewModel.activeProfile?.id
        Task {
            let prepared = await Self.resolveStream(
                contentId: meta.id,
                type: meta.type,
                subtitleLine: "",
                profileId: profileId
            )
            guard !Task.isCancelled else { return }
            if let prepared {
                presentPlayback(
                    url: prepared.url,
                    meta: meta,
                    subtitle: prepared.subtitleLine,
                    externalSubtitles: prepared.subtitles,
                    resumeFrom: nil,
                    httpHeaders: prepared.httpHeaders
                )
            } else {
                withAnimation(.easeInOut(duration: 0.28)) {
                    openDetailsRoot(id: meta.id, type: meta.type)
                }
            }
        }
    }

    private func dismissPlayer(meta: NuvioMeta, subtitle: String) {
        let isTrailer = subtitle == PlaybackMarkers.trailerSubtitle
        withAnimation(.easeInOut(duration: 0.24)) {
            switch playbackOrigin {
            case .details:
                // A stream that never reached playback should return to the
                // exact decision point so another source is one click away.
                reopenStreamPickerOnDetails = !playbackDidStart && !isTrailer
                reopenStreamPickerEpisode = reopenStreamPickerOnDetails ? playbackCurrentEpisode : nil
                activeScreen = .details(id: meta.id, type: meta.type)
            case .cloudLibrary:
                activeScreen = .main
            case .main:
                activeScreen = (isTrailer || meta.isSeries)
                    ? .details(id: meta.id, type: meta.type)
                    : .main
            }
        }
    }
}



/// Shown between login and who's-watching while the first account pull is in
/// flight, so profile names arrive before the selection grid renders.
private struct AccountSyncWaitView: View {
    var body: some View {
        VStack(spacing: 26) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
                .scaleEffect(1.6)

            Text("Syncing your account")
                .font(.custom("Inter-Bold", size: 44))
                .foregroundColor(.white)

            Text("Hang tight while we import your profiles and watch history.")
                .font(.custom("Inter-Regular", size: 28))
                .foregroundColor(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Give the focus engine somewhere to land; with no focusable view on
        // screen a Menu press would quit the app.
        .focusable()
    }
}

/// Root background that reads the appearance settings from the active profile's
/// store (through the inherited `.defaultAppStorage`), so the theme color follows
/// the selected profile rather than being shared across all profiles.
private struct ProfileScopedRootBackground: View {
    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue

    var body: some View {
        Color.nuvioBackground(amoled: amoled, body: bodyColor).ignoresSafeArea()
    }
}



/// Composites the active profile's avatar (catalog face or custom web image
/// over its accent circle)
/// into a static, circular bitmap for use as the profile tab's icon.
///
/// tvOS tab items can only display a still image, not a live `AsyncImage`/SwiftUI
/// view, so `ProfileAvatarView` can't be dropped into a `.tabItem` directly. We
/// draw the same composition off-screen once per avatar and hand the finished
/// bitmap to the tab bar; until it's ready (or when no avatar is set) the tab
/// falls back to the generic person symbol.
@MainActor
final class ProfileTabAvatarRenderer: ObservableObject {
    @Published private(set) var image: UIImage?
    /// The avatar id the current `image` (or in-flight render) belongs to, so we
    /// skip redundant work and ignore renders that finish after a profile swap.
    private var renderedAvatarId: String?

    /// Point size of the composited icon. tvOS scales tab images down to fit, so
    /// a generous size keeps the avatar crisp in the sidebar.
    private let diameter: CGFloat = 50

    func refresh(avatarId: String?) {
        guard let avatarId, !avatarId.isEmpty,
              let url = AvatarCatalogStore.shared.imageURL(for: avatarId) else {
            // No avatar chosen, or the catalog/custom URL is not available:
            // show the symbol. Clearing `renderedAvatarId` lets a later
            // refresh (once the catalog arrives) re-attempt the render.
            renderedAvatarId = nil
            image = nil
            return
        }
        guard avatarId != renderedAvatarId else { return }
        renderedAvatarId = avatarId
        image = nil
        let background = UIColor(
            AvatarCatalogStore.shared.item(for: avatarId)?.backgroundColor
                ?? Color(red: 0.12, green: 0.30, blue: 0.55)
        )
        Task { await render(avatarId: avatarId, url: url, background: background) }
    }

    private func render(avatarId: String, url: URL, background: UIColor) async {
        guard let face = await BackdropImageCache.shared.image(for: url) else { return }
        let size = CGSize(width: diameter, height: diameter)
        let composed = UIGraphicsImageRenderer(size: size).image { ctx in
            let rect = CGRect(origin: .zero, size: size)
            ctx.cgContext.addEllipse(in: rect)
            ctx.cgContext.clip()
            background.setFill()
            ctx.fill(rect)

            // Aspect-fill the (transparent-PNG) face inside the circle.
            let faceSize = face.size
            guard faceSize.width > 0, faceSize.height > 0 else { return }
            let scale = max(rect.width / faceSize.width, rect.height / faceSize.height)
            let drawSize = CGSize(width: faceSize.width * scale, height: faceSize.height * scale)
            let origin = CGPoint(x: (rect.width - drawSize.width) / 2,
                                 y: (rect.height - drawSize.height) / 2)
            face.draw(in: CGRect(origin: origin, size: drawSize))
        }.withRenderingMode(.alwaysOriginal)

        // Bail if the active profile changed while the face was downloading.
        guard renderedAvatarId == avatarId else { return }
        image = composed
    }
}

@available(tvOS 27.0, *)
private struct TVSidebarProfileHeader: View {
    let profile: Profile?
    let action: () -> Void

    @FocusState private var isFocused: Bool
    @AppStorage(SettingsKey.profileName) private var settingsProfileName = "Nuvio User"

    var body: some View {
        HStack(spacing: 12) {
            TVSidebarAvatar(profile: profile, isFocused: isFocused)

            VStack(alignment: .leading, spacing: 3) {
                Text(displayName)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .layoutPriority(1)

                if isFocused {
                    Text("Change Profile")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white.opacity(0.72))
                        .lineLimit(1)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            if !isFocused {
                TimelineView(.periodic(from: Date(), by: 30)) { context in
                    Text(context.date, format: .dateTime.hour().minute())
                        .font(.system(size: 23, weight: .medium))
                        .foregroundColor(.white.opacity(0.68))
                        .lineLimit(1)
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
        .focusable(true)
        .focused($isFocused)
        .focusEffectDisabled()
        .onTapGesture(perform: action)
        .animation(.easeInOut(duration: 0.2), value: isFocused)
    }

    private var displayName: String {
        ProfileDisplayName.resolve(profile: profile, settingsName: settingsProfileName)
    }
}

private struct TVSidebarAvatar: View {
    let profile: Profile?
    let isFocused: Bool

    var body: some View {
        ProfileAvatarView(
            avatarId: profile?.avatarId ?? ProfileAvatarCatalog.defaultId,
            size: 44,
            isFocused: isFocused
        )
        .scaleEffect(isFocused ? 1.12 : 1)
        .offset(y: isFocused ? -3 : 0)
        .shadow(color: .black.opacity(isFocused ? 0.32 : 0), radius: 12, x: 0, y: 8)
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: isFocused)
    }
}

enum ProfileDisplayName {
    static func resolve(profile: Profile?, settingsName: String) -> String {
        if let profileName = profile?.name.trimmingCharacters(in: .whitespacesAndNewlines),
           !profileName.isEmpty {
            return profileName
        }
        let trimmed = settingsName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Nuvio User" : trimmed
    }
}






/// User-controlled ordering of Home rows (Settings → Layout → Home Catalogs).
/// The saved order lives in the active profile's settings; Home records a
/// titles snapshot on every load so the Settings list can render row names
/// without refetching catalogs.
enum TVHomeCatalogOrder {
    static let changedNotification = Notification.Name("nuvio.tv.homeCatalogOrder.changed")
    static let snapshotChangedNotification = Notification.Name("nuvio.tv.homeCatalogSnapshot.changed")

    static func catalogDisplayTitle(_ name: String, contentType: String, showType: Bool) -> String {
        guard showType else { return name }
        let normalized = contentType.lowercased().replacingOccurrences(of: "_", with: "-")
        let suffix: String
        switch normalized {
        case "movie": suffix = "Movies"
        case "series", "show", "tvshow", "tv-show": suffix = "TV Shows"
        case "anime": suffix = "Anime"
        case "channel", "live", "livetv", "live-tv", "iptv", "radio": suffix = "Channels"
        default: suffix = contentType.prefix(1).uppercased() + contentType.dropFirst()
        }
        let lower = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.hasSuffix(suffix.lowercased()), !(suffix == "TV Shows" && lower.hasSuffix("series")) else { return name }
        return "\(name) - \(suffix)"
    }

    static func savedOrder() -> [String] {
        guard let data = ProfileSettings.current.data(forKey: SettingsKey.homeCatalogOrder),
              let keys = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return normalizedOrder(keys)
    }

    static func save(_ keys: [String]) {
        let keys = normalizedOrder(keys)
        guard let data = try? JSONEncoder().encode(keys) else { return }
        ProfileSettings.current.set(data, forKey: SettingsKey.homeCatalogOrder)
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    /// Home sections use `addon_<catalog-key>` ids while the account layout
    /// uses the catalog key without that UI prefix. Store the canonical form
    /// locally too, so a locally saved reorder survives the next catalog load.
    private static func normalizedOrder(_ keys: [String]) -> [String] {
        var seen = Set<String>()
        return keys.compactMap { rawKey in
            let key = sectionOrderKey(rawKey)
            guard !key.isEmpty, seen.insert(key).inserted else { return nil }
            return key
        }
    }

    private static func sectionOrderKey(_ id: String) -> String {
        if id.hasPrefix("addon_") {
            return String(id.dropFirst("addon_".count))
        }
        return id
    }

    /// Account catalog keys (`<addonId>_<type>_<catalogId>`) the user has hidden
    /// from Home on another device, pulled from the account. The repository
    /// consults this to drop hidden catalog rows before building Home.
    static func disabledCatalogKeys() -> Set<String> {
        guard let data = ProfileSettings.current.data(forKey: SettingsKey.homeCatalogDisabled),
              let keys = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(keys)
    }

    static func disabledAddonIDs() -> Set<String> {
        guard let data = ProfileSettings.current.data(forKey: SettingsKey.homeCatalogDisabledAddonIDs),
              let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(ids)
    }

    static func disabledAddonNames() -> Set<String> {
        guard let data = ProfileSettings.current.data(forKey: SettingsKey.homeCatalogDisabledAddonNames),
              let names = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(names)
    }

    static func normalizedAddonSourceName(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    static func setDisabledAddonSources(ids: Set<String>, names: Set<String>) {
        persist(ids, forKey: SettingsKey.homeCatalogDisabledAddonIDs)
        persist(
            Set(names.map(Self.normalizedAddonSourceName)),
            forKey: SettingsKey.homeCatalogDisabledAddonNames
        )
    }

    /// Collection ids the user has hidden from Home on another device.
    static func disabledCollectionIds() -> Set<String> {
        guard let data = ProfileSettings.current.data(forKey: SettingsKey.homeCollectionDisabled),
              let keys = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(keys)
    }

    /// Account catalog keys in the account's Home order → position, used by the
    /// repository to order the add-on catalog rows. Empty when nothing synced.
    static func syncedCatalogOrderIndex() -> [String: Int] {
        guard let data = ProfileSettings.current.data(forKey: SettingsKey.homeCatalogSyncedOrder),
              let keys = try? JSONDecoder().decode([String].self, from: data) else { return [:] }
        var index: [String: Int] = [:]
        for (position, key) in keys.enumerated() where index[key] == nil {
            index[key] = position
        }
        return index
    }

    /// Saved order first (rows the user has placed), then any new rows in
    /// their natural position order — mirrors Android's orderedKeys behavior.
    /// Falls back to the account-synced order when no local reorder exists.
    static func apply(to sections: [TVHomeSection]) -> [TVHomeSection] {
        let localOrder = savedOrder()
        let syncedKeys: [String] = {
            guard let data = ProfileSettings.current.data(forKey: SettingsKey.homeCatalogSyncedOrder),
                  let keys = try? JSONDecoder().decode([String].self, from: data) else { return [] }
            return normalizedOrder(keys)
        }()
        // Prefer the local Settings reorder; otherwise honor the account layout
        // (including `collection_<id>` slots among catalogs).
        let order = localOrder.isEmpty ? syncedKeys : localOrder
        guard !order.isEmpty else { return sections }
        var indexByKey: [String: Int] = [:]
        for (index, key) in order.enumerated() where indexByKey[key] == nil {
            indexByKey[key] = index
        }
        // Catalog rows from addons use `addon_<key>` ids; order keys omit the
        // prefix. Collection rows already use `collection_<id>`.
        func orderKey(for section: TVHomeSection) -> String {
            if section.isCollectionRow { return section.id }
            return sectionOrderKey(section.id)
        }
        let known = sections
            .filter { indexByKey[orderKey(for: $0)] != nil }
            .sorted {
                (indexByKey[orderKey(for: $0)] ?? 0) < (indexByKey[orderKey(for: $1)] ?? 0)
        }
        let unknown = sections.filter { indexByKey[orderKey(for: $0)] == nil }
        return known + unknown
    }

    /// One row as the Settings list needs it: what to call it, which add-on it
    /// came from, and the key that hides it.
    struct SnapshotRow: Equatable {
        let id: String
        let title: String
        let addonName: String?
        let addonId: String?
        let contentType: String?
        let catalogId: String?
        /// Nil for a row that cannot be hidden (Continue Watching).
        let settingsKey: String?
    }

    /// The account's key for a catalog row. Kept here so the repository, Home
    /// and Settings cannot drift into two spellings of the same key.
    static func catalogSettingsKey(addonId: String, contentType: String, catalogId: String) -> String {
        "\(addonId)_\(contentType)_\(catalogId)"
    }

    /// Records the effective rows after a Home load.
    ///
    /// Rows the user has hidden are absent from `sections` — Home never built
    /// them — so they are carried over from the previous snapshot at the index
    /// they last held. Without that, hiding a row also removed it from the
    /// Settings list and there was no way left to bring it back.
    static func writeSnapshot(_ sections: [TVHomeSection]) {
        let hiddenCatalogs = disabledCatalogKeys()
        let hiddenCollections = disabledCollectionIds()
        let disabledAddons = disabledAddonIDs()
        let disabledAddonNames = disabledAddonNames()
        var rows = sections.map {
            SnapshotRow(
                id: $0.id,
                title: $0.title,
                addonName: $0.addonName,
                addonId: $0.addonId,
                contentType: $0.contentType,
                catalogId: $0.catalogId,
                settingsKey: $0.catalogSettingsKey
            )
        }

        let live = Set(rows.map(\.id))
        for (index, previous) in snapshotRows().enumerated() {
            guard !live.contains(previous.id) else { continue }
            let isHiddenByLayout = previous.settingsKey.map { key in
                key.hasPrefix(TVHomeSection.collectionIdPrefix)
                    ? hiddenCollections.contains(
                        String(key.dropFirst(TVHomeSection.collectionIdPrefix.count))
                      )
                    : hiddenCatalogs.contains(key)
            } ?? false
            let isHiddenByAddon = previous.addonId.map(disabledAddons.contains) ?? false
                || previous.addonName.map {
                    disabledAddonNames.contains(normalizedAddonSourceName($0))
                } ?? false
            guard isHiddenByLayout || isHiddenByAddon else { continue }
            rows.insert(previous, at: min(index, rows.count))
        }

        writeSnapshotRows(rows)
    }

    /// Replaces one add-on's rows with the catalogs that actually returned
    /// content. Dynamic manifests rotate candidates, so merging would retain
    /// stale recommendations that no longer exist on Home.
    static func replaceSnapshotRows(
        forAddonID addonID: String,
        addonName: String,
        with additions: [SnapshotRow]
    ) {
        let current = snapshotRows()
        let normalizedName = normalizedAddonSourceName(addonName)
        func belongsToSource(_ row: SnapshotRow) -> Bool {
            if row.addonId == addonID { return true }
            guard row.addonId == nil, let rowName = row.addonName else { return false }
            return normalizedAddonSourceName(rowName) == normalizedName
        }

        let insertionIndex = current.firstIndex(where: belongsToSource) ?? current.count
        var rows = current.filter { !belongsToSource($0) }
        var seen = Set<String>()
        let uniqueAdditions = additions.filter { seen.insert($0.id).inserted }
        rows.insert(contentsOf: uniqueAdditions, at: min(insertionIndex, rows.count))
        guard rows != current else { return }
        writeSnapshotRows(rows)
    }

    /// Keeps the Settings list's snapshot aligned after an in-list move so
    /// re-entering the pane shows the new order even before Home reloads.
    static func writeSnapshotRows(_ rows: [SnapshotRow]) {
        let payload = rows.map { row -> [String: String] in
            var entry = ["id": row.id, "title": row.title]
            if let addonName = row.addonName { entry["addon"] = addonName }
            if let addonId = row.addonId { entry["addonId"] = addonId }
            if let contentType = row.contentType { entry["type"] = contentType }
            if let catalogId = row.catalogId { entry["catalogId"] = catalogId }
            if let settingsKey = row.settingsKey { entry["key"] = settingsKey }
            return entry
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        ProfileSettings.current.set(data, forKey: SettingsKey.homeCatalogTitles)
        NotificationCenter.default.post(name: snapshotChangedNotification, object: nil)
    }

    /// Rows for the Settings reorder list, from the last Home snapshot.
    static func snapshotRows() -> [SnapshotRow] {
        guard let data = ProfileSettings.current.data(forKey: SettingsKey.homeCatalogTitles),
              let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: String]] else {
            return []
        }
        return rows.compactMap { row in
            guard let id = row["id"], let title = row["title"] else { return nil }
            return SnapshotRow(
                id: id,
                title: title,
                addonName: row["addon"],
                addonId: row["addonId"],
                contentType: row["type"],
                catalogId: row["catalogId"],
                settingsKey: row["key"]
            )
        }
    }

    /// Builds the account payload for the current Home catalog snapshot.
    /// Home's `addon_...` ids are UI-only; sync receives the source add-on id,
    /// media type, catalog id, enabled state, and saved row order.
    static func syncItems() -> [[String: Any]] {
        var items: [[String: Any]] = []
        for row in snapshotRows() {
            guard let settingsKey = row.settingsKey else { continue }

            if settingsKey.hasPrefix(TVHomeSection.collectionIdPrefix) {
                let collectionId = String(settingsKey.dropFirst(TVHomeSection.collectionIdPrefix.count))
                guard !collectionId.isEmpty else { continue }
                items.append([
                    "addon_id": "",
                    "type": "",
                    "catalog_id": "",
                    "enabled": isRowEnabled(row),
                    "order": items.count,
                    "custom_title": "",
                    "is_collection": true,
                    "collection_id": collectionId
                ])
                continue
            }

            let source = catalogSyncSource(for: row)
            guard !source.addonId.isEmpty,
                  !source.contentType.isEmpty,
                  !source.catalogId.isEmpty else { continue }
            items.append([
                "addon_id": source.addonId,
                "type": source.contentType,
                "catalog_id": source.catalogId,
                "enabled": isRowEnabled(row),
                "order": items.count,
                "custom_title": "",
                "is_collection": false,
                "collection_id": ""
            ])
        }
        return items
    }

    private static func catalogSyncSource(
        for row: SnapshotRow
    ) -> (addonId: String, contentType: String, catalogId: String) {
        if let addonId = row.addonId,
           let contentType = row.contentType,
           let catalogId = row.catalogId {
            return (addonId, contentType, catalogId)
        }

        switch row.id {
        case "movie_top": return (CinemetaCatalogRepository.cinemetaAddonId, "movie", "top")
        case "series_top": return (CinemetaCatalogRepository.cinemetaAddonId, "series", "top")
        case "movie_rating": return (CinemetaCatalogRepository.cinemetaAddonId, "movie", "imdbRating")
        case "series_rating": return (CinemetaCatalogRepository.cinemetaAddonId, "series", "imdbRating")
        default: return ("", "", "")
        }
    }

    /// True when the row is currently shown on Home.
    static func isRowEnabled(_ row: SnapshotRow) -> Bool {
        guard let key = row.settingsKey else { return true }
        if key.hasPrefix(TVHomeSection.collectionIdPrefix) {
            let id = String(key.dropFirst(TVHomeSection.collectionIdPrefix.count))
            return !disabledCollectionIds().contains(id)
        }
        return !disabledCatalogKeys().contains(key)
    }

    /// Hides or restores one Home row. Writes the same profile settings the
    /// account pull writes, so the repository drops the row on Home's next load
    /// exactly as it would for a catalog hidden on another device.
    static func setRowEnabled(_ row: SnapshotRow, isEnabled: Bool) {
        guard let key = row.settingsKey else { return }
        if key.hasPrefix(TVHomeSection.collectionIdPrefix) {
            let id = String(key.dropFirst(TVHomeSection.collectionIdPrefix.count))
            var ids = disabledCollectionIds()
            if isEnabled { ids.remove(id) } else { ids.insert(id) }
            persist(ids, forKey: SettingsKey.homeCollectionDisabled)
        } else {
            var keys = disabledCatalogKeys()
            if isEnabled { keys.remove(key) } else { keys.insert(key) }
            persist(keys, forKey: SettingsKey.homeCatalogDisabled)
        }
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    private static func persist(_ keys: Set<String>, forKey key: String) {
        guard let data = try? JSONEncoder().encode(Array(keys).sorted()) else { return }
        ProfileSettings.current.set(data, forKey: key)
    }
}

/// Keeps catalogs used only inside synced collection folders out of top-level
/// Home rows. Inputs are explicit so the matching rule remains deterministic.
enum CatalogHomeVisibilityResolver {
    struct Source {
        let addonIdentifier: String
        let contentType: String
        let catalogID: String
        let collectionID: String

        init(addonIdentifier: String, contentType: String, catalogID: String, collectionID: String = "") {
            self.addonIdentifier = addonIdentifier
            self.contentType = contentType
            self.catalogID = catalogID
            self.collectionID = collectionID
        }
    }

    static func shouldInclude(
        addonID: String,
        contentType: String,
        catalogID: String,
        collectionSources: [Source],
        manifestURL: URL,
        explicitHomeKeys: Set<String>
    ) -> Bool {
        let key = TVHomeCatalogOrder.catalogSettingsKey(
            addonId: addonID, contentType: contentType, catalogId: catalogID
        )
        let matchingSources = collectionSources.filter {
            matches($0.addonIdentifier, addonID: addonID, manifestURL: manifestURL)
        }
        guard !matchingSources.isEmpty else { return true }

        // An explicitly represented catalog remains eligible (the existing
        // disabled-key filter decides whether Home actually shows it).
        if explicitHomeKeys.contains(key) { return true }

        // A synced collection row makes the layout authoritative for that
        // collection-backed add-on only. Other add-ons' synced rows must not
        // suppress manually installed catalogs here.
        let hasMatchingCollectionKey = matchingSources.contains {
            !($0.collectionID.isEmpty)
                && explicitHomeKeys.contains("collection_\($0.collectionID)")
        }
        if hasMatchingCollectionKey { return false }
        // Without a matching synced row, retain manual-install behavior while
        // hiding catalogs used exactly as collection sources.
        return !matchingSources.contains {
            $0.contentType == contentType && $0.catalogID == catalogID
        }
    }

    private static func matches(_ raw: String, addonID: String, manifestURL: URL) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.caseInsensitiveCompare(addonID) == .orderedSame { return true }
        var candidates = [value]
        if value.lowercased().hasPrefix("addon:"),
           let separator = value.dropFirst("addon:".count).firstIndex(of: ":") {
            candidates.append(String(value[value.index(after: separator)...]))
            let embeddedID = String(value[value.index(value.startIndex, offsetBy: "addon:".count)..<separator])
            if embeddedID.caseInsensitiveCompare(addonID) == .orderedSame { return true }
        }
        let canonical = canonicalURL(manifestURL)
        return candidates.compactMap(URL.init(string:)).contains {
            canonicalURL($0) == canonical
        }
    }

    private static func canonicalURL(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        var path = components.percentEncodedPath
        if path.split(separator: "/").last?.lowercased() == "manifest.json" {
            path = droppingTrailingSlash(String(path.dropLast("manifest.json".count)))
        } else {
            path = droppingTrailingSlash(path)
        }
        components.percentEncodedPath = path
        return components.string ?? url.absoluteString
    }

    private static func droppingTrailingSlash(_ input: String) -> String {
        var value = input
        while value.count > 1 && value.hasSuffix("/") { value.removeLast() }
        return value == "/" ? "" : value
    }
}












enum NuvioDateDisplay {
    static func formattedDate(_ value: String?) -> String? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        if raw.caseInsensitiveCompare("tbd") == .orderedSame || raw.caseInsensitiveCompare("tba") == .orderedSame {
            return "TBD"
        }

        let datePart = String(raw.prefix(10))
        if !showsFullDates {
            let year = String(datePart.prefix(4))
            return Int(year) == nil ? raw : year
        }
        guard datePart.count == 10,
              let date = isoDay.date(from: datePart) else {
            return raw
        }

        return display.string(from: date)
    }

    private static var showsFullDates: Bool {
        let key = "nuvio.tv.settings.layout.showFullDates"
        let defaults = UserDefaults.standard
        return defaults.object(forKey: key) == nil || defaults.bool(forKey: key)
    }

    private static let isoDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let display: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMMM d, yyyy"
        return f
    }()
}

/// Formats Stremio/Cinemeta runtime strings ("142 min", "120", "1h 55min")
/// into hour/minute display ("2h 22m", "2h", "45m").
enum NuvioRuntimeDisplay {
    static func formatted(_ runtime: String?) -> String? {
        guard let runtime = runtime?.trimmingCharacters(in: .whitespacesAndNewlines),
              !runtime.isEmpty else {
            return nil
        }

        let normalized = runtime.lowercased()
        let hours = firstNumber(in: normalized, pattern: #"(\d+)\s*h"#)
        let minutes = firstNumber(in: normalized, pattern: #"(\d+)\s*m(?:in)?"#)
        let totalMinutes: Int?

        if hours != nil || minutes != nil {
            totalMinutes = (hours ?? 0) * 60 + (minutes ?? 0)
        } else {
            totalMinutes = Int(normalized.filter(\.isNumber))
        }

        guard let totalMinutes, totalMinutes > 0 else {
            return runtime
        }

        let wholeHours = totalMinutes / 60
        let remainingMinutes = totalMinutes % 60

        if wholeHours > 0 && remainingMinutes > 0 {
            return "\(wholeHours)h \(remainingMinutes)m"
        } else if wholeHours > 0 {
            return "\(wholeHours)h"
        } else {
            return "\(remainingMinutes)m"
        }
    }

    private static func firstNumber(in value: String, pattern: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: value,
                range: NSRange(value.startIndex..<value.endIndex, in: value)
              ),
              let range = Range(match.range(at: 1), in: value) else {
            return nil
        }
        return Int(value[range])
    }
}


enum TVLayout {
    static let contentLeading: CGFloat = 10
    /// Shared gutter: every screen starts its content here, clear of the rail.
    static let rowLeading: CGFloat = NavigationRailMetrics.contentLeading
}

extension Color {
    static let tvBackground = Color(red: 0.015, green: 0.015, blue: 0.018)
    static let tvCard = Color(red: 0.105, green: 0.108, blue: 0.115)
    static let tvAccent = Color(red: 0.94, green: 0.13, blue: 0.13)

    /// App body background. AMOLED forces pure black; otherwise the selected
    /// background tint (Settings → Appearance → App Background) is used.
    static func nuvioBackground(amoled: Bool, body: String = SettingsBackground.charcoal.rawValue) -> Color {
        amoled ? .black : SettingsBackground.color(for: body)
    }

    /// Builds a color from a `#RRGGBB` (or `RRGGBB`) hex string. Falls back to
    /// white for malformed input. Used by the subtitle styling swatches/preview.
    init(hex: String) {
        let raw = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        var value: UInt64 = 0xFFFFFF
        Scanner(string: String(raw.prefix(6))).scanHexInt64(&value)
        self.init(
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0
        )
    }
}

extension String {
    /// Inserts a hard line break after every `n` whitespace-separated words, so
    /// long descriptions wrap at a fixed word count (hero + details on tvOS).
    func wrappedEveryNWords(_ n: Int) -> String {
        guard n > 0 else { return self }
        let words = split(whereSeparator: { $0.isWhitespace })
        guard words.count > n else { return self }

        var lines: [String] = []
        var index = 0
        while index < words.count {
            let end = Swift.min(index + n, words.count)
            lines.append(words[index..<end].joined(separator: " "))
            index += n
        }
        return lines.joined(separator: "\n")
    }
}
