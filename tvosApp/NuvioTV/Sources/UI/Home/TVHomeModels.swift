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

enum TVHomeGridLayout {
    static let columns = 7
    static let rows = 3
    static let previewItemCount = columns * rows - 1
    // Same poster geometry as the See All catalog this grid links into
    // (`CollectionFolderGridMetrics`), so a title is the same size on both.
    static let posterWidth: CGFloat = 210
    static let posterHeight: CGFloat = 315
    static let itemSpacing: CGFloat = 28
    static let sectionSpacing: CGFloat = 54
    static let heroPageLimit = 7
    static let seeAllID = "__see_all__"

    static var gridColumns: [GridItem] {
        Array(
            repeating: GridItem(.fixed(posterWidth), spacing: itemSpacing, alignment: .top),
            count: columns
        )
    }

    static func isWatched(_ item: NuvioMeta, watchedTitleKeys: Set<String>) -> Bool? {
        let type = item.type.lowercased()
        let titleWatched = !watchedTitleKeys.isDisjoint(
            with: WatchedStore.catalogTitleIdentityKeys(for: item)
        )
        guard ["series", "tv", "show", "tvshow"].contains(type) else {
            return titleWatched
        }
        return titleWatched ? true : nil
    }
}

/// Shared Home vertical rhythm for catalog *and* collection folder rows.
enum TVHomeLayout {
    static let sectionSpacing: CGFloat = 28
    /// Keep the first catalog heading close to the hero description.
    static let heroBottomPadding: CGFloat = 20
    static let rowsTopPadding: CGFloat = 4
    /// Extra scroll room so the last row can reach the same fixed anchor as
    /// earlier rows instead of being clamped to the viewport bottom.
    static let finalRowScrollRunway: CGFloat = 24
    /// Focus breathing room above/below cards inside a strip.
    static let stripVerticalPadding: CGFloat = 24
    /// Section title line (~30pt) + VStack spacing under the title (~10pt) + slack.
    static let rowTitleBlock: CGFloat = 46

    /// Horizontal strip motion with no spring settling.
    static let scrollAnimation = NuvioMotion.scroll
    /// Keep successive remote presses from stacking long-running vertical
    /// transactions while retaining a visible native scroll transition.
    static let verticalScrollAnimation = NuvioMotion.settle
}
