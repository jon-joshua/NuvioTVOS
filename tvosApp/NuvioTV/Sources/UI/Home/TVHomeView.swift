import SwiftUI
import Foundation
import UIKit
import ImageIO
import OSLog

private final class TVHomeFocusWork {
    var defersOverlayPreparation = false
    var pendingOverlayRestoreCardID: String?
    /// Remains set until the restored card's actual focus callback runs. The
    /// shared FocusState can be updated before that callback, so it cannot be
    /// used as the restore-in-progress marker by itself.
    var restoringOverlayCardID: String?
    var restoreReleaseTask: Task<Void, Never>?
    var pendingFocusedMeta: NuvioMeta?
    var pendingFocusedFolder: TVCollectionFolderItem?
    var pendingSectionId: String?
    var focusSettleTask: Task<Void, Never>?
    var enrichedHeroMetadata: [String: NuvioMeta] = [:]
    var pendingLandscapeFocusedId: String?
    var landscapeFocusTask: Task<Void, Never>?

    func cancelAll() {
        restoreReleaseTask?.cancel()
        focusSettleTask?.cancel()
        landscapeFocusTask?.cancel()
        restoreReleaseTask = nil
        focusSettleTask = nil
        landscapeFocusTask = nil
        pendingFocusedMeta = nil
        pendingFocusedFolder = nil
        pendingSectionId = nil
        pendingLandscapeFocusedId = nil
        defersOverlayPreparation = false
        pendingOverlayRestoreCardID = nil
        restoringOverlayCardID = nil
    }
}

/// Keeps each row's horizontal position even when that row is outside the
/// materialized vertical window. This deliberately is not observable: the row
/// owns the live `@State`, and the cache is only read when a row is remounted.
private final class TVHomeRowScrollStore {
    private var indices: [String: Int] = [:]

    func index(for sectionId: String) -> Int {
        indices[sectionId] ?? 0
    }

    func setIndex(_ index: Int, for sectionId: String) {
        indices[sectionId] = index
    }

    func removeAll() {
        indices.removeAll()
    }
}

struct TVHomeView: View {
    /// Failure sets a retry already ran against without improving them, keyed by
    /// the signature itself (which encodes the add-on set, so two profiles never
    /// share a verdict). Static because Home is torn down on every profile
    /// switch, and a per-view copy would forget the verdict exactly when the
    /// next entry needs it. A relaunch clears it, giving a genuinely transient
    /// outage a fresh try.
    @MainActor private static var unimprovedHomeFailures: Set<String> = []

    @ObservedObject var store: TVHomeStore
    let repository: CatalogRepository
    let isActive: Bool
    let isFullScreenOverlayPresented: Bool
    let detailsDidDisappearGeneration: UInt
    /// True while a freshly picked profile is being prepared. Keeps Home's own
    /// loader on screen for that whole beat, so the switch shows one screen
    /// instead of a cover handing over to a spinner.
    var isProfileSwitching: Bool = false
    let contentIdentity: TVHomeContentIdentity
    let collectionsRevision: UInt
    var sessionNeedsReauthentication: Bool = false
    let onNavigateToDetails: (String, String) -> Void
    let onOpenCollectionFolder: (TVCollectionFolderItem, String) -> Void
    let onResumePlayback: (ContinueWatchingItem) -> Void
    var onPlayContinueWatchingManually: ((ContinueWatchingItem) -> Void)? = nil
    var onStartContinueWatchingFromBeginning: ((ContinueWatchingItem) -> Void)? = nil
    var onRemoveFromContinueWatching: ((ContinueWatchingItem) -> Void)? = nil
    var onLongPressCard: ((NuvioMeta) -> Void)? = nil
    /// Raised instead of `onLongPressCard` for cards in the Continue Watching
    /// row, which carry resume actions the generic title menu has no use for.
    var onLongPressContinueWatching: ((ContinueWatchingItem) -> Void)? = nil
    /// Asks the account for fresh data when Nuvio Sync owns Continue Watching.
    /// That row is read from the local ledger, so nothing else here would ever
    /// notice a title deleted on another device.
    var onRequestAccountRefresh: () -> Void = {}
    var onRequestReauth: () -> Void = {}

    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue
    @AppStorage(SettingsKey.heroEnabled) private var heroEnabled = true
    @AppStorage(SettingsKey.focusedPosterBackdropEnabled) private var focusedPosterBackdropEnabled = true
    @AppStorage(SettingsKey.focusedPosterBackdropDelay) private var focusedPosterBackdropDelay = 3
    @AppStorage(SettingsKey.hideUnreleased) private var hideUnreleased = false
    @AppStorage(SettingsKey.continueWatchingSort) private var continueWatchingSort = "Default"
    @AppStorage(SettingsKey.upNextFromFurthestEpisode) private var upNextFromFurthestEpisode = true
    @AppStorage(SettingsKey.showUnairedNextUp) private var showUnairedNextUp = true
    @AppStorage(SettingsKey.posterLabels) private var posterLabels = false
    @AppStorage(SettingsKey.tmdbEnabled) private var tmdbEnabled = false
    @AppStorage(SettingsKey.tmdbLanguage) private var tmdbLanguage = "en"
    @AppStorage(SettingsKey.tmdbUseArtwork) private var tmdbUseArtwork = true
    @AppStorage(SettingsKey.tmdbUseBasicInfo) private var tmdbUseBasicInfo = true
    @AppStorage(SettingsKey.smbLocalRowEnabled) private var smbLocalRowEnabled = true
    @AppStorage(SettingsKey.jellyfinLocalRowEnabled) private var jellyfinLocalRowEnabled = true

    @State private var isBannerDismissed = false

    @State private var localTitlesSection: TVHomeSection?
    @State private var jellyfinSection: TVHomeSection?
    @State private var isLoading = true
    @State private var focusedMeta: NuvioMeta?
    /// Collection folder currently focused on Home. When set, the hero shows
    /// emoji + folder title instead of title poster meta/description.
    @State private var focusedCollectionFolder: TVCollectionFolderItem?
    /// Row the settled focus lives in; the hero only shows Continue Watching
    /// context (episode line, time left) for cards focused in that row.
    @State private var focusedSectionId: String?
    @State private var landscapeFocusedId: String?
    @State private var focusWork = TVHomeFocusWork()
    @State private var rowScrollStore = TVHomeRowScrollStore()
    /// Bumped when the rail opens; rows watch it and snap back to their first card.
    @State private var rowResetGeneration = 0
    @State private var homeReloadTask: Task<Void, Never>?
    /// Add-on/catalog settings the last completed load actually read.
    @State private var lastLoadedInputSignature: String?
    @State private var rawContinueWatchingItems: [ContinueWatchingItem] = []
    @State private var continueWatching: [ContinueWatchingItem] = []
    @State private var upcomingItems: [ContinueWatchingItem] = []
    /// Derived once when Continue Watching changes. Recomputing these from the
    /// entire history inside `body` made every focus update scale with the
    /// number of loaded progress items.
    @State private var continueWatchingMetas: [NuvioMeta] = []
    @State private var upcomingMetas: [NuvioMeta] = []
    @State private var continueWatchingByMetaId: [String: ContinueWatchingItem] = [:]
    @State private var continueWatchingIndexByMetaId: [String: Int] = [:]
    @State private var continueWatchingIDs: [String] = []
    @State private var displayedProgressSource: TraktWatchProgressSource?
    @State private var continueWatchingRefreshGeneration = 0
    @State private var continueWatchingRefreshTask: Task<Void, Never>?
    @State private var simklLoadingDebugInfo: String?
    @State private var simklLoadingTimeoutTask: Task<Void, Never>?
    @State private var simklLoadingStartedAt: Date?
    @State private var isLoadingMoreContinueWatching = false
    /// Rows the current load still owes, rendered as spinner skeletons until
    /// their catalog answers. Empty whenever no load is in flight.
    @State private var homeLoadingPlaceholders: [TVHomeSection] = []
    @State private var watchedTitleKeys: Set<String> = []
    @State private var errorMessage: String?
    @State private var didRequestInitialCardFocus = false
    @State private var didPrepareInitialFocusViewport = false
    @State private var pendingInitialFocusCardKey: String?
    @State private var shouldRestoreHomeFocus = false
    /// Memo for the Hide Unreleased pass over add-on rows. Filtering allocates a
    /// fresh items buffer per row, which defeats the buffer-identity fast path in
    /// `HomePosterRow.==` and turns every focus update into a field-by-field
    /// compare of every title on Home. Reuse the last result while the store's
    /// sections and the calendar day are unchanged.
    @State private var unreleasedFilterMemo = UnreleasedSectionFilterMemo()

    private final class UnreleasedSectionFilterMemo {
        private var revision: Int?
        private var today: String?
        private var sections: [TVHomeSection] = []

