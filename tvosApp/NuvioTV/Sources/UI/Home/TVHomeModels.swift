import SwiftUI
import Foundation
import UIKit
import ImageIO
import OSLog

struct TVHomeSection: Identifiable {
    static let continueWatchingId = "continue_watching"
    static let upcomingId = "upcoming"
    static let localTitlesId = "local_titles"
    static let jellyfinId = "jellyfin_titles"
    /// Id prefix for rows built from account-synced collections.
    static let collectionIdPrefix = "collection_"

    let id: String
    let title: String
    var items: [NuvioMeta]
    var contentType: String? = nil
    var catalogId: String? = nil
    var addonId: String? = nil
    /// Display name of the add-on this row came from, for the Settings list.
    var addonName: String? = nil
    var catalogGenre: String? = nil
    /// Items already returned by the first add-on response but not mounted yet.
    var pendingItems: [NuvioMeta] = []
    var nextSkip: Int? = nil
    var hasMore: Bool = false
    var isLoadingMore: Bool = false
    /// A row the last Home had, whose catalog request has not answered yet. It
    /// holds the row's place with spinner cards instead of letting the row pop
    /// in underneath the user later. Mirrors the Android app, which seeds the
    /// same skeleton from placeholder items (it shimmers where this spins).
    var isLoadingPlaceholder: Bool = false
    /// Pinned collections render above the standard catalog rows.
    var isPinnedCollection: Bool = false
    /// Folder cards for a collection row (emoji / cover tiles). When non-empty,
    /// Home renders `TVCollectionFolderRow` with the same paging rhythm as
    /// catalog rows; catalogs stay grouped inside folders.
    var collectionFolders: [TVCollectionFolderItem] = []

    var isCollectionRow: Bool { id.hasPrefix(Self.collectionIdPrefix) }
    /// Skeletons count as content so every consumer — row rendering, the
    /// materialization window, paging offsets — sees one list with one set of
    /// indices. The few places that need a *real* row (hero, initial focus)
    /// filter on `isLoadingPlaceholder` instead.
    var hasContent: Bool { !items.isEmpty || !collectionFolders.isEmpty || isLoadingPlaceholder }

    /// The key this row is hidden/shown by, in the account's format. Collections
    /// use `collection_<id>`; catalogs use `<addonId>_<type>_<catalogId>`, with
    /// the built-in rows attributed to Cinemeta since they have no manifest of
    /// their own. Nil for rows that are not a catalog at all (Continue
    /// Watching), which therefore cannot be toggled.
    var catalogSettingsKey: String? {
        if isCollectionRow { return id }
        guard let contentType, let catalogId else { return nil }
        return TVHomeCatalogOrder.catalogSettingsKey(
            addonId: addonId ?? CinemetaCatalogRepository.cinemetaAddonId,
            contentType: contentType,
            catalogId: catalogId
        )
    }
}

/// Cache key for the profile-scoped inputs that build Home's catalog tree.
/// The sync revision is retained by `NuvioSyncManager`, so Home sees the latest
/// identity even when account sync finishes before this view is mounted.
struct TVHomeContentIdentity: Hashable {
    let profileId: String
    let catalogRevision: UInt
}

/// Holds the Home screen's browsing state outside `TVHomeView` so it survives
/// the details/player push (which tears the view down). Owned by `ContentView`;
/// lets returning from a card restore the cached catalog + the focused card
/// instead of reloading and jumping back to the top.
final class TVHomeStore: ObservableObject {
    @Published var sections: [TVHomeSection] = [] {
        didSet { sectionsRevision &+= 1 }
    }
    /// Bumped on every replacement or in-place mutation of `sections`, so Home
    /// can memoise derived arrays without comparing the sections themselves.
    private(set) var sectionsRevision = 0
    @Published var hero: NuvioMeta?
    /// True when any last-known-good tree is available. Cache reuse additionally
    /// requires `loadedContentIdentity` to match the requested profile/revision.
    @Published private(set) var hasLoaded = false
    /// Composite "<sectionId>\u{1}<metaId>" key of the last focused card.
    var lastFocusedCardID: String?
    private var loadedContentIdentity: TVHomeContentIdentity?
    private var loadingContentIdentity: TVHomeContentIdentity?
    private var loadGeneration: UInt = 0
    /// Screen-scoped work keyed by purpose ("catalog", "collections", ...).
    /// Owned here rather than by `.task` modifiers on the Home view: pushing
    /// Details on the navigation stack fires Home's `onDisappear`, which would
    /// cancel every view-owned task and rerun it on pop, reloading Home on
    /// every return.
    private var tasks: [String: Task<Void, Never>] = [:]

