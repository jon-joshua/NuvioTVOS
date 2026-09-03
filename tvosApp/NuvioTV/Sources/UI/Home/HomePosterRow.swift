import SwiftUI

/// A row whose catalog is still in flight: its real title over a lightweight
/// skeleton strip, sized exactly like `HomePosterRow` so the row keeps its height
/// and the rows below it do not jump when the real cards arrive.
///
/// The Android app draws this same skeleton with a shimmer sweep; here each card
/// uses the app's existing glass loading treatment. Deliberately not focusable —
/// focus lands on the first row that has real titles, so the user is never parked
/// on a card that is about to become something else.
struct TVLoadingCatalogRow: View {
    let title: String

    @AppStorage(SettingsKey.posterLabels) private var posterLabels = false

    private let cardWidth: CGFloat = 260
    private let cardHeight: CGFloat = 390
    private let cardSpacing: CGFloat = 40

    /// Matches `HomePosterRow.stripHeight`, so swapping a skeleton for the real
    /// row changes nothing about the rows below it.
    private var stripHeight: CGFloat {
        cardHeight + (posterLabels ? TVHomeLayout.captionBlock : 0)
    }

    var body: some View {
        // A definite-size window: a strip wider than the screen must be clipped
        // here, never allowed to size the parent.
        GeometryReader { geo in
                HStack(alignment: .bottom, spacing: cardSpacing) {
                    // Enough to run past the right edge at either card size, so
                    // the strip reads as a row rather than a few loose tiles.
                    ForEach(0..<9, id: \.self) { _ in
                        LoadingPosterCard(width: cardWidth, height: cardHeight)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
                .clipped()
            }
        .frame(height: stripHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One Home shelf: a title over a native horizontal row of `PosterCard`s. Focus
/// moves freely across the visible cards; the row scrolls only when the focus
/// engine has to reveal a card at an edge, as the Apple TV app does.
struct HomePosterRow: View {
    let id: String
    let title: String
    let horizontalEdgeInset: CGFloat
    let items: [NuvioMeta]
    var progressByItemId: [String: ContinueWatchingItem] = [:]
    var watchedTitleKeys: Set<String> = []
    var initialScrollIndex: Int = 0
    var onScrollIndexChange: (Int) -> Void = { _ in }
    /// Composite key ("<sectionId>\u{1}<metaId>") of the card that should take
    /// focus on appear — the first card on a fresh load, or the card the user
    /// left on when returning from details.
    let initialFocusCardKey: String?
    let landscapeFocusedId: String?
    var externalFocus: FocusState<String?>.Binding? = nil
    /// Suppresses the one focus/layout animation caused by returning to Home
    /// from another tab. Normal left/right focus animation remains enabled.
    var suppressFocusAnimations: Bool = false
    let onInitialFocusRequested: () -> Void
    let onFocus: (NuvioMeta) -> Void
    let onBlur: (NuvioMeta) -> Void
    let onApproachEnd: (NuvioMeta) -> Void
    let onSelect: (NuvioMeta) -> Void
    var onOpenDetails: ((NuvioMeta) -> Void)? = nil
    var onPlayContinueWatchingManually: ((ContinueWatchingItem) -> Void)? = nil
    var onStartContinueWatchingFromBeginning: ((ContinueWatchingItem) -> Void)? = nil
    var onRemoveFromContinueWatching: ((ContinueWatchingItem) -> Void)? = nil

    /// Programmatic scroll target only: the rail reset and a card that must be
    /// mounted before it can take focus. Nil the rest of the time; the focus
    /// engine scrolls the row itself when focus reaches an edge, as tvOS does.
    @State private var scrollTargetID: String?
    @AppStorage(SettingsKey.posterLabels) private var posterLabels = false
    private let smoothFocus = true

    private var compactPosterWidth: CGFloat {
        260
    }

    private var rowSpacing: CGFloat {
        40
    }

    private var rowPrefix: String { "\(id)\u{1}" }

    /// Continue Watching and Upcoming are landscape rows, like the TV app's
    /// Up Next: the episode still with title and progress on it.
    private var isLandscapeRow: Bool {
        id == TVHomeSection.continueWatchingId || id == TVHomeSection.upcomingId
    }

    private var cardFocusAnimations: Bool { smoothFocus && !suppressFocusAnimations }

    /// The card focus last rested on, from the host.s cache. Default focus for
    /// re-entering the row, and the initial scroll target for a remounted row.
    private var lastFocusedIndex: Int {
        guard !items.isEmpty else { return 0 }
        return min(max(initialScrollIndex, 0), items.count - 1)
    }

    /// One writer only: the row. `.scrollPosition` writes back whatever sits at
    /// the anchor after a scroll it performed itself, which is not something
    /// the row needs to know.
    private var scrollTarget: Binding<String?> {
        Binding(get: { scrollTargetID }, set: { _ in })
    }


    // Card height plus vertical breathing room for the focus lift.
    private var stripHeight: CGFloat {
        if isLandscapeRow { return TVHomeLayout.landscapeRowCardSize.height }
        return 390 + (posterLabels ? TVHomeLayout.captionBlock : 0)
    }

    private func isWatched(_ item: NuvioMeta) -> Bool? {
        let normalizedType = item.type.lowercased()
        let titleWatched = !watchedTitleKeys.isDisjoint(
            with: WatchedStore.catalogTitleIdentityKeys(for: item)
        )
        guard ["series", "tv", "show", "tvshow"].contains(normalizedType) else {
            return titleWatched
        }
        // A whole-series action writes a local aggregate marker plus episode
        // rows. Return the marker immediately, just like movie cards; when it
        // is absent, nil lets WatchedCheckmarkBadge resolve episode completion.
        return titleWatched ? true : nil
    }

    private var defaultFocusCardKey: String? {
        guard !items.isEmpty else { return nil }
        return rowPrefix + items[lastFocusedIndex].id
    }

    var body: some View {
        cardStrip
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
        .defaultFocusIfAvailable(externalFocus, defaultFocusCardKey)
        // A card that must take focus has to exist first (see `pinIfInRow`).
        .onAppear {
            // A remounted row starts where focus last was, not at card 0.
            if scrollTargetID == nil, lastFocusedIndex > 0 {
                scrollTargetID = items[lastFocusedIndex].id
            }
            pinIfInRow(initialFocusCardKey)
        }
        .onChange(of: initialFocusCardKey) { _, key in pinIfInRow(key) }
    }

    private var cardStrip: some View {
        PinnedHorizontalRow(
            items: items,
            spacing: rowSpacing,
            // The gutter is the list's safe area now; the scroll view insets to it.
            leadingMargin: 0,
            // Cards run off the physical right edge, as the hero does.
            trailingBleed: horizontalEdgeInset,
            animation: cardFocusAnimations ? TVHomeLayout.scrollAnimation : nil,
            pinnedID: scrollTarget
        ) { index, item in
            card(for: item, at: index)
        }
        // The landscape card widens its cell and pushes trailing siblings.
        .animation(cardFocusAnimations ? TVHomeLayout.scrollAnimation : nil, value: landscapeFocusedId)
        // No fixed height and no clip: the lifted card draws outside the row.
    }

    @ViewBuilder
    private func card(for item: NuvioMeta, at index: Int) -> some View {
        let cardKey = rowPrefix + item.id
        let shouldRequestInitialFocus = cardKey == initialFocusCardKey
        let progressItem = progressByItemId[item.id]
        PosterCard(
            meta: item,
            // Focus expansion off: neither the TV app nor Plex widens a poster on focus.
            isLandscape: false,
            continueProgress: progressItem?.progress,
            continueRemainingText: progressItem?.remainingText,
            continueEpisodeText: progressItem?.episodeLabel,
            continueEpisodeTitleText: progressItem?.episodeDisplayTitle,
            continueEpisodeArtworkURL: progressItem?.episodeArtworkURL,
            continueIsUpNext: progressItem?.isUpNextEntry == true,
            continueUpNextBadgeText: progressItem?.upNextBadgeText,
            showsWatchedBadge: id != TVHomeSection.continueWatchingId && id != TVHomeSection.upcomingId,
            shouldRequestInitialFocus: shouldRequestInitialFocus,
            onInitialFocusRequested: shouldRequestInitialFocus ? onInitialFocusRequested : nil,
            onFocus: { handleFocus($0, at: index) },
            onBlur: onBlur,
            externalFocus: externalFocus,
            externalFocusValue: cardKey,
            onOpenDetails: onOpenDetails != nil ? { onOpenDetails?(item) } : nil,
            onPlayManually: ((id == TVHomeSection.continueWatchingId || id == TVHomeSection.upcomingId) && progressItem != nil) ? {
                if let p = progressItem { onPlayContinueWatchingManually?(p) }
            } : nil,
            onStartFromBeginning: ((id == TVHomeSection.continueWatchingId || id == TVHomeSection.upcomingId) && progressItem != nil) ? {
                if let p = progressItem { onStartContinueWatchingFromBeginning?(p) }
            } : nil,
            onRemoveFromContinueWatching: ((id == TVHomeSection.continueWatchingId || id == TVHomeSection.upcomingId) && progressItem != nil) ? {
                if let p = progressItem { onRemoveFromContinueWatching?(p) }
            } : nil,
            isWatched: isWatched(item),
            fixedLandscapeSize: isLandscapeRow ? TVHomeLayout.landscapeRowCardSize : nil
        ) {
            onSelect(item)
        }
        // `PosterCard.==` ignores the closures built above, so an unchanged
        // card skips its body entirely when the row re-evaluates.
        .equatable()
    }

    /// Focus moved: remember where, and let the host react (paging, backdrop).
    /// The row itself does not scroll; the focus engine reveals the card only
    /// when it would leave the visible area.
    private func handleFocus(_ meta: NuvioMeta, at index: Int) {
        onScrollIndexChange(index)
        onApproachEnd(meta)
        onFocus(meta)
    }

    /// `LazyHStack` only builds cards near the viewport, so a card that must take
    /// focus (initial focus, overlay return) is scrolled to first; that mounts
    /// it, and `PosterCard.onAppear` / the focus engine can then land on it.
    private func pinIfInRow(_ cardKey: String?) {
        guard let cardKey, cardKey.hasPrefix(rowPrefix) else { return }
        let itemID = String(cardKey.dropFirst(rowPrefix.count))
        guard items.contains(where: { $0.id == itemID }) else { return }
        withTransaction(Transaction(animation: nil)) { scrollTargetID = itemID }
    }
}


// Keep row identity and horizontal state stable, while allowing the focused
// vertical window to swap lightweight shells for real poster cards.
extension HomePosterRow: Equatable {
    static func == (lhs: HomePosterRow, rhs: HomePosterRow) -> Bool {
        return lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.horizontalEdgeInset == rhs.horizontalEdgeInset
            && lhs.items == rhs.items
            && lhs.watchedTitleKeys == rhs.watchedTitleKeys
            // `initialScrollIndex` is deliberately not compared: the host reads
            // it back from the store this row's own focus callback just wrote,
            // so it changes on every press and would defeat the gate. It is
            // only consulted when the row mounts and when focus re-enters it.
            && lhs.initialFocusCardKey == rhs.initialFocusCardKey
            && lhs.landscapeFocusedId == rhs.landscapeFocusedId
            && lhs.suppressFocusAnimations == rhs.suppressFocusAnimations
    }
}
