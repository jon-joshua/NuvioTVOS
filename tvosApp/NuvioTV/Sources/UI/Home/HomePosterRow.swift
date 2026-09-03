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
    private let liquidGlassCards = true

    private let cardWidth: CGFloat = 210
    private let cardHeight: CGFloat = 315
    private let cardSpacing: CGFloat = 28

    /// Matches `HomePosterRow.stripHeight`, so swapping a skeleton for the real
    /// row changes nothing about the rows below it.
    private var stripHeight: CGFloat {
        cardHeight + (posterLabels ? 48 : 0) + TVHomeLayout.stripVerticalPadding * 2
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.custom("Inter-Bold", size: 30))
                .foregroundColor(.white)
                .padding(.leading, TVLayout.rowLeading)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Same definite-size window as `HomePosterRow`: a strip wider than
            // the screen must be clipped here, never allowed to size the parent
            // — that is what used to push the row titles and hero off-screen.
            GeometryReader { geo in
                HStack(alignment: .bottom, spacing: cardSpacing) {
                    // Enough to run past the right edge at either card size, so
                    // the strip reads as a row rather than a few loose tiles.
                    ForEach(0..<9, id: \.self) { _ in
                        LoadingPosterCard(
                            width: cardWidth,
                            height: cardHeight,
                            isLiquidGlassEnabled: liquidGlassCards
                        )
                    }
                }
                .padding(.leading, TVLayout.rowLeading)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
                .clipped()
            }
            .frame(height: stripHeight)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One Home shelf: a title over a native horizontal row of `PosterCard`s that
/// keeps the focused card pinned under the title (see `PinnedHorizontalRow`).
struct HomePosterRow: View {
    let id: String
    let title: String
    let horizontalEdgeInset: CGFloat
    let items: [NuvioMeta]
    var progressByItemId: [String: ContinueWatchingItem] = [:]
    var watchedTitleKeys: Set<String> = []
    var initialScrollIndex: Int = 0
    /// See TVHomeView.resetRowsForRail.
    var resetGeneration: Int = 0
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
    var isRowFocused: Bool = false
    let onInitialFocusRequested: () -> Void
    let onFocus: (NuvioMeta) -> Void
    let onBlur: (NuvioMeta) -> Void
    let onApproachEnd: (NuvioMeta) -> Void
    let onSelect: (NuvioMeta) -> Void
    var onLongPress: ((NuvioMeta) -> Void)? = nil
    var onOpenDetails: ((NuvioMeta) -> Void)? = nil
    var onPlayContinueWatchingManually: ((ContinueWatchingItem) -> Void)? = nil
    var onStartContinueWatchingFromBeginning: ((ContinueWatchingItem) -> Void)? = nil
    var onRemoveFromContinueWatching: ((ContinueWatchingItem) -> Void)? = nil

    /// Meta id of the card pinned to the gutter — the `ForEach` identity the
    /// scroll view positions on. Nil until the row has laid out once.
    @State private var leadingCardID: String?
    @AppStorage(SettingsKey.posterLabels) private var posterLabels = false
    private let smoothFocus = true
    @AppStorage(SettingsKey.focusHighlighter) private var focusHighlighter = false

    private var compactPosterWidth: CGFloat {
        210
    }

    private var rowSpacing: CGFloat {
        28
    }

    private var rowPrefix: String { "\(id)\u{1}" }

    private var cardFocusAnimations: Bool { smoothFocus && !suppressFocusAnimations }

    /// Index of the pinned card. On the row's first frame this falls back to the
    /// caller's cached index, so a remounted row never draws at card 0 first.
    private var pinnedIndex: Int {
        guard !items.isEmpty else { return 0 }
        if let leadingCardID, let index = items.firstIndex(where: { $0.id == leadingCardID }) {
            return index
        }
        return min(max(initialScrollIndex, 0), items.count - 1)
    }

    /// The scroll view's position binding. Reads the cached index until the
    /// first focus; after that `leadingCardID` owns it. One writer only: the
    /// row. `.scrollPosition` writes back whatever sits at the anchor after a
    /// scroll it performed itself (initial layout, the focus engine's reveal),
    /// and that is not the focused card, so it must not steer `pinnedIndex`,
    /// default focus or the disabled mask.
    private var scrollTarget: Binding<String?> {
        Binding(
            get: { leadingCardID ?? (items.isEmpty ? nil : items[pinnedIndex].id) },
            set: { _ in }
        )
    }