        func filtered(
            _ input: [TVHomeSection],
            revision: Int,
            today: String,
            transform: (TVHomeSection) -> TVHomeSection
        ) -> [TVHomeSection] {
            if self.revision == revision, self.today == today {
                return sections
            }
            let result = input.map(transform)
            self.revision = revision
            self.today = today
            sections = result
            return result
        }
    }
    /// Keeps the one externally bound card structurally unchanged while focus
    /// crosses between Home and the adaptive sidebar. This does not request
    /// focus; it only prevents removing/re-adding `.focused` around the artwork.
    @State private var retainedFocusBindingCardID: String?
    /// Card to actively re-focus once the Details/Player overlay dismisses.
    /// Captured when the tab view gets disabled (overlay up), consumed when it
    /// is re-enabled. See `restoreOverlayFocus`.
    @State private var overlayRestoreCardID: String?
    /// Increments for every overlay presentation. Delayed focus callbacks from
    /// an older Details/Player return must never clear the next return's focus
    /// lock when the user opens the same card twice in quick succession.
    @State private var overlayRestoreGeneration = 0
    /// Row order as of the last render, so a card that leaves Continue Watching
    /// can be traced back to the slot it occupied. See the retarget below.
    @State private var continueWatchingCardIDs: [String] = []
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.navigationRailShift) private var railShift
    @State private var focusedRowIndex = 0
    /// The Grid hero owns its own focus state, so `focusedCardID` goes nil while
    /// it is focused. Home still holds focus then, and arming the focus restore
    /// there would let `defaultFocus` reclaim focus the moment Menu tries to
    /// hand it to the sidebar.
    /// Suppress the one focus/layout animation caused by returning to Home from
    /// another tab. Normal left/right focus animations remain enabled.
    @State private var suppressReturnFocusAnimations = false
    @State private var returnFocusAnimationGeneration = 0

    private var tmdbHomeSettingsKey: String {
        "\(tmdbEnabled)|\(tmdbLanguage)|\(tmdbUseArtwork)|\(tmdbUseBasicInfo)"
    }
    @FocusState private var isLoadingFocusActive: Bool
    @FocusState private var focusedCardID: String?

    var body: some View {
        let _ = TVHomeDebugTrace.log("home.body.render active=\(isActive) isEnabled=\(isEnabled)")
        withFocusHandlers(withLifecycleHandlers(withSettingsHandlers(withLoadHandlers(homeContent))))
    }

    // MARK: - Body modifier groups
    //
    // `body` used to be one ~700-line expression (layout + 28 handler
    // closures); Swift 6.3's type-checker refuses it. Each group below is
    // type-checked on its own. They are methods rather than ViewModifiers so
    // they keep access to the view's private state.

    private func withLoadHandlers<Content: View>(_ content: Content) -> some View {
        content
        .task(id: "\(contentIdentity.profileId):\(contentIdentity.catalogRevision):\(tmdbHomeSettingsKey)") {
            await loadWithAutomaticRetry(for: contentIdentity, forceReload: true)
            // Add-on metadata providers are configured by the time Home has
            // loaded, so this is the pass that recovers titles an earlier sync
            // could not resolve. Mirrors the phone's
            // `retryMetadataResolutionWhenAddonMetaProvidersReady`.
            await ContinueWatchingBuilder.rebuild(reason: "home loaded")
            await ContinueWatchingStore.refreshMissingEpisodeDetails()
        }
        .task(id: "\(contentIdentity.profileId):\(collectionsRevision)") {
            await refreshCollectionSections(for: contentIdentity)
        }
        .task(id: "\(contentIdentity.profileId):smbLocalTitles:\(smbLocalRowEnabled)") {
            await loadLocalTitlesSection()
        }
        .onReceive(NotificationCenter.default.publisher(for: SMBLibraryIndex.changedNotification)) { _ in
            guard isActive else { return }
            Task { await loadLocalTitlesSection() }
        }
        .task(id: "\(contentIdentity.profileId):jellyfinTitles:\(jellyfinLocalRowEnabled)") {
            await loadJellyfinSection()
        }
        .onReceive(NotificationCenter.default.publisher(for: JellyfinLibraryIndex.changedNotification)) { _ in
            guard isActive else { return }
            Task { await loadJellyfinSection() }
        }
        .onAppear {
            // A TabView may recreate Home instead of keeping it mounted. Arm
            // before its saved focus is restored so the first layout pass is
            // already non-animated.
            if isActive, store.lastFocusedCardID != nil {
                armReturnFocusAnimationSuppression()
            }
            // Classic was never a distinct layout; collapse legacy values to Modern.
            refreshContinueWatching()
            refreshWatchedTitles()
            scheduleContinueWatchingRefresh()
        }
        // Home stays mounted behind Details/Player, so `onAppear` no longer
        // fires on return. Refresh the Continue Watching row whenever the store
        // changes (progress saved during playback, item finished/removed).
        .onReceive(NotificationCenter.default.publisher(for: ContinueWatchingStore.changedNotification).receive(on: RunLoop.main)) { _ in
            guard isActive else { return }
            refreshContinueWatching()
        }
        // A removal has to leave the row immediately, including under Trakt/Simkl
        // where the displayed list belongs to the provider and only changes on
        // the next fetch.
        .onReceive(NotificationCenter.default.publisher(for: ContinueWatchingDismissStore.changedNotification).receive(on: RunLoop.main)) { _ in
            guard isActive else { return }
            let all = continueWatching + upcomingItems
            let remaining = all.filter { !ContinueWatchingDismissStore.isDismissed($0) }
            if remaining.count != all.count {
                setContinueWatching(remaining)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: TraktAuthStore.changedNotification).receive(on: RunLoop.main)) { _ in
            guard isActive else { return }
            scheduleContinueWatchingRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: TraktSettingsStore.continueWatchingChangedNotification).receive(on: RunLoop.main)) { _ in
            guard isActive else { return }
            scheduleContinueWatchingRefresh()
        }
    }

    private func withSettingsHandlers<Content: View>(_ content: Content) -> some View {
        content
        // TabView can keep Home mounted while Settings is selected, so returning
        // to Home does not reliably produce another onAppear.
        .onChange(of: isActive) { _, active in
            if active {
                // A tab switch can also toggle the environment's `isEnabled`.
                // That is not an overlay dismissal, so discard any focus lock
                // accidentally captured while Home was becoming inactive.
                if overlayRestoreCardID != nil {
                    overlayRestoreGeneration &+= 1
                    overlayRestoreCardID = nil
                }
                // Usually armed while leaving Home. Re-arm here as a fallback
                // for TabView implementations that recreate the selected tab.
                if !suppressReturnFocusAnimations {
                    armReturnFocusAnimationSuppression()
                }
                if focusedCardID != nil {
                    releaseReturnFocusAnimationSuppression()
                }
                if !rawContinueWatchingItems.isEmpty {
                    setContinueWatching(rawContinueWatchingItems)
                }
                if usesRemoteProgress {
                    scheduleContinueWatchingRefresh()
                } else {
                    refreshContinueWatching()
                }
                #if DEBUG
                logRowWindow("home became active")
                #endif
            } else {
                // Details and Player leave Home selected; a real tab change
                // must never carry their one-card restoration lock back Home.
                overlayRestoreGeneration &+= 1
                overlayRestoreCardID = nil
                // Android disposes Home's composition on a tab switch, which
                // cancels screen-scoped work. Mirror that cancellation while
                // keeping the shared Home store warm for the next entry.
                continueWatchingRefreshTask?.cancel()
                continueWatchingRefreshTask = nil
                continueWatchingRefreshGeneration &+= 1
                // A real tab switch can destroy the conditional Home tree
                // before LazyVStack gets another appearance callback. Keep
                // the saved target and let the next activation seed its
                // distant row/scroll position again.
                pendingInitialFocusCardKey = store.lastFocusedCardID
                didRequestInitialCardFocus = false
                didPrepareInitialFocusViewport = false
                // Arm before tvOS removes card focus. Waiting until Home becomes
                // active again is too late: focus restoration has already begun.
                armReturnFocusAnimationSuppression()
            }
        }
        .onChange(of: continueWatchingSort) { _, _ in
            if !rawContinueWatchingItems.isEmpty {
                setContinueWatching(rawContinueWatchingItems)
            }
            if usesRemoteProgress {
                scheduleContinueWatchingRefresh()
            } else {
                refreshContinueWatching()
            }
        }
        .onChange(of: hideUnreleased) { _, _ in
            if usesRemoteProgress {
                scheduleContinueWatchingRefresh()
            } else {
                refreshContinueWatching()
            }
        }
        .onChange(of: showUnairedNextUp) { _, _ in
            // Local Next Up cards are derived from the episode guide, so the
            // preference must rebuild that row rather than merely re-sort the
            // already materialized cards. Remote rows need a fresh fetch because
            // previously hidden upcoming cards are no longer in view state.
            if usesRemoteProgress {
                scheduleContinueWatchingRefresh()
            } else {
                Task { @MainActor in
                    await ContinueWatchingBuilder.rebuild(reason: "unaired preference changed")
                    refreshContinueWatching()
                }
            }
        }
        .onChange(of: upNextFromFurthestEpisode) { _, _ in
            if usesRemoteProgress {
                scheduleContinueWatchingRefresh()
            } else {
                Task { @MainActor in
                    await ContinueWatchingBuilder.rebuild(reason: "up next episode preference changed")
                    refreshContinueWatching()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: WatchedStore.changedNotification)) { _ in
            guard isActive else { return }
            refreshWatchedTitles()
            // A watched mark can be the only history left for a completed
            // series. Rebuild the local row so a newly aired episode can seed a
            // fresh "Airs Today" card even after the old row was retired.
            if !usesRemoteProgress {
                ContinueWatchingBuilder.scheduleRebuild(reason: "watched state changed")
            }
        }
    }

    private func withLifecycleHandlers<Content: View>(_ content: Content) -> some View {
        content
        // Settings → Home Catalogs reorder applies to the mounted Home live.
        .onReceive(NotificationCenter.default.publisher(for: TVHomeCatalogOrder.changedNotification)) { _ in
            guard isActive else { return }
            let reordered = homeOrderedSections(store.sections)
            if reordered.map(\.id) != store.sections.map(\.id) {
                store.sections = reordered
            }
        }
        // Individual revision changes can arrive while the initial physical-
        // device load is still in flight. Once account sync confirms that all
        // Home inputs have landed, queue one replacement load from that final
        // add-on and catalog-settings snapshot.
        .onReceive(NotificationCenter.default.publisher(for: NuvioSyncManager.homeContentSyncedNotification)) { _ in
            guard isActive && !isFullScreenOverlayPresented else { return }
            homeReloadTask?.cancel()
            let identity = contentIdentity
            homeReloadTask = Task { @MainActor in
                await reloadHomeAfterSyncedInputs(for: identity)
            }
        }
        .onDisappear {
            focusWork.cancelAll()
            homeReloadTask?.cancel()
            continueWatchingRefreshTask?.cancel()
            continueWatchingRefreshTask = nil
            finishSimklHomeLoadingDiagnostic()
            continueWatchingRefreshGeneration &+= 1
        }
        .onChange(of: isLoading) { _, loading in
            if loading {
                requestLoadingFocus()
            }
        }
        .onChange(of: focusedPosterBackdropEnabled) { _, enabled in
            guard !enabled else { return }
            focusWork.pendingLandscapeFocusedId = nil
            focusWork.landscapeFocusTask?.cancel()
            landscapeFocusedId = nil
        }
    }

    private func withFocusHandlers<Content: View>(_ content: Content) -> some View {
        content
        .onChange(of: focusedCardID) { _, newValue in
            if let newValue {
                if let pendingInitialFocusCardKey {
                    guard pendingInitialFocusCardKey == newValue else { return }
                    self.pendingInitialFocusCardKey = nil
                } else if !didPrepareInitialFocusViewport,
                          let saved = store.lastFocusedCardID,
                          saved != newValue
                {
                    pendingInitialFocusCardKey = saved
                    return
                }
                store.lastFocusedCardID = newValue
                // `@State` invalidates on every write, even to an equal value,
                // and this runs on every focus move.
                if shouldRestoreHomeFocus { shouldRestoreHomeFocus = false }
                if isActive {
                    releaseReturnFocusAnimationSuppression()
                }
                if isEnabled,
                   newValue == overlayRestoreCardID,
                   focusWork.restoringOverlayCardID != newValue {
                    overlayRestoreCardID = nil
                }
            } else if !focusWork.defersOverlayPreparation,
                      store.lastFocusedCardID != nil {
                shouldRestoreHomeFocus = true
            }
        }
        // Visible menus still toggle Home's disabled environment. Full-screen
        // overlays do not: their opacity-zero Home tree is already unfocusable,
        // and handling the overlay transition directly avoids invalidating all
        // resident shelves on Details entry.
        .onChange(of: isEnabled) { _, enabled in
            TVHomeDebugTrace.log(
                "home.overlay.isEnabled changed to \(enabled) active=\(isActive) defersPrep=\(focusWork.defersOverlayPreparation)"
            )
            // Full-screen transitions have their own handler below. This one
            // remains for the visible card-menu path and inactive TabView tabs.
            guard !isFullScreenOverlayPresented else { return }
            handleHomeOverlayStateChange(isPresented: !enabled)
        }
        .onChange(of: isFullScreenOverlayPresented) { _, presented in
            TVHomeDebugTrace.log(
                "home.overlay.fullScreen changed to \(presented) active=\(isActive) defersPrep=\(focusWork.defersOverlayPreparation)"
            )
            handleHomeOverlayStateChange(isPresented: presented)
        }
        .onChange(of: detailsDidDisappearGeneration) { _, generation in
            guard !isFullScreenOverlayPresented else { return }
            guard let target = overlayRestoreCardID,
                  focusWork.restoringOverlayCardID == target else { return }
            TVHomeDebugTrace.log(
                "home.details.disappeared generation=\(generation) restoring target=\(target)"
            )
            // Details is now out of the hierarchy, so this is the first focus
            // request that tvOS can actually commit. The card's focus callback
            // will release the one-card lock on the next run-loop turn.
            focusedCardID = target
        }
        // Removing a card takes the focus capture with it: the restore target
        // still names the card that just left, and because every other card is
        // unfocusable while a capture stands, focus lands nowhere at all. Hand
        // the slot to whatever moved into it instead.
        .onChange(of: continueWatchingIDs) { _, ids in
            let previous = continueWatchingCardIDs
            continueWatchingCardIDs = ids
            guard let target = overlayRestoreCardID,
                  let removedID = continueWatchingMetaID(inCardKey: target),
                  !ids.contains(removedID),
                  let removedIndex = previous.firstIndex(of: removedID) else { return }

            // Invalidates the in-flight restores aimed at the removed card:
            // they only write focus while their own generation is current.
            overlayRestoreGeneration &+= 1
            guard !ids.isEmpty else {
                // Row is gone entirely. Drop the capture so the engine can place
                // focus itself rather than leaving every card disabled behind a
                // target that will never exist.
                overlayRestoreCardID = nil
                return
            }
            // The card that shifted into the slot, or the new last card when the
            // removed one was at the end.
            let successorID = ids[min(removedIndex, ids.count - 1)]
            let sectionPrefix = target.hasPrefix("\(TVHomeSection.upcomingId)\u{1}")
                ? TVHomeSection.upcomingId
                : TVHomeSection.continueWatchingId
            let successorKey = "\(sectionPrefix)\u{1}\(successorID)"
            overlayRestoreCardID = successorKey
            store.lastFocusedCardID = successorKey
            restoreOverlayFocus(to: successorKey, generation: overlayRestoreGeneration)
        }
    }

    /// The Home layout tree, kept out of `body` so the layout and the
    /// 28-handler modifier chain are not one expression: the Swift 6.3
    /// type-checker gives up on the combined ~700-line version.
    private var homeContent: some View {
        ZStack(alignment: .topLeading) {
            // Match Android's AppTabHost ownership: only the selected tab owns
            // a Home render tree. TVHomeStore and this view's @State preserve
            // data/position, while image, focus, and row subtrees are released
            if isActive {
            // 1. Bottom Layer: Full Screen Crossfading Backdrop
            // Collection folder heroes: top-trailing crop (Android TopEnd) so
            // portrait hero art isn't center-cropped with the subject too high.
            CrossfadingBackdrop(
                // Android Grid Home owns a contained 400pt hero backdrop. Keep
                // the full-screen backdrop for Modern/Compact only.
                //
                // While loading there is deliberately no artwork: during a
                // profile switch the backdrop still holds the previous profile's
                // hero, and showing a spinner over someone else's content is the
                // opposite of a clean handover.
                url: showsLoading ? nil : homeBackdropURL,
                placeholder: Color.nuvioBackground(amoled: amoled, body: bodyColor),
                alignment: focusedCollectionFolder != nil ? .topTrailing : .center
            )
            .equatable()
            .ignoresSafeArea()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Hold the backdrop still while the rail slides the page (see
            // navigationRailShift); only the content should move.
            .offset(x: -railShift)
            .animation(NuvioMotion.drawer, value: railShift)
            
            // 2. Gradients overlay for backdrop blending and readability.
            // Uses the selected body background color (not pure black) so the
            // chosen theme tint is visible behind the hero on the home screen.
            let backdropColor = Color.nuvioBackground(amoled: amoled, body: bodyColor)
            GeometryReader { proxy in
                LinearGradient(
                    stops: [
                        .init(color: backdropColor.opacity(0.94), location: 0),
                        .init(color: backdropColor.opacity(0.84), location: 0.22),
                        .init(color: backdropColor.opacity(0.52), location: 0.46),
                        .init(color: backdropColor.opacity(0.14), location: 0.76),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: proxy.size.width * 0.58)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            .ignoresSafeArea()
            .offset(x: -railShift)
            .animation(NuvioMotion.drawer, value: railShift)

            GeometryReader { proxy in
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: backdropColor.opacity(0.20), location: 0.42),
                            .init(color: backdropColor.opacity(0.58), location: 0.78),
                            .init(color: backdropColor, location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: proxy.size.height * 0.40)
                }
            }
            .ignoresSafeArea()
            .offset(x: -railShift)
            .animation(NuvioMotion.drawer, value: railShift)
            .animation(NuvioMotion.drawer, value: railShift)

            // 3. Scrollable catalog rows overlay, with pinned Hero at the top
            VStack(alignment: .leading, spacing: 0) {
                if showsLoading {
                    TVLoadingView()
                        .overlay {
                            Color.clear
                                .frame(width: 1, height: 1)
                                .focusable(true)
                                .focused($isLoadingFocusActive)
                        }
                        // Match Settings: make the content a focus section with
                        // an explicit default target during the initial focus
                        // pass. The async write below remains a fallback.
                        .focusSection()
                        .defaultFocusIfAvailable($isLoadingFocusActive, true)
                        .onAppear {
                            requestLoadingFocus()
                        }
                } else if let errorMessage, store.sections.isEmpty && continueWatching.isEmpty {
                    TVErrorView(message: errorMessage) {
                        homeReloadTask?.cancel()
                        homeReloadTask = Task { @MainActor in
                            await loadWithAutomaticRetry(for: contentIdentity)
                        }
                    }
                } else {
                    // Header Hero Meta block (static, outside the rows). Folder
                    // focus swaps poster meta for emoji + folder title (browse-style).
                    if heroEnabled {
                        if let folder = focusedCollectionFolder {
                            TVCollectionFolderHeroView(folder: folder)
                        } else if let heroMeta = visibleFocusedMeta ?? visibleHero {
                            TVHeroView(meta: heroMeta, continueItem: heroContinueItem(for: heroMeta)) {
                                navigateToDetailsFromHome(id: heroMeta.id, type: heroMeta.type)
                            }
                            .equatable()
                        }
                    }
                    
                    // Android uses a LazyColumn of LazyRows: only viewport rows
                    // and cards own render work. Keep the vertical Home strip
                    // lazy as well; rows retain their horizontal position in
                    // `rowScrollStore` while focused-row shells preserve focus.
                    GeometryReader { proxy in
                        let sections = visibleSections.filter(\.hasContent)
                        let horizontalEdgeInset = max(
                            0,
                            (UIScreen.main.bounds.width - proxy.size.width) / 2
                        )
                            // Native lazy vertical scrolling for the rows. The
                            // focused row ±2 window controls real card/artwork
                            // materialization; lazy mounting limits row work
                            // outside the viewport without changing row geometry.
                            ScrollViewReader { verticalScrollProxy in
                                ScrollView(.vertical, showsIndicators: false) {
                                    LazyVStack(alignment: .leading, spacing: TVHomeLayout.sectionSpacing) {
                                        if sessionNeedsReauthentication && !isBannerDismissed {
                                            TVReauthBannerView(
                                                onSignIn: onRequestReauth,
                                                onDismiss: {
                                                    withAnimation(.easeInOut(duration: 0.2)) {
                                                        isBannerDismissed = true
                                                    }
                                                }
                                            )
                                            .padding(.horizontal, horizontalEdgeInset)
                                        }

                                        ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                                        if section.isLoadingPlaceholder {
                                            TVLoadingCatalogRow(title: section.title)
                                                .frame(
                                                    height: estimatedHeight(for: section),
                                                    alignment: .topLeading
                                                )
                                        } else if !section.collectionFolders.isEmpty {
                                            TVCollectionFolderRow(
                                                id: section.id,
                                                title: section.title,
                                                horizontalEdgeInset: horizontalEdgeInset,
                                                folders: section.collectionFolders,
                                                initialScrollIndex: rowScrollStore.index(for: section.id),
resetGeneration: rowResetGeneration,
                                                onScrollIndexChange: { newIndex in
                                                    rowScrollStore.setIndex(newIndex, for: section.id)
                                                },
                                                initialFocusCardKey: initialFocusCardKey,
                                                externalFocus: $focusedCardID,
                                                restrictFocusToCardKey: overlayRestoreCardID,
                                                retainFocusAppearanceForCardKey: overlayRestoreCardID,
                                                suppressFocusAnimations: suppressReturnFocusAnimations
                                                    && focusedRowIndex == index,
                                                isRowFocused: focusedRowIndex == index,
                                                onInitialFocusRequested: {
                                                    didRequestInitialCardFocus = true
                                                },
                                                onFocus: { folder in
                                                    let cardKey = "\(section.id)\u{1}\(folder.id)"
                                                    if focusWork.restoringOverlayCardID == cardKey {
                                                        completeOverlayFocusRestore(for: cardKey)
                                                    }
                                                    let changedRow = focusedRowIndex != index
                                                    // Only a row change needs a vertical scroll. A
                                                    // horizontal move within the row used to issue a
                                                    // no-animation scrollTo as well, which forced the
                                                    // outer ScrollView to re-resolve on every press.
                                                    if changedRow {
                                                        focusedRowIndex = index
                                                        withAnimation(TVHomeLayout.verticalScrollAnimation) {
                                                            verticalScrollProxy.scrollTo(section.id, anchor: .top)
                                                        }
                                                    }
                                                    focusedCardID = cardKey
                                                    settleFolderFocus(folder, in: section.id)
                                                },
                                                onSelect: { folder in
                                                    overlayRestoreCardID = "\(section.id)\u{1}\(folder.id)"
                                                    onOpenCollectionFolder(folder, section.title)
                                                }
                                            )
                                            .equatable()
                                            .id(section.id)
                                         } else {
                                            HomePosterRow(
                                                id: section.id,
                                                title: section.title,
                                                horizontalEdgeInset: horizontalEdgeInset,
                                                items: section.items,
                                                progressByItemId: (section.id == TVHomeSection.continueWatchingId || section.id == TVHomeSection.upcomingId)
                                                    ? continueWatchingByMetaId : [:],
                                                watchedTitleKeys: watchedTitleKeys,
                                                initialScrollIndex: rowScrollStore.index(for: section.id),
resetGeneration: rowResetGeneration,
                                                onScrollIndexChange: { newIndex in
                                                    rowScrollStore.setIndex(newIndex, for: section.id)
                                                },
                                                initialFocusCardKey: initialFocusCardKey,
                                                landscapeFocusedId: landscapeFocusedId(for: section.id),
                                                externalFocus: $focusedCardID,
                                                restrictFocusToCardKey: overlayRestoreCardID,
                                                retainFocusAppearanceForCardKey: overlayRestoreCardID,
                                                suppressFocusAnimations: suppressReturnFocusAnimations
                                                    && focusedRowIndex == index,
                                                isRowFocused: focusedRowIndex == index,
                                                onInitialFocusRequested: {
                                                    didRequestInitialCardFocus = true
                                                },
                                                onFocus: { meta in
                                                    let focusStarted = TVHomeDebugTrace.now()
                                                    let cardKey = "\(section.id)\u{1}\(meta.id)"
                                                    let changedRow = focusedRowIndex != index
                                                    TVHomeDebugTrace.log(
                                                        "home.focus.begin section=\(section.id) meta=\(meta.id) "
                                                            + "changedRow=\(changedRow) fromRow=\(focusedRowIndex) toRow=\(index)"
                                                    )
                                                    if focusWork.restoringOverlayCardID == cardKey {
                                                        completeOverlayFocusRestore(for: cardKey)
                                                    }
                                                    // Only a row change needs a vertical scroll; see the
                                                    // folder-row handler above for why the horizontal
                                                    // case no longer calls scrollTo.
                                                    if changedRow {
                                                        focusedRowIndex = index
                                                        TVHomeDebugTrace.log(
                                                            "home.scrollTo section=\(section.id) anchor=top"
                                                        )
                                                        withAnimation(TVHomeLayout.verticalScrollAnimation) {
                                                            verticalScrollProxy.scrollTo(section.id, anchor: .top)
                                                        }
                                                    }
                                                    focusedCardID = cardKey
                                                    settleCatalogFocus(on: meta, in: section.id)
                                                    scheduleLandscapeFocus(cardKey: cardKey)
                                                    TVHomeDebugTrace.log(
                                                        "home.focus.end section=\(section.id) meta=\(meta.id) "
                                                            + "ms=\(TVHomeDebugTrace.elapsedMilliseconds(since: focusStarted))"
                                                    )
                                                },
                                                onBlur: { meta in
                                                    clearLandscapeFocus(cardKey: "\(section.id)\u{1}\(meta.id)")
                                                },
                                                onApproachEnd: { meta in
                                                    loadMoreSectionIfNeeded(
                                                        sectionId: section.id, currentItem: meta)
                                                },
                                                onSelect: { meta in
                                                    if (section.id == TVHomeSection.continueWatchingId || section.id == TVHomeSection.upcomingId),
                                                        let item = continueWatchingByMetaId[meta.id]
                                                    {
                                                        if item.isUpNextEntry && !item.hasAired && !item.isAiringToday {
                                                            let cardKey = "\(section.id)\u{1}\(meta.id)"
                                                            navigateToDetailsFromHome(
                                                                id: meta.id,
                                                                type: meta.type,
                                                                restoreCardID: cardKey
                                                            )
                                                        } else {
                                                            onResumePlayback(item)
                                                        }
                                                    } else {
                                                        let cardKey = "\(section.id)\u{1}\(meta.id)"
                                                        navigateToDetailsFromHome(
                                                            id: meta.id,
                                                            type: meta.type,
                                                            restoreCardID: cardKey
                                                        )
                                                    }
                                                },
                                                onLongPress: longPressHandler(for: section.id),
                                                onOpenDetails: { meta in
                                                    let cardKey = "\(section.id)\u{1}\(meta.id)"
                                                    navigateToDetailsFromHome(
                                                        id: meta.id,
                                                        type: meta.type,
                                                        restoreCardID: cardKey
                                                    )
                                                },
                                                onPlayContinueWatchingManually: onPlayContinueWatchingManually,
                                                onStartContinueWatchingFromBeginning: onStartContinueWatchingFromBeginning,
                                                onRemoveFromContinueWatching: onRemoveFromContinueWatching
                                            )
                                            .equatable()
                                            .id(section.id)
                                        }  // end catalog vs collection branch
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, TVHomeLayout.rowsTopPadding)
                                    .padding(.bottom, 80)
                                    .onAppear {
                                        prepareInitialFocusViewport(
                                            for: sections,
                                            using: verticalScrollProxy
                                        )
                                    }
                                    .onChange(of: initialFocusContentSignature) { _, _ in
                                        prepareInitialFocusViewport(
                                            for: sections,
                                            using: verticalScrollProxy
                                        )
                                    }

                                    // The final row otherwise hits the
                                    // ScrollView's bottom limit before it can
                                    // reach the same fixed position as the
                                    // preceding rows. Keep a full viewport of
                                    // non-focusable runway, plus the 24pt
                                    // design inset, after the last catalog.
                                    Color.clear
                                        .frame(height: proxy.size.height + TVHomeLayout.finalRowScrollRunway)
                                        .accessibilityHidden(true)
                                }
                                .onChange(of: railShift) { _, shift in
                                    if shift > 0 { resetRowsForRail(using: verticalScrollProxy) }
                                }
                            }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    // Treat the rows as a focus section so focus can jump in/out
                    // cleanly. The default focus is only armed after Home loses
                    // focus, so the first Menu press can still reach the sidebar,
                    // while returning from the sidebar restores the saved card.
                    .focusSection()
                    .defaultFocusIfAvailable($focusedCardID, store.lastFocusedCardID ?? focusWork.pendingOverlayRestoreCardID)
                }
            }
            // Ignore the bottom safe-area inset too, so the scrolling rows window
            // runs to the screen's bottom edge instead of stopping short and
            // leaving a black bar below the lowest visible row.
            .ignoresSafeArea(.container, edges: [.top, .bottom])

            }

            if let report = simklLoadingDebugInfo, !report.isEmpty {
                SimklHomeLoadingDebugReport(report: report)
                    .frame(maxWidth: 920)
                    .padding(.horizontal, 48)
                    .padding(.top, 48)
                    .zIndex(20)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Opening the rail resets Home, Plex-style: every row back to its first
    /// card and the list back to the top, animated, so the left edge is clean.
    private func resetRowsForRail(using proxy: ScrollViewProxy) {
        rowResetGeneration += 1
        rowScrollStore.removeAll()
        guard let first = visibleSections.first(where: \.hasContent)?.id else { return }
        withAnimation(NuvioMotion.settle) { proxy.scrollTo(first, anchor: .top) }
    }

    /// - Parameter heroBleed: Horizontal safe-area inset this grid sits inside.
    ///   The scroll view gives it back so the hero backdrop runs to the physical
    ///   screen edges; every row below re-applies it so the posters keep the
    ///   gutter the rest of Home uses.
    @ViewBuilder

    /// Nudges focus back to `target` after an overlay dismissal, in case the
    /// engine parked focus outside the rows (hero, sidebar) while the tab view
    /// was still fading in. Two attempts because cards are unfocusable at
    /// near-zero opacity; the trailing clear lifts the card restriction even
    /// if the saved card no longer exists (e.g. Continue Watching reordered),
    /// so the rows can never be left permanently unfocusable.
    /// The meta id inside a Continue Watching or Upcoming card key, or nil for any other row.
    private func continueWatchingMetaID(inCardKey key: String) -> String? {
        let cwPrefix = "\(TVHomeSection.continueWatchingId)\u{1}"
        if key.hasPrefix(cwPrefix) {
            return String(key.dropFirst(cwPrefix.count))
        }
        let upPrefix = "\(TVHomeSection.upcomingId)\u{1}"
        if key.hasPrefix(upPrefix) {
            return String(key.dropFirst(upPrefix.count))
        }
        return nil
    }

    /// Handles focus capture for both visible menus and full-screen overlays.
    /// Full-screen presentation intentionally does not toggle Home's disabled
    /// environment, so this transition hook replaces the old Details-specific
    /// `isEnabled` callback without rebuilding every resident shelf.
    private func handleHomeOverlayStateChange(isPresented: Bool) {
        // TabView may disable an unselected Home tab. Only overlay restoration
        // while Home remains selected should touch the saved focus target.
        guard isActive else {
            overlayRestoreGeneration &+= 1
            overlayRestoreCardID = nil
            return
        }

        if isPresented {
            // Direct Home → Details navigation already captured the target in
            // reference storage. Avoid publishing the one-card lock now; doing
            // so would rebuild every resident shelf before Details can draw.
            if focusWork.defersOverlayPreparation {
                TVHomeDebugTrace.log("home.overlay.presentation deferring preparation")
                focusWork.landscapeFocusTask?.cancel()
                focusWork.pendingLandscapeFocusedId = nil
                focusWork.focusSettleTask?.cancel()
                return
            }

            // For visible menus and non-Home overlay entry, capture the target
            // before focus is removed so the return path cannot jump to the
            // first card.
            armReturnFocusAnimationSuppression()
            overlayRestoreGeneration &+= 1
            let target = focusedCardID ?? store.lastFocusedCardID
            TVHomeDebugTrace.log("home.overlay.presentation setting target=\(target ?? "nil")")
            overlayRestoreCardID = target
        } else if focusWork.defersOverlayPreparation {
            let target = focusWork.pendingOverlayRestoreCardID
            focusWork.defersOverlayPreparation = false
            focusWork.pendingOverlayRestoreCardID = nil
            guard let target else {
                TVHomeDebugTrace.log("home.overlay.dismissal defersPrep with nil target")
                return
            }

            // Build the restriction only on return. Details is no longer
            // competing with this Home render, and delayed focus writes run
            // after the target modifier is mounted.
            armReturnFocusAnimationSuppression()
            overlayRestoreGeneration &+= 1
            TVHomeDebugTrace.log("home.overlay.dismissal restoring to target=\(target) gen=\(overlayRestoreGeneration)")
            overlayRestoreCardID = target
            restoreOverlayFocus(
                to: target,
                generation: overlayRestoreGeneration,
                waitForDetailsDisappearance: true
            )
        } else if let target = overlayRestoreCardID {
            TVHomeDebugTrace.log("home.overlay.dismissal fallback restoring to target=\(target) gen=\(overlayRestoreGeneration)")
            restoreOverlayFocus(to: target, generation: overlayRestoreGeneration)
        }
    }

    private func restoreOverlayFocus(
        to target: String,
        generation: Int,
        waitForDetailsDisappearance: Bool = false
    ) {
        TVHomeDebugTrace.log(
            "home.restoreOverlayFocus begin target=\(target) gen=\(generation) "
                + "waitForDetailsDisappearance=\(waitForDetailsDisappearance)"
        )
        focusWork.restoringOverlayCardID = target

        if waitForDetailsDisappearance {
            // The Details view is still mounted at this point. Its actual
            // onDisappear callback will issue the first focus request that
            // tvOS can commit; timer writes here only create a visible delay.
            TVHomeDebugTrace.log("home.restoreOverlayFocus waiting for details.disappear")
        } else {
            focusedCardID = target
            // Visible menus do not have a Details transition to wait for, so
            // retain their short retry window.
            for delay in [0.04, 0.12, 0.25, 0.45] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    if overlayRestoreGeneration == generation, overlayRestoreCardID == target {
                        TVHomeDebugTrace.log("home.restoreOverlayFocus fire target=\(target) delay=\(delay)")
                        focusedCardID = target
                    }
                }
            }
        }

        // Safety fallback if the lifecycle callback is lost. Normally the
        // target card's focus callback clears the lock much earlier.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            if overlayRestoreGeneration == generation, overlayRestoreCardID == target {
                TVHomeDebugTrace.log("home.restoreOverlayFocus safety cleanup target=\(target)")
                if waitForDetailsDisappearance {
                    focusedCardID = target
                }
                overlayRestoreCardID = nil
                if focusWork.restoringOverlayCardID == target {
                    focusWork.restoringOverlayCardID = nil
                }
            }
        }
    }

    /// Release the one-card focus lock as soon as the intended card's real
    /// focus callback confirms restoration. Defer the unlock by one run-loop
    /// turn so the current focus transaction finishes with only that card
    /// eligible; unlocking inside the callback let tvOS jump to the first row
    /// in the six-row focus window (two rows above).
    private func completeOverlayFocusRestore(for cardKey: String) {
        guard focusWork.restoringOverlayCardID == cardKey else { return }
        let generation = overlayRestoreGeneration
        TVHomeDebugTrace.log("home.completeOverlayFocusRestore start cardKey=\(cardKey) gen=\(generation)")
        DispatchQueue.main.async {
            guard overlayRestoreGeneration == generation,
                  focusWork.restoringOverlayCardID == cardKey,
                  overlayRestoreCardID == cardKey else { return }

            TVHomeDebugTrace.log("home.completeOverlayFocusRestore done cardKey=\(cardKey)")
            focusWork.restoringOverlayCardID = nil
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                overlayRestoreCardID = nil
                focusedCardID = cardKey
            }
        }
    }

    /// The loading spinner should only replace the catalog on a genuine first
    /// load. When returning from a card the sections are already cached in the
    /// store, so we render them straight away instead of flashing the spinner.
    private var showsLoading: Bool {
        // A profile switch holds this on regardless of what is cached: the rows
        // underneath belong to the profile being left, and swapping them in
        // place is what made a switch look like Home assembling itself.
        if isProfileSwitching { return true }
        // Account progress is available before the add-on catalog requests
        // finish. Do not cover a ready Continue Watching row with the global
        // spinner while BetterPosters (or another large add-on) is loading.
        return isLoading && store.sections.isEmpty && continueWatching.isEmpty
    }

    private var firstFocusableSectionId: String? {
        visibleSections.first { $0.hasContent && !$0.isLoadingPlaceholder }?.id
    }

    /// Composite key of the card that should grab focus when the rows appear.
    /// On a fresh load that's the first card; when returning from details it's
    /// the card the user left on (persisted in the store), so focus lands back
    /// exactly where it was — the same behaviour as coming out of the menu.
    private var initialFocusCardKey: String? {
        guard !didRequestInitialCardFocus else { return nil }
        if let pendingInitialFocusCardKey {
            return pendingInitialFocusCardKey
        }
        if let saved = store.lastFocusedCardID {
            return saved
        }
        guard let section = visibleSections.first(where: {
            $0.hasContent && !$0.isLoadingPlaceholder
        }) else { return nil }
        if let folder = section.collectionFolders.first {
            return "\(section.id)\u{1}\(folder.id)"
        }
        guard let first = section.items.first else { return nil }
        return "\(section.id)\u{1}\(first.id)"
    }

    /// Stable, small signature for progressive row publication. It lets the
    /// lazy viewport retry saved-focus preparation without comparing metadata
    /// arrays or rebuilding work for every card.
    private var initialFocusContentSignature: String {
        let sectionSignature = visibleSections.map { section in
            "\(section.id)\u{1}\(section.isLoadingPlaceholder ? 1 : 0)"
                + "\u{1}\(section.items.count)\u{1}\(section.collectionFolders.count)"
        }
        .joined(separator: "\u{1e}")
        return "\(store.hasLoaded)\u{1e}\(sectionSignature)"
    }

    /// Finds the saved card without assuming that section or card IDs contain
    /// no separators. The lazy vertical stack must know the distant section
    /// before its card can run the existing initial-focus callback.
    private func initialFocusLocation(
        in sections: [TVHomeSection]
    ) -> (sectionIndex: Int, sectionID: String, cardIndex: Int)? {
        guard let focusKey = initialFocusCardKey else { return nil }

        for (sectionIndex, section) in sections.enumerated() {
            let prefix = "\(section.id)\u{1}"
            guard focusKey.hasPrefix(prefix) else { continue }
            let cardID = String(focusKey.dropFirst(prefix.count))

            if let cardIndex = section.collectionFolders.firstIndex(where: { $0.id == cardID }) {
                return (sectionIndex, section.id, cardIndex)
            }
            if let cardIndex = section.items.firstIndex(where: { $0.id == cardID }) {
                return (sectionIndex, section.id, cardIndex)
            }
        }
        return nil
    }

    /// Seeds both vertical and horizontal restoration state before a distant
    /// saved card can request focus from a lazily mounted row.
    private func prepareInitialFocusViewport(
        for sections: [TVHomeSection],
        using proxy: ScrollViewProxy
    ) {
        guard !didPrepareInitialFocusViewport else { return }
        guard let location = initialFocusLocation(in: sections) else {
            // Keep a saved target alive while progressive loading has not yet
            // published its section. Once the final tree is known, fall back
            // safely to normal first-row focus if that card truly disappeared.
            if !store.hasLoaded {
                if pendingInitialFocusCardKey == nil {
                    pendingInitialFocusCardKey = store.lastFocusedCardID
                }
                return
            }
            pendingInitialFocusCardKey = nil
            didPrepareInitialFocusViewport = true
            store.lastFocusedCardID = nil
            return
        }

        didPrepareInitialFocusViewport = true
        focusedRowIndex = location.sectionIndex
        rowScrollStore.setIndex(location.cardIndex, for: location.sectionID)

        // Fresh first-row focus already has the correct viewport. Preserve its
        // existing first-load behavior and only move the lazy stack for a
        // distant saved section.
        guard location.sectionIndex > 0 else { return }
        DispatchQueue.main.async {
            guard !self.didRequestInitialCardFocus else { return }
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                proxy.scrollTo(location.sectionID, anchor: .top)
            }
        }
    }

    /// Catalog poster row estimate (title + strip + labels padding).
    private var estimatedCatalogRowHeight: CGFloat {
        let imageHeight: CGFloat = 315
        let stripHeight = imageHeight + (posterLabels ? 48 : 0) + TVHomeLayout.stripVerticalPadding * 2
        // One 30pt Inter title line plus the row's 10pt internal spacing.
        return stripHeight + TVHomeLayout.rowTitleBlock
    }

    /// Collection folder row estimate. Curated templates may hide every folder
    /// label even when poster labels are enabled globally.
    private func estimatedCollectionRowHeight(for section: TVHomeSection) -> CGFloat {
        let imageHeight: CGFloat = 315
        let showsLabels = posterLabels && section.collectionFolders.contains { !$0.hideTitle }
        let stripHeight = imageHeight + (showsLabels ? 48 : 0) + TVHomeLayout.stripVerticalPadding * 2
        return stripHeight + TVHomeLayout.rowTitleBlock
    }

    private func estimatedHeight(for section: TVHomeSection) -> CGFloat {
        return section.collectionFolders.isEmpty
            ? estimatedCatalogRowHeight
            : estimatedCollectionRowHeight(for: section)
    }

    /// Captures return identity without publishing SwiftUI state. Publishing
    /// `overlayRestoreCardID` here invalidates the entire Home tree on the same
    /// frame that Details is trying to mount, which is why Search felt faster.
    private func navigateToDetailsFromHome(
        id: String,
        type: String,
        restoreCardID: String? = nil
    ) {
        focusWork.defersOverlayPreparation = true
        focusWork.pendingOverlayRestoreCardID = restoreCardID
            ?? focusedCardID
            ?? store.lastFocusedCardID
        onNavigateToDetails(id, type)
    }

    private var visibleSections: [TVHomeSection] {
        let resumeSection = TVHomeSection(
            id: TVHomeSection.continueWatchingId,
            title: L10n.string("home_continue_watching", fallback: "Continue Watching"),
            items: continueWatchingMetas
        )
        let upcomingSection = TVHomeSection(
            id: TVHomeSection.upcomingId,
            title: L10n.string("tvos_home_upcoming", fallback: "Upcoming"),
            items: upcomingMetas
        )
        let pinnedSections = (continueWatching.isEmpty ? [] : [resumeSection])
            + (upcomingMetas.isEmpty ? [] : [upcomingSection])
            + [localTitlesSection, jellyfinSection].compactMap { $0 }

        // The common path does not need to copy and filter every add-on row on
        // each focus update. Keep the original copy-on-write item arrays intact.
        guard hideUnreleased else { return pinnedSections + store.sections }

        let today = ContentReleasePolicy.todayIsoDay()
        func trimmed(_ section: TVHomeSection) -> TVHomeSection {
            // Collection folder rows don't carry title posters; leave them intact.
            if !section.collectionFolders.isEmpty
                || section.id == TVHomeSection.localTitlesId
                || section.id == TVHomeSection.jellyfinId {
                return section
            }
            var copy = section
            copy.items = section.items.filter {
                !ContentReleasePolicy.isUnreleased($0, today: today)
            }
            return copy
        }

        // Pinned rows are short and change independently of the store, so they
        // are trimmed fresh; the add-on rows reuse the memoised buffers.
        return pinnedSections.map(trimmed)
            + unreleasedFilterMemo.filtered(
                store.sections,
                revision: store.sectionsRevision,
                today: today,
                transform: trimmed
            )
    }

    /// Held cards in the Continue Watching / Upcoming row open the resume menu; every other
    /// row keeps the generic title menu. A Continue Watching card whose entry has
    /// since gone (the row refreshed mid-press) falls back rather than doing
    /// nothing.
    private func longPressHandler(for sectionId: String) -> ((NuvioMeta) -> Void)? {
        guard (sectionId == TVHomeSection.continueWatchingId || sectionId == TVHomeSection.upcomingId),
              let onLongPressContinueWatching else {
            return onLongPressCard
        }
        return { meta in
            if let item = continueWatchingByMetaId[meta.id] {
                onLongPressContinueWatching(item)
            } else {
                onLongPressCard?(meta)
            }
        }
    }

    /// Continue Watching context for the hero — only when the focused card is
    /// actually in the Continue Watching / Upcoming row. The same title can also appear in
    /// catalog rows (Popular etc.), where the hero should stay generic.
    private func heroContinueItem(for meta: NuvioMeta) -> ContinueWatchingItem? {
        guard visibleFocusedMeta != nil,
              (focusedSectionId == TVHomeSection.continueWatchingId || focusedSectionId == TVHomeSection.upcomingId) else { return nil }
        return continueWatchingByMetaId[meta.id]
    }

    private var visibleHero: NuvioMeta? {
        guard let hero = store.hero, isVisible(hero) else { return visibleSections.first?.items.first }
        return hero
    }

    private var visibleFocusedMeta: NuvioMeta? {
        guard let focusedMeta, isVisible(focusedMeta) else { return nil }
        return focusedMeta
    }

    /// Featured titles for Grid View's automatic hero. Start with one item from
    /// each catalog for variety, then fill any remaining carousel slots from
    /// the catalog order without duplicates.

    private func landscapeFocusedId(for sectionId: String) -> String? {
        guard let landscapeFocusedId,
              landscapeFocusedId.hasPrefix("\(sectionId)\u{1}") else {
            return nil
        }
        return landscapeFocusedId
    }

    private var homeBackdropURL: String? {
        // Collection folder focus uses its own hero backdrop (Android Modern
        // Home parity). Fall back to the focused/hero title poster otherwise.
        if let folder = focusedCollectionFolder {
            return folder.preferredHeroBackdropURLString
                ?? preferredBackdropURL(for: visibleHero)
        }
        return preferredBackdropURL(for: visibleFocusedMeta) ?? preferredBackdropURL(for: visibleHero)
    }

    private func preferredBackdropURL(for meta: NuvioMeta?) -> String? {
        guard let meta else { return nil }

        // Match PosterCard's landscape artwork selection. BetterPosters catalog
        // entries intentionally contain `poster` without `background`; falling
        // back here keeps the focused card and the Home backdrop in sync.
        for candidate in [meta.backgroundUrl, meta.posterUrl] {
            let url = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !url.isEmpty { return url }
        }
        return nil
    }

    private func isVisible(_ meta: NuvioMeta) -> Bool {
        guard hideUnreleased else { return true }
        return !ContentReleasePolicy.isUnreleased(meta)
    }

    private func shouldDisplayContinueWatchingItem(_ item: ContinueWatchingItem) -> Bool {
        (!item.isUpNextEntry || ContinueWatchingFeatureFlags.nextUpCardsEnabled)
            && isVisible(item.meta)
            && (showUnairedNextUp || !item.isUpNextEntry || item.hasAired || item.isAiringToday)
            && !ContinueWatchingDismissStore.isDismissed(item)
    }

    private func requestLoadingFocus() {
        DispatchQueue.main.async {
            isLoadingFocusActive = true
        }
    }

    @MainActor
    private func loadWithAutomaticRetry(
        for identity: TVHomeContentIdentity,
        forceReload: Bool = false
    ) async {
        guard identity.profileId != "none" && !identity.profileId.isEmpty else {
            isLoading = false
            return
        }
        let maximumAttempts = 3
        for attempt in 0..<maximumAttempts {
            await load(for: identity, forceReload: forceReload || attempt > 0)
            guard !Task.isCancelled else { return }
            if store.isLoaded(for: identity) {
                // Add-on rows are best-effort, so a partial response is still
                // useful. Keep it visible, wait briefly, then replace the tree
                // once instead of caching the omission for the whole session.
                guard repository.homeCatalogLoadWasPartial else { return }
                let failure = repository.homeCatalogFailureSignature
                // This recovery is for a transient outage. A failure set an
                // earlier retry already failed to change is permanent -- a dead
                // add-on URL, or a catalog its host always rejects -- and
                // retrying it re-fetches every row from every add-on to recover
                // nothing, on every profile entry for the rest of the session.
                if let failure, Self.unimprovedHomeFailures.contains(failure) { return }
                do {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                } catch {
                    return
                }
                await load(for: identity, forceReload: true)
                if let failure, repository.homeCatalogFailureSignature == failure {
                    Self.unimprovedHomeFailures.insert(failure)
                }
                return
            }
            guard attempt < maximumAttempts - 1 else { return }

            do {
                try await Task.sleep(
                    nanoseconds: UInt64(attempt + 1) * 1_000_000_000
                )
            } catch {
                return
            }
        }
    }

    @MainActor
    private func load(
        for identity: TVHomeContentIdentity,
        forceReload: Bool = false
    ) async {
        guard identity.profileId != "none" && !identity.profileId.isEmpty else {
            isLoading = false
            return
        }
        // Progress is local/account-synced state and does not depend on the
        // catalog network request below. Publish it first so Home is useful
        // even while a large add-on is still resolving its rows.
        refreshContinueWatching()
        refreshWatchedTitles()

        // Returning from a card: the catalog is still cached in the store, so
        // skip the network round-trip. The saved card re-focuses itself via
        // `initialFocusCardKey`, which restores the row/scroll position too.
        if !forceReload, store.isLoaded(for: identity) {
            isLoading = false
            refreshContinueWatching()
            refreshWatchedTitles()
            return
        }

        let generation = store.beginLoad(for: identity)
        // Captured before the first request so it describes what this load read,
        // not what a settings change mid-flight left behind.
        let inputSignature = repository.homeCatalogInputSignature
        isLoading = true
        errorMessage = nil

        // Collections are already local once account sync applies them. Publish
        // their folder rows before starting provider requests so a slow catalog
        // host cannot hold the user's collections off Home.
        let collectionSections = await loadCollectionSections()
        guard store.isCurrentLoad(generation, for: identity) else { return }
        let previouslyLoadedCatalogSections = store.sections.filter {
            !$0.isCollectionRow
                && !$0.isLoadingPlaceholder
                && isHomeCatalogSectionFromEnabledSource($0)
        }
        // Seeded before the first publish so a cold Home shows its rows'
        // titles and spinning cards immediately, rather than assembling itself
        // row by row under the user.
        homeLoadingPlaceholders = homeSkeletonSections(
            excluding: Set(previouslyLoadedCatalogSections.map(\.id))
                .union(collectionSections.map(\.id))
        )
        publishHomeSections(
            catalogSections: previouslyLoadedCatalogSections,
            collectionSections: collectionSections,
            resetFocusIfEmpty: true
        )

        var receivedCatalogUpdate = false
        do {
            var latestCatalogSections: [TVHomeSection] = []
            for try await catalogs in repository.homeCatalogsProgressively() {
                try Task.checkCancellation()
                guard store.isCurrentLoad(generation, for: identity) else { return }
                let catalogSections = await makeHomeCatalogSections(from: catalogs)
                try Task.checkCancellation()
                guard store.isCurrentLoad(generation, for: identity) else { return }
                latestCatalogSections = catalogSections
                receivedCatalogUpdate = receivedCatalogUpdate || !catalogSections.isEmpty
                let loadedIds = Set(catalogSections.map(\.id))
                let retainedPrevious = previouslyLoadedCatalogSections.filter {
                    !loadedIds.contains($0.id)
                }
                publishHomeSections(
                    // Keep the previous successful tree while this replacement
                    // is still arriving, then publish the exact final result
                    // below. Late rows append without making earlier rows flash.
                    catalogSections: catalogSections + retainedPrevious,
                    collectionSections: collectionSections,
                    resetFocusIfEmpty: true
                )
            }
            guard receivedCatalogUpdate || !collectionSections.isEmpty else {
                throw URLError(.cannotLoadFromNetwork)
            }
            guard store.isCurrentLoad(generation, for: identity) else { return }
            // Every row this load was going to produce has arrived; whatever is
            // still a skeleton is never coming.
            clearHomeLoadingPlaceholders()
            publishHomeSections(
                catalogSections: receivedCatalogUpdate
                    ? latestCatalogSections
                    : previouslyLoadedCatalogSections,
                collectionSections: collectionSections,
                resetFocusIfEmpty: true
            )
            store.finishLoad(generation, for: identity)
            lastLoadedInputSignature = inputSignature
            refreshContinueWatching()
            refreshWatchedTitles()
            isLoading = false
        } catch is CancellationError {
            guard store.isCurrentLoad(generation, for: identity) else { return }
            store.cancelLoad(generation, for: identity)
            clearHomeLoadingPlaceholders()
            isLoading = false
        } catch {
            guard store.isCurrentLoad(generation, for: identity) else { return }
            clearHomeLoadingPlaceholders()
            errorMessage = error.localizedDescription
            // Synced collections or progressively loaded catalogs remain useful
            // even if another provider failed after they were published.
            if receivedCatalogUpdate || !collectionSections.isEmpty {
                store.finishLoad(generation, for: identity)
                lastLoadedInputSignature = inputSignature
            } else {
                store.cancelLoad(generation, for: identity)
            }
            isLoading = false
        }
    }

    @MainActor
    private func reloadHomeAfterSyncedInputs(for identity: TVHomeContentIdentity) async {
        guard identity.profileId != "none" && !identity.profileId.isEmpty else { return }
        // Do not overlap the revision-owned load. Waiting preserves its useful
        // rows, then forceReload replaces them using the complete synced inputs.
        while store.isLoading(for: identity) {
            do {
                try await Task.sleep(nanoseconds: 200_000_000)
            } catch {
                return
            }
        }
        guard !Task.isCancelled, identity == contentIdentity else { return }
        // The notification means sync finished, not that it changed anything
        // Home reads. When the add-on and catalog settings are byte-identical
        // to the ones the completed load already used, this reload re-fetches
        // every catalog from every add-on to rebuild the same tree.
        guard repository.homeCatalogInputSignature != lastLoadedInputSignature else { return }
        await load(for: identity, forceReload: true)
    }

    @MainActor
    private func makeHomeCatalogSections(from catalogs: [NuvioCatalog]) async -> [TVHomeSection] {
        var loadedSections: [TVHomeSection] = []
        loadedSections.reserveCapacity(catalogs.count)

        for catalog in catalogs {
            guard !Task.isCancelled else { return loadedSections }
            let items: [NuvioMeta]
            let pendingItems: [NuvioMeta]
            let nextSkip: Int
            if let catalogItems = catalog.items {
                let initialItems = Array(catalogItems.prefix(18))
                items = await TmdbDetailsService.localizedMetadata(for: initialItems)
                pendingItems = Array(catalogItems.dropFirst(initialItems.count))
                // The add-on already returned these records, even though Home
                // reveals them in smaller UI batches.
                nextSkip = catalogItems.count
            } else {
                var resolvedItems: [NuvioMeta] = []
                for id in catalog.itemIds.prefix(18) {
                    if let meta = try? await repository.getMetadata(
                        id: id,
                        type: catalog.contentType ?? "movie"
                    ) {
                        resolvedItems.append(meta)
                    }
                }
                items = resolvedItems
                pendingItems = []
                nextSkip = items.count
            }

            let canRequestMore = catalog.contentType != nil && catalog.catalogId != nil
            loadedSections.append(
                TVHomeSection(
                    id: catalog.id,
                    title: catalog.name,
                    items: items,
                    contentType: catalog.contentType,
                    catalogId: catalog.catalogId,
                    addonId: catalog.addonId,
                    addonName: catalog.addonName,
                    catalogGenre: catalog.catalogGenre,
                    pendingItems: pendingItems,
                    nextSkip: nextSkip,
                    hasMore: !items.isEmpty && (!pendingItems.isEmpty || canRequestMore)
                )
            )
        }
        return loadedSections
    }

    /// Pinning is an invariant above the user/catalog order: saved cross-device
    /// row positions may arrange the remainder, but can never push a pinned
    /// collection below a catalog.
    private func homeOrderedSections(_ sections: [TVHomeSection]) -> [TVHomeSection] {
        let pinnedCollections = sections.filter {
            $0.isCollectionRow && $0.isPinnedCollection
        }
        let remainder = sections.filter {
            !($0.isCollectionRow && $0.isPinnedCollection)
        }
        return pinnedCollections + TVHomeCatalogOrder.apply(to: remainder)
    }

    @MainActor
    private func publishHomeSections(
        catalogSections: [TVHomeSection],
        collectionSections: [TVHomeSection],
        resetFocusIfEmpty: Bool
    ) {
        let pinned = collectionSections.filter(\.isPinnedCollection)
        let unpinned = collectionSections.filter { !$0.isPinnedCollection }
        let composed = homeOrderedSections(pinned + catalogSections + unpinned)

        // Rows this load still owes, drawn as skeletons in their saved position.
        let published = Set(composed.map(\.id))
        let skeletons = homeLoadingPlaceholders.filter { !published.contains($0.id) }
        guard !composed.isEmpty || !skeletons.isEmpty else {
            store.sections = []
            store.hero = nil
            return
        }
        let visible = skeletons.isEmpty
            ? composed
            : homeOrderedSections(composed + skeletons)

        // "Empty" means nothing real was on screen yet — skeletons must not
        // count, or the focus seeding below would be skipped once the first
        // genuine row lands.
        let wasEmpty = store.sections.allSatisfy(\.isLoadingPlaceholder)
        // The snapshot is what the next launch seeds skeletons *from*, so only
        // rows that actually resolved belong in it.
        TVHomeCatalogOrder.writeSnapshot(composed)
        store.sections = visible
        store.hero = composed.lazy.compactMap { $0.items.first }.first

        guard wasEmpty && resetFocusIfEmpty else { return }
        store.lastFocusedCardID = nil
        focusedMeta = store.hero
        focusedSectionId = nil
        focusedCollectionFolder = nil
        focusWork.pendingFocusedMeta = focusedMeta
        // Keep folder-hero state clear until a folder card is focused.
        landscapeFocusedId = nil
        focusWork.pendingLandscapeFocusedId = nil
        didRequestInitialCardFocus = false
        didPrepareInitialFocusViewport = false
        pendingInitialFocusCardKey = nil
        shouldRestoreHomeFocus = false
        retainedFocusBindingCardID = nil
    }

    /// Skeleton rows for catalogs this load has not returned yet, taken from the
    /// last Home's snapshot so each one lands in its saved position.
    ///
    /// Hidden rows survive in that snapshot on purpose — Settings needs them to
    /// offer them back — so they are filtered out here; a row the user removed
    /// must not reappear as a spinner. Collection rows are excluded too: they
    /// come from the local store and are already on screen before the first
    /// catalog request goes out.
    private func homeSkeletonSections(excluding published: Set<String>) -> [TVHomeSection] {
        let hiddenCatalogs = TVHomeCatalogOrder.disabledCatalogKeys()
        let hiddenCollections = TVHomeCatalogOrder.disabledCollectionIds()

        return TVHomeCatalogOrder.snapshotRows().compactMap { row in
            guard !published.contains(row.id),
                  !row.id.hasPrefix(TVHomeSection.collectionIdPrefix),
                  row.id != TVHomeSection.continueWatchingId,
                  row.id != TVHomeSection.upcomingId,
                  !hiddenCollections.contains(row.id),
                  isHomeCatalogSnapshotRowFromEnabledSource(row) else {
                return nil
            }
            if let settingsKey = row.settingsKey, hiddenCatalogs.contains(settingsKey) {
                return nil
            }
            return TVHomeSection(
                id: row.id,
                title: row.title,
                items: [],
                addonName: row.addonName,
                isLoadingPlaceholder: true
            )
        }
    }

    /// A disabled provider must not leave its previous rows or loading
    /// placeholders visible while the replacement Home tree is being built.
    /// Built-in rows have no `addonId`, but their persisted settings key still
    /// carries Cinemeta's manifest id.
    private func isHomeCatalogSectionFromEnabledSource(_ section: TVHomeSection) -> Bool {
        guard section.contentType != nil, section.catalogId != nil else { return true }
        guard section.addonId == nil else { return true }
        return CinemetaCatalogRepository.isCinemetaEnabled
    }

    private func isHomeCatalogSnapshotRowFromEnabledSource(
        _ row: TVHomeCatalogOrder.SnapshotRow
    ) -> Bool {
        guard !CinemetaCatalogRepository.isCinemetaEnabled else { return true }
        return !(row.settingsKey?.hasPrefix("\(CinemetaCatalogRepository.cinemetaAddonId)_") ?? false)
    }

    /// Drops every skeleton, from the pending list and from what is on screen.
    /// A row that failed has to stop spinning, not spin until the next load.
    private func clearHomeLoadingPlaceholders() {
        homeLoadingPlaceholders = []
        guard store.sections.contains(where: \.isLoadingPlaceholder) else { return }
        store.sections = store.sections.filter { !$0.isLoadingPlaceholder }
    }

    /// Builds one Home row per synced collection with emoji/folder cards.
    /// Uses the same vertical paging / spacing rhythm as catalog rows
    /// (`TVHomeLayout`, measured heights, neighbor materialization) so the
    /// next section (e.g. Popular) peeks under a focused collection the same
    /// way catalog rows do — without flattening folders into title posters.
    private func loadCollectionSections() async -> [TVHomeSection] {
        let disabledCollectionIds = TVHomeCatalogOrder.disabledCollectionIds()
        let stored = CollectionsStore.collections()
        var sections: [TVHomeSection] = []
        for collection in stored {
            if disabledCollectionIds.contains(collection.id) {
                continue
            }
            // Keep every folder card — including empty / TMDB / Trakt-only.
            // Previously those were dropped, so a collection with no add-on
            // catalogs never appeared on Home even though sync had it.
            let folders: [TVCollectionFolderItem] = collection.folders.map { folder in
                TVCollectionFolderItem(
                    collectionId: collection.id,
                    folder: folder,
                    sources: folder.resolvedSources,
                    viewMode: collection.viewMode,
                    showAllTab: collection.showAllTab
                )
            }
            if folders.isEmpty {
                continue
            }
            sections.append(
                TVHomeSection(
                    id: "\(TVHomeSection.collectionIdPrefix)\(collection.id)",
                    title: collection.title,
                    items: [],
                    isPinnedCollection: collection.pinToTop,
                    collectionFolders: folders
                )
            )
        }
        return sections
    }

    /// Re-resolves collection rows in place after a sync pull / local edit
    /// lands while Home is already loaded, without disturbing catalog rows.
    private func refreshCollectionSections(for identity: TVHomeContentIdentity) async {
        guard identity.profileId != "none" && !identity.profileId.isEmpty else { return }
        // The revision is retained even if it changes during the initial catalog
        // request. Wait for that identity to finish, then apply the latest store
        // snapshot instead of dropping an early collection update.
        while store.isLoading(for: identity) {
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                return
            }
        }
        guard store.isLoaded(for: identity) else { return }
        let fresh = await loadCollectionSections()
        guard store.isLoaded(for: identity) else { return }
        let catalogRows = store.sections.filter { !$0.isCollectionRow }
        let pinned = fresh.filter(\.isPinnedCollection)
        let unpinned = fresh.filter { !$0.isPinnedCollection }
        let merged = homeOrderedSections(pinned + catalogRows + unpinned)
        TVHomeCatalogOrder.writeSnapshot(merged)
        // Compare ids *and* folder tile shapes / titles so edits like switching
        // Poster ↔ Landscape actually re-render Home (id-only checks skip them).
        let currentSignature = collectionSectionsSignature(store.sections)
        let nextSignature = collectionSectionsSignature(merged)
        if currentSignature != nextSignature {
            store.sections = merged
        }
    }

    private func collectionSectionsSignature(_ sections: [TVHomeSection]) -> String {
        sections.map { section in
            let folders = section.collectionFolders
                .map {
                    "\($0.id):\($0.tileShape.rawValue):\($0.title):\($0.focusGifEnabled):\($0.focusGifUrl ?? ""):\($0.heroBackdropUrl ?? ""):\($0.titleLogoUrl ?? ""):\($0.viewMode.rawValue):\($0.showAllTab)"
                }
                .joined(separator: ",")
            return "\(section.id)|\(section.title)|\(section.isPinnedCollection)|\(folders)"
        }.joined(separator: ";")
    }

    /// Idle delay before hero text + full-screen backdrop swap. Short enough to
    /// feel responsive when parked, long enough that continuous left/right/up/down
    /// focus does not kick off decode/crossfade every step.
    private var heroSettleNanoseconds: UInt64 {
        300_000_000
    }

    /// Catalog title focus: card strip + row offset are immediate; hero/backdrop
    /// publish only after the settle delay (and cancel if focus moves again).
    private func settleCatalogFocus(on meta: NuvioMeta, in sectionId: String) {
        focusWork.pendingFocusedMeta = meta
        focusWork.pendingFocusedFolder = nil
        focusWork.pendingSectionId = sectionId
        scheduleHeroSettle()
    }

    /// Collection folder focus: same freeze as catalog — keep previous hero art
    /// until the user rests on a folder card.
    private func settleFolderFocus(_ folder: TVCollectionFolderItem, in sectionId: String) {
        focusWork.pendingFocusedMeta = nil
        focusWork.pendingFocusedFolder = folder
        focusWork.pendingSectionId = sectionId
        scheduleHeroSettle()
    }

    private func scheduleHeroSettle() {
        focusWork.focusSettleTask?.cancel()

        let targetMetaId = focusWork.pendingFocusedMeta?.id
        let targetFolderId = focusWork.pendingFocusedFolder?.id
        let targetSectionId = focusWork.pendingSectionId
        let hasFolderPending = targetFolderId != nil
        let delay = heroSettleNanoseconds
        TVHomeDebugTrace.log(
            "hero.schedule section=\(targetSectionId ?? "nil") meta=\(targetMetaId ?? "nil") "
                + "folder=\(targetFolderId ?? "nil") delayMs=\(delay / 1_000_000)"
        )

        focusWork.focusSettleTask = Task { @MainActor in
            let started = TVHomeDebugTrace.now()
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }

            if hasFolderPending {
                guard let folder = focusWork.pendingFocusedFolder,
                      folder.id == targetFolderId,
                      let targetSectionId,
                      focusWork.pendingSectionId == targetSectionId else { return }
                // The section is part of the hero state: Continue Watching can
                // change the episode line and description for the same title.
                // Publish it with the settled card, not with the first focus
                // callback during a rapid move.
                focusedSectionId = targetSectionId
                // Publish folder hero only when it actually changes.
                if focusedCollectionFolder?.id != folder.id {
                    focusedCollectionFolder = folder
                }
                if focusedMeta != nil {
                    focusedMeta = nil
                }
                TVHomeDebugTrace.log(
                    "hero.publish folder=\(folder.id) elapsedMs=\(TVHomeDebugTrace.elapsedMilliseconds(since: started))"
                )
                return
            }

            guard let settledMeta = focusWork.pendingFocusedMeta,
                  settledMeta.id == targetMetaId,
                  let targetSectionId,
                  focusWork.pendingSectionId == targetSectionId else { return }

            // Leaving a folder hero: clear only after settle so backdrop stays frozen.
            focusedSectionId = targetSectionId
            if focusedCollectionFolder != nil {
                focusedCollectionFolder = nil
            }
            if focusedMeta?.id != settledMeta.id {
                focusedMeta = settledMeta
            }

            TVHomeDebugTrace.log(
                "hero.publish section=\(targetSectionId) meta=\(settledMeta.id) "
                    + "enrich=\(settledMeta.needsHeroMetadataEnrichment) "
                    + "elapsedMs=\(TVHomeDebugTrace.elapsedMilliseconds(since: started))"
            )

            // Third-party catalog responses are often intentionally compact
            // and omit runtime/status and shelf artwork. Once focus settles,
            // ask for the full metadata record and fill the missing fields.
            guard settledMeta.needsHeroMetadataEnrichment else { return }
            await enrichSettledCatalogMeta(settledMeta, in: targetSectionId)
        }
    }

    /// Fetches (or reuses the cached) full `/meta` record for a catalog card
    /// focus has rested on and merges the missing fields into it. Debounced by
    /// `scheduleHeroSettle`, so rapid navigation never generates a request per
    /// card passed over. The merged record replaces `focusedMeta` (hero), the
    /// pending focus target, and the exact item inside
    /// `store.sections[sectionId].items` — the latter being what `PosterCard`
    /// renders, so the landscape overlay gains the title logo/backdrop.
    @MainActor
    private func enrichSettledCatalogMeta(_ settledMeta: NuvioMeta, in sectionId: String) async {
        let enrichmentKey = "\(settledMeta.type.lowercased())\u{1f}\(settledMeta.id)"
        let fullMeta: NuvioMeta
        if let cached = focusWork.enrichedHeroMetadata[enrichmentKey] {
            fullMeta = cached
        } else {
            guard let fetched = try? await repository.getMetadata(
                id: settledMeta.id,
                type: settledMeta.type
            ) else {
                return
            }
            // Cache even when focus has already moved on, so the next visit to
            // this card reuses the fetch instead of repeating it.
            focusWork.enrichedHeroMetadata[enrichmentKey] = fetched
            fullMeta = fetched
        }

        let merged = settledMeta.fillingMissingHeroMetadata(from: fullMeta)
        // Publish only while this card is still the settled focus target: a
        // stale record must never overwrite the hero mid-navigation.
        guard !Task.isCancelled,
              focusWork.pendingFocusedMeta?.id == settledMeta.id,
              focusWork.pendingSectionId == sectionId,
              focusWork.pendingFocusedFolder == nil else {
            return
        }
        focusedMeta = merged
        focusWork.pendingFocusedMeta = merged
        guard let sectionIndex = store.sections.firstIndex(where: { $0.id == sectionId }),
              let itemIndex = store.sections[sectionIndex].items.firstIndex(where: { $0.id == settledMeta.id }) else {
            return
        }
        if store.sections[sectionIndex].items[itemIndex] != merged {
            store.sections[sectionIndex].items[itemIndex] = merged
        }
    }

    @MainActor
    private func loadMoreSectionIfNeeded(sectionId: String, currentItem: NuvioMeta) {
        // The resume row is built locally from the ledger rather than fetched
        // from an add-on catalog, so it pages through its own path.
        if sectionId == TVHomeSection.continueWatchingId {
            loadMoreContinueWatchingIfNeeded(currentItem: currentItem)
            return
        }
        if sectionId == TVHomeSection.upcomingId {
            return
        }
        guard let sectionIndex = store.sections.firstIndex(where: { $0.id == sectionId }) else { return }
        let section = store.sections[sectionIndex]
        guard section.hasMore,
              !section.isLoadingMore,
              let contentType = section.contentType,
              let catalogId = section.catalogId,
              let itemIndex = section.items.firstIndex(where: { $0.id == currentItem.id }),
              itemIndex >= max(section.items.count - TVHomeRowPrefetchThreshold, 0) else {
            return
        }

        let requestedSkip = section.nextSkip ?? section.items.count

        // Some add-ons return hundreds of items in their first response. Home
        // mounts them in small batches to keep the horizontal row responsive;
        // reveal those before making another network request. These records
        // skipped the TMDB enrichment the first 18 items went through, so pass
        // the batch through the same preparation so post-18 cards show the
        // same shelf artwork (logo/backdrop) as the head of the row.
        if !section.pendingItems.isEmpty {
            let batchCount = min(18, section.pendingItems.count)
            let batch = Array(section.pendingItems.prefix(batchCount))
            store.sections[sectionIndex].pendingItems.removeFirst(batchCount)
            store.sections[sectionIndex].isLoadingMore = true
            Task { @MainActor in
                defer {
                    if let latestIndex = store.sections.firstIndex(where: { $0.id == sectionId }) {
                        store.sections[latestIndex].isLoadingMore = false
                    }
                }
                let enrichedBatch = await TmdbDetailsService.localizedMetadata(for: batch)
                guard let latestIndex = store.sections.firstIndex(where: { $0.id == sectionId }) else {
                    return
                }
                let currentIds = Set(store.sections[latestIndex].items.map(\.id))
                store.sections[latestIndex].items.append(
                    contentsOf: enrichedBatch.filter { !currentIds.contains($0.id) }
                )
                store.sections[latestIndex].hasMore =
                    !store.sections[latestIndex].pendingItems.isEmpty
                    || (store.sections[latestIndex].contentType != nil && store.sections[latestIndex].catalogId != nil)
            }
            return
        }

        store.sections[sectionIndex].isLoadingMore = true

        Task { @MainActor in
            do {
                let page = try await repository.browseCatalog(
                    addonId: section.addonId,
                    contentType: contentType,
                    catalogId: catalogId,
                    skip: requestedSkip,
                    genre: section.catalogGenre
                )

                guard let latestIndex = store.sections.firstIndex(where: { $0.id == sectionId }) else { return }
                let existingIds = Set(store.sections[latestIndex].items.map(\.id))
                let newItems = page.items.filter { !existingIds.contains($0.id) }

                store.sections[latestIndex].items.append(contentsOf: newItems)
                store.sections[latestIndex].nextSkip = page.nextSkip ?? (requestedSkip + page.items.count)
                store.sections[latestIndex].hasMore = page.hasMore && !newItems.isEmpty
                store.sections[latestIndex].isLoadingMore = false
            } catch {
                guard let latestIndex = store.sections.firstIndex(where: { $0.id == sectionId }) else { return }
                store.sections[latestIndex].isLoadingMore = false
            }
        }
    }

    private func scheduleLandscapeFocus(cardKey: String) {
        guard !suppressReturnFocusAnimations, focusedPosterBackdropEnabled else {
            focusWork.pendingLandscapeFocusedId = nil
            landscapeFocusedId = nil
            focusWork.landscapeFocusTask?.cancel()
            return
        }

        if focusWork.pendingLandscapeFocusedId == cardKey && landscapeFocusedId == nil { return }
        if landscapeFocusedId == cardKey { return }

        focusWork.pendingLandscapeFocusedId = cardKey
        if landscapeFocusedId != nil {
            landscapeFocusedId = nil
        }
        focusWork.landscapeFocusTask?.cancel()

        let targetKey = cardKey
        let delaySeconds = max(1, focusedPosterBackdropDelay)
        TVHomeDebugTrace.log(
            "backdrop.schedule card=\(cardKey) delayMs=\(delaySeconds * 1_000)"
        )
        focusWork.landscapeFocusTask = Task { @MainActor in
            let started = TVHomeDebugTrace.now()
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds) * 1_000_000_000)
            guard !Task.isCancelled,
                  focusWork.pendingLandscapeFocusedId == targetKey else {
                return
            }

            landscapeFocusedId = targetKey
            TVHomeDebugTrace.log(
                "backdrop.publish card=\(targetKey) elapsedMs=\(TVHomeDebugTrace.elapsedMilliseconds(since: started))"
            )
        }
    }

    private func armReturnFocusAnimationSuppression() {
        returnFocusAnimationGeneration &+= 1
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            suppressReturnFocusAnimations = true
            landscapeFocusedId = nil
        }
        focusWork.pendingLandscapeFocusedId = nil
        focusWork.landscapeFocusTask?.cancel()
    }

    private func releaseReturnFocusAnimationSuppression() {
        guard suppressReturnFocusAnimations else { return }
        let generation = returnFocusAnimationGeneration

        // Let the restored card and row settle for a couple of frames while
        // animations are disabled, then restore normal navigation motion.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            guard isActive, returnFocusAnimationGeneration == generation else { return }
            suppressReturnFocusAnimations = false

            // Switching tabs leaves `focusedCardID` intact, so coming back
            // from Settings does not emit PosterCard's normal onFocus callback.
            // Restart the landscape settle timer for that retained card once
            // the no-animation restoration window has finished.
            if let focusedCardID {
                scheduleLandscapeFocus(cardKey: focusedCardID)
            }
        }
    }

    private func clearLandscapeFocus(cardKey: String) {
        if focusWork.pendingLandscapeFocusedId == cardKey {
            focusWork.pendingLandscapeFocusedId = nil
            focusWork.landscapeFocusTask?.cancel()
        }

        if !focusWork.defersOverlayPreparation, landscapeFocusedId == cardKey {
            landscapeFocusedId = nil
        }
    }

    /// Publishes Continue Watching and its derived lookup data together. The
    /// row is updated from notifications and source refreshes, while Home can
    /// re-evaluate its body dozens of times during focus movement; keeping the
    /// metadata array and progress index out of those body computations is the
    /// important part of this helper.
    private func setContinueWatching(_ rawItems: [ContinueWatchingItem]) {
        rawContinueWatchingItems = rawItems
        let (items, upcoming): ([ContinueWatchingItem], [ContinueWatchingItem]) = {
            if continueWatchingSort == "Separate Upcoming Row" {
                let released = ContinueWatchingSortPolicy.sorted(rawItems, preference: continueWatchingSort)
                let unreleased = ContinueWatchingSortPolicy.upcomingItems(rawItems)
                return (released, unreleased)
            } else {
                return (ContinueWatchingSortPolicy.sorted(rawItems, preference: continueWatchingSort), [])
            }
        }()

        TVHomeDebugTrace.log(
            "cw.set incoming=\(rawItems.count) showing=\(items.count) upcoming=\(upcoming.count) "
                + "upNext=\(rawItems.filter(\.isUpNextEntry).count)"
        )
        let all = items + upcoming
        var byMetaId = Dictionary<String, ContinueWatchingItem>(
            minimumCapacity: all.count
        )
        var indexByMetaId = Dictionary<String, Int>(minimumCapacity: items.count)
        for (index, item) in items.enumerated() {
            if let existing = byMetaId[item.meta.id], existing.lastWatchedAt >= item.lastWatchedAt {
                continue
            }
            byMetaId[item.meta.id] = item
            indexByMetaId[item.meta.id] = index
        }
        for item in upcoming {
            if byMetaId[item.meta.id] == nil {
                byMetaId[item.meta.id] = item
            }
        }

        continueWatching = items
        // The full series episode guide remains on the source item for resume,
        // episode lookup, and playback. The row cards only need presentation
        // metadata; keeping hundreds of `videos` entries in every SwiftUI card
        // value makes repeated focus/layout passes carry unnecessary payload.
        continueWatchingMetas = items.map { $0.meta.persistenceSnapshot }
        upcomingItems = upcoming
        upcomingMetas = upcoming.map { $0.meta.persistenceSnapshot }
        continueWatchingByMetaId = byMetaId
        continueWatchingIndexByMetaId = indexByMetaId
        continueWatchingIDs = items.map(\.meta.id)
    }

    private func refreshContinueWatching() {
        guard !usesRemoteProgress else {
            if displayedProgressSource != selectedProgressSource {
                setContinueWatching([])
                displayedProgressSource = selectedProgressSource
            }
            #if DEBUG
            logRowWindow("remote progress source (\(selectedProgressSource.rawValue))")
            #endif
            return
        }
        // The store holds the persisted first page and is authoritative — a save
        // during playback lands there immediately. Pages scrolled in beyond it
        // live only in the builder, so merge them back, letting the store win on
        // any title present in both.
        var byId: [String: ContinueWatchingItem] = [:]
        for item in ContinueWatchingBuilder.pagedItems {
            byId[item.meta.id] = item
        }
        for item in ContinueWatchingStore.items() {
            byId[item.meta.id] = item
        }
        // `recencySortDate`, not `lastWatchedAt`: this pass is what the "Default"
        // sort preference ends up being, and a new drop belongs at the top of it
        // on the day it airs rather than wherever the seeding episode's age puts
        // it. They are the same value for every other card.
        let visibleItems = byId.values
            .sorted { $0.recencySortDate > $1.recencySortDate }
            .filter(shouldDisplayContinueWatchingItem)
        setContinueWatching(visibleItems)
        displayedProgressSource = .nuvioSync
        #if DEBUG
        logRowWindow("after CW refresh (\(continueWatching.count) item(s), \(upcomingItems.count) upcoming)")
        #endif
    }

    #if DEBUG
    /// Reports which rows are focusable versus placeholders, and what the row
    /// window is centred on. Vertical navigation dying on Home means the centre
    /// disagrees with where focus actually is, and that is invisible otherwise.
    private func logRowWindow(_ reason: String) {
        let sections = visibleSections.filter(\.hasContent)
    }
    #endif

    /// Pages in more of the account's history as focus nears the end of the
    /// Continue Watching row, the same way a catalog row loads its next page.
    /// Everything is already in the local ledger, so this only costs metadata
    /// lookups for titles this device has not rendered before.
    private func loadMoreContinueWatchingIfNeeded(currentItem: NuvioMeta) {
        let continueIndex = continueWatchingIndexByMetaId[currentItem.id]
        TVHomeDebugTrace.log(
            "cw.approach id=\(currentItem.id) index=\(continueIndex.map(String.init) ?? "nil") "
                + "count=\(continueWatching.count) canMore=\(ContinueWatchingBuilder.canLoadMore) "
                + "loading=\(isLoadingMoreContinueWatching)"
        )
        guard !usesRemoteProgress,
              ContinueWatchingBuilder.canLoadMore,
              !isLoadingMoreContinueWatching,
              let index = continueIndex,
              index >= max(continueWatching.count - TVHomeRowPrefetchThreshold, 0) else {
            return
        }
        isLoadingMoreContinueWatching = true
        TVHomeDebugTrace.log("cw.approach loadNextPage start count=\(continueWatching.count)")
        Task { @MainActor in
            defer { isLoadingMoreContinueWatching = false }
            _ = await ContinueWatchingBuilder.loadNextPage()
            guard !usesRemoteProgress else { return }
            refreshContinueWatching()
            TVHomeDebugTrace.log("cw.approach loadNextPage end count=\(continueWatching.count)")
        }
    }

    private func scheduleContinueWatchingRefresh() {
        continueWatchingRefreshTask?.cancel()
        continueWatchingRefreshTask = Task {
            await refreshContinueWatchingFromSelectedSource()
        }
    }

    @MainActor
    private func refreshContinueWatchingFromSelectedSource() async {
        continueWatchingRefreshGeneration &+= 1
        let generation = continueWatchingRefreshGeneration
        let profileID = ContinueWatchingStore.activeProfileId
        let source = selectedProgressSource
        let isSimklRefresh = source == .simkl

        if isSimklRefresh {
            beginSimklHomeLoadingDiagnostic(generation: generation)
        } else {
            finishSimklHomeLoadingDiagnostic()
        }
        defer {
            if isSimklRefresh, generation == continueWatchingRefreshGeneration {
                finishSimklHomeLoadingDiagnostic()
            }
        }

        refreshContinueWatching()
        guard usesRemoteProgress else {
            // The ledger this just read is only as fresh as the last account
            // pull. Ask for a new one; it lands via the store's change
            // notification, which already refreshes the row.
            onRequestAccountRefresh()
            return
        }

        let items = await TraktProgressService.fetchContinueWatching(
            repository: repository,
            source: source
        )
        guard !Task.isCancelled else {
            return
        }
        guard generation == continueWatchingRefreshGeneration else {
            return
        }
        guard profileID == ContinueWatchingStore.activeProfileId else {
            return
        }
        guard source == selectedProgressSource, usesRemoteProgress else {
            return
        }
        guard let items else {
            return
        }
        // The row shows one card per title, but a remote provider can return a
        // paused playback per episode — two rows for one series otherwise, and
        // a duplicate-key trap downstream. The provider already sorts newest
        // first, so keeping the first occurrence keeps both the order and the
        // episode the user would resume. The local path dedupes the same way.
        var seenMetaIds = Set<String>()
        let visibleItems = items.filter {
            shouldDisplayContinueWatchingItem($0)
                && seenMetaIds.insert($0.meta.id).inserted
        }
        setContinueWatching(visibleItems)
        displayedProgressSource = source

        // Continue Watching is visible now. Refresh watched checkmarks afterward
        // so a full history sync never blocks the row during a source switch.
        switch source {
        case .nuvioSync:
            break
        case .trakt:
            _ = await TraktHistoryService.syncWatchedHistory()
        case .simkl:
            _ = await SimklHistoryService.syncWatchedHistory()
        }
    }

    private var selectedProgressSource: TraktWatchProgressSource {
        TraktSettingsStore.watchProgressSource
    }

    private var usesRemoteProgress: Bool {
        RemoteTrackingState.isProgressSourceAuthenticated
    }

    private func beginSimklHomeLoadingDiagnostic(generation: Int) {
        simklLoadingTimeoutTask?.cancel()
        simklLoadingStartedAt = Date()
        simklLoadingDebugInfo = nil
        simklLoadingTimeoutTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  generation == continueWatchingRefreshGeneration,
                  selectedProgressSource == .simkl else { return }
            simklLoadingDebugInfo = makeSimklHomeLoadingDebugInfo()
        }
    }

    private func finishSimklHomeLoadingDiagnostic() {
        simklLoadingTimeoutTask?.cancel()
        simklLoadingTimeoutTask = nil
        simklLoadingStartedAt = nil
        simklLoadingDebugInfo = nil
    }

    private func makeSimklHomeLoadingDebugInfo() -> String {
        let profileStore = ProfileSettings.store(for: contentIdentity.profileId)
        let scope = contentIdentity.profileId.trimmingCharacters(in: .whitespacesAndNewlines)
        let authenticated = SimklRuntimeSession.authenticatedState(
            store: profileStore,
            profileScope: scope.isEmpty ? "default" : scope
        ) != nil
        let elapsed = simklLoadingStartedAt.map { Int(Date().timeIntervalSince($0)) } ?? 60

        return [
            "SIMKL DEBUG REPORT",
            "reason=Home Continue Watching did not finish after \(elapsed) seconds",
            "stage=Home Simkl progress refresh",
            "source=\(selectedProgressSource.rawValue)",
            "client_id_configured=\(SimklConfig.isConfigured(in: profileStore))",
            "authenticated=\(authenticated)",
            "home_catalog_loading=\(isLoading)",
            "home_sections=\(store.sections.count)",
            "profile_id=\(contentIdentity.profileId)",
            "app_version=\(SimklConfig.appVersion)",
            "os=\(ProcessInfo.processInfo.operatingSystemVersionString)",
            "next=possible Simkl/network timeout, expired credentials, or Home waiting on a provider response"
        ].joined(separator: "\n")
    }

    private func refreshWatchedTitles() {
        watchedTitleKeys = WatchedStore.visibleWholeTitleIdentityKeys()
    }

    @MainActor
    private func loadLocalTitlesSection() async {
        guard contentIdentity.profileId != "none" && !contentIdentity.profileId.isEmpty else {
            localTitlesSection = nil
            return
        }
        guard smbLocalRowEnabled else {
            localTitlesSection = nil
            return
        }
        let indexed = SMBLibraryIndex.shared.titles()
        guard !indexed.isEmpty else {
            localTitlesSection = nil
            return
        }
        var metasByContentId: [String: NuvioMeta] = [:]
        var iterator = indexed.makeIterator()
        let repository = self.repository
        await withTaskGroup(of: (String, NuvioMeta?).self) { group in
            func startNext() {
                guard let title = iterator.next() else { return }
                group.addTask { @MainActor in
                    (title.contentId, try? await repository.getMetadata(id: title.contentId, type: title.type))
                }
            }
            for _ in 0..<6 { startNext() }
            while let (contentId, meta) = await group.next() {
                if let meta { metasByContentId[contentId] = meta }
                startNext()
            }
        }
        let metas = indexed.compactMap { metasByContentId[$0.contentId] }
        localTitlesSection = metas.isEmpty ? nil : TVHomeSection(
            id: TVHomeSection.localTitlesId,
            title: L10n.string("home_local_titles", fallback: "Local titles"),
            items: metas
        )
    }

    @MainActor
    private func loadJellyfinSection() async {
        guard contentIdentity.profileId != "none" && !contentIdentity.profileId.isEmpty else {
            jellyfinSection = nil
            return
        }
        guard jellyfinLocalRowEnabled else {
            jellyfinSection = nil
            return
        }
        let metas = JellyfinLibraryIndex.shared.titles().compactMap {
            JellyfinLibraryIndex.shared.meta(forContentId: $0.contentId)
        }
        jellyfinSection = metas.isEmpty ? nil : TVHomeSection(
            id: TVHomeSection.jellyfinId,
            title: L10n.string("home_jellyfin_titles", fallback: "Jellyfin"),
            items: metas
        )
    }
}