    /// Runs `operation` under `key`, cancelling whatever ran under it before.
    func run(_ key: String, _ operation: @escaping @MainActor () async -> Void) {
        tasks[key]?.cancel()
        tasks[key] = Task { @MainActor in
            await operation()
        }
    }

    func cancel(_ key: String) {
        tasks[key]?.cancel()
        tasks[key] = nil
    }

    func isLoaded(for identity: TVHomeContentIdentity) -> Bool {
        hasLoaded && loadedContentIdentity == identity
    }

    func isLoading(for identity: TVHomeContentIdentity) -> Bool {
        loadingContentIdentity == identity
    }

    @discardableResult
    func beginLoad(for identity: TVHomeContentIdentity) -> UInt {
        let previousProfileId = loadedContentIdentity?.profileId
            ?? loadingContentIdentity?.profileId
        if let previousProfileId, previousProfileId != identity.profileId {
            sections = []
            hero = nil
            lastFocusedCardID = nil
            loadedContentIdentity = nil
        }

        loadGeneration &+= 1
        loadingContentIdentity = identity
        hasLoaded = false
        return loadGeneration
    }

    func isCurrentLoad(
        _ generation: UInt,
        for identity: TVHomeContentIdentity
    ) -> Bool {
        loadGeneration == generation && loadingContentIdentity == identity
    }

    func finishLoad(
        _ generation: UInt,
        for identity: TVHomeContentIdentity
    ) {
        guard isCurrentLoad(generation, for: identity) else { return }
        loadedContentIdentity = identity
        loadingContentIdentity = nil
        hasLoaded = true
    }

    func cancelLoad(
        _ generation: UInt,
        for identity: TVHomeContentIdentity
    ) {
        guard isCurrentLoad(generation, for: identity) else { return }
        loadingContentIdentity = nil
        hasLoaded = loadedContentIdentity != nil
    }

    func reset() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        loadGeneration &+= 1
        sections = []
        hero = nil
        hasLoaded = false
        lastFocusedCardID = nil
        loadedContentIdentity = nil
        loadingContentIdentity = nil
    }
}

// Android triggers pagination from the last visible card, six cards from the
// end. tvOS triggers from the focused card instead, so include the roughly six
// cards already visible ahead of focus to give network requests the same runway.
let TVHomeRowPrefetchThreshold = 12


/// Shared Home vertical rhythm for catalog *and* collection folder rows.
enum TVHomeLayout {
    static let sectionSpacing: CGFloat = 26
    /// Extra room under a row so the next section title sits about 90pt below
    /// the posters, as in the TV app, while the title-to-row gap stays at
    /// `sectionSpacing`.
    static let rowBottomSpacing: CGFloat = 64
    /// Keep the first catalog heading close to the hero description.
    static let heroBottomPadding: CGFloat = 20
    /// Headroom under the hero so a focused top row lifts inside the list's
    /// clip. The hero sits above the list, so the list must keep clipping.
    static let rowsTopPadding: CGFloat = 30
    /// Extra scroll room so the last row can reach the same fixed anchor as
    /// earlier rows instead of being clamped to the viewport bottom.
    static let finalRowScrollRunway: CGFloat = 24
    /// Focus breathing room above/below cards inside a strip.
    static let stripVerticalPadding: CGFloat = 24
    /// Shelf title: the tvOS Headline style, as the TV app uses for its rows.
    static let rowTitleFont: Font = .system(size: 38, weight: .semibold)
    /// Title to strip. The strip already carries `stripVerticalPadding` above
    /// its cards, so the visible gap is the sum: 30pt, which clears the lift.
    static let rowTitleSpacing: CGFloat = 6
    /// Section header line (~46pt) + `sectionSpacing` under it.
    static let rowTitleBlock: CGFloat = 72
    /// Two caption lines under a poster (25pt + 23pt) plus their spacing.
    static let captionBlock: CGFloat = 64
    /// Continue Watching lockup: the HIG five-column width at 16:9, like the
    /// TV app's Up Next row.
    static let landscapeRowCardSize = CGSize(width: 320, height: 180)

    /// Horizontal strip motion with no spring settling.
    static let scrollAnimation = NuvioMotion.scroll
    /// Keep successive remote presses from stacking long-running vertical
    /// transactions while retaining a visible native scroll transition.
    static let verticalScrollAnimation = NuvioMotion.settle
}