    // Card height (315) + vertical breathing room for the focus border/shadow.
    private var stripHeight: CGFloat {
        let imageHeight: CGFloat = 315
        return imageHeight + (posterLabels ? 48 : 0) + TVHomeLayout.stripVerticalPadding * 2
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
        return rowPrefix + items[pinnedIndex].id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Keep the section title above the card strip (landscape art / focus
            // scale can overflow the strip and would otherwise paint over it).
            Text(title)
                .font(.custom("Inter-Bold", size: 30))
                .foregroundColor(.white)
                .padding(.leading, TVLayout.rowLeading)
                .offset(y: 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .zIndex(1)

            cardStrip
                .zIndex(0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
        .defaultFocusIfAvailable(externalFocus, defaultFocusCardKey)
        .onChange(of: resetGeneration) { _, _ in resetToStart() }
        // A card that must take focus has to exist first (see `pinIfInRow`).
        .onAppear {
            pinIfInRow(initialFocusCardKey)
        }
        .onChange(of: initialFocusCardKey) { _, key in pinIfInRow(key) }
    }

    private var cardStrip: some View {
        // Resolve the pinned index once per row pass. `pinnedIndex` is a linear
        // scan of `items`, and every card used to run it from `.disabled`.
        let pinned = pinnedIndex
        return PinnedHorizontalRow(
            items: items,
            spacing: rowSpacing,
            leadingMargin: TVLayout.rowLeading,
            // Cards run off the physical right edge, as the hero does.
            trailingBleed: horizontalEdgeInset,
            animation: cardFocusAnimations ? TVHomeLayout.scrollAnimation : nil,
            pinnedID: scrollTarget
        ) { index, item in
            card(for: item, at: index, pinnedIndex: pinned)
                // Room for the focus scale and shadow inside the scroll view's clip.
                .padding(.vertical, TVHomeLayout.stripVerticalPadding)
        }
        // The landscape card widens its cell and pushes trailing siblings.
        .animation(cardFocusAnimations ? TVHomeLayout.scrollAnimation : nil, value: landscapeFocusedId)
        // No fixed height: the row is as tall as its padded cards, so no card is ever
        // partially clipped and the outer list never nudges to reveal one.
    }

    @ViewBuilder
    private func card(for item: NuvioMeta, at index: Int, pinnedIndex pinned: Int) -> some View {
        let cardKey = rowPrefix + item.id
        let shouldRequestInitialFocus = cardKey == initialFocusCardKey
        let progressItem = progressByItemId[item.id]
        PosterCard(
            meta: item,
            isLandscape: landscapeFocusedId == cardKey,
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
            onLongPress: onLongPress,
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
            showPosterLabels: posterLabels,
            smoothFocusAnimations: cardFocusAnimations,
            focusHighlighterEnabled: focusHighlighter,
            allowsFocus: true,
            isWatched: isWatched(item)
        ) {
            onSelect(item)
        }
        // `PosterCard.==` ignores the closures built above, so an unchanged
        // card skips its body entirely when the row re-evaluates.
        .equatable()
        .disabled(!isRowFocused && index != pinned)
    }

    /// Pin the focused card, then let the host react (paging, backdrop, store).
    private func handleFocus(_ meta: NuvioMeta, at index: Int) {
        if cardFocusAnimations {
            withAnimation(TVHomeLayout.scrollAnimation) { leadingCardID = meta.id }
        } else {
            withTransaction(Transaction(animation: nil)) { leadingCardID = meta.id }
        }
        onScrollIndexChange(index)
        onApproachEnd(meta)
        onFocus(meta)
    }

    /// Rail opened: back to the first card (see TVHomeView.resetRowsForRail).
    private func resetToStart() {
        withAnimation(NuvioMotion.settle) { leadingCardID = items.first?.id }
        onScrollIndexChange(0)
    }

    /// `LazyHStack` only builds cards near the viewport, so a card that must take
    /// focus (initial focus, overlay return) is pinned first — that mounts it,
    /// and `PosterCard.onAppear` / the focus engine can then land on it.
    private func pinIfInRow(_ cardKey: String?) {
        guard let cardKey, cardKey.hasPrefix(rowPrefix) else { return }
        let itemID = String(cardKey.dropFirst(rowPrefix.count))
        guard items.contains(where: { $0.id == itemID }) else { return }
        withTransaction(Transaction(animation: nil)) { leadingCardID = itemID }
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
            // only consulted before the first focus, when `leadingCardID` is nil.
            && lhs.resetGeneration == rhs.resetGeneration
            && lhs.initialFocusCardKey == rhs.initialFocusCardKey
            && lhs.landscapeFocusedId == rhs.landscapeFocusedId
            && lhs.suppressFocusAnimations == rhs.suppressFocusAnimations
            && lhs.isRowFocused == rhs.isRowFocused
    }
}
