import SwiftUI
import Foundation
import UIKit
import ImageIO
import OSLog

/// Three-row Home preview used by the Grid View layout. Every catalog keeps its
/// existing order and title; only its presentation changes to the same 210×315
/// poster geometry used by Search and Library. The eighteenth cell is reserved
/// for See All, so each preview remains exactly six columns by three rows.
struct TVHomeCatalogGridSection: View {
    let section: TVHomeSection
    let watchedTitleKeys: Set<String>
    let initialFocusCardKey: String?
    var externalFocus: FocusState<String?>.Binding? = nil
    var restrictFocusToCardKey: String? = nil
    var suppressFocusAnimations = false
    let onInitialFocusRequested: () -> Void
    let onFocus: (NuvioMeta) -> Void
    let onSelect: (NuvioMeta) -> Void
    var onLongPress: ((NuvioMeta) -> Void)? = nil
    let onSeeAllFocus: () -> Void
    let onSeeAll: () -> Void

    private var previewItems: [NuvioMeta] {
        Array(section.items.prefix(TVHomeGridLayout.previewItemCount))
    }

    private var seeAllKey: String {
        "\(section.id)\u{1}\(TVHomeGridLayout.seeAllID)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(section.title)
                .font(.custom("Inter-Bold", size: 30))
                .foregroundColor(.white)

            LazyVGrid(
                columns: TVHomeGridLayout.gridColumns,
                alignment: .leading,
                spacing: TVHomeGridLayout.itemSpacing
            ) {
                ForEach(previewItems) { item in
                    let cardKey = "\(section.id)\u{1}\(item.id)"
                    let shouldRequestInitialFocus = cardKey == initialFocusCardKey
                    PosterGridCard(
                        meta: item,
                        width: TVHomeGridLayout.posterWidth,
                        height: TVHomeGridLayout.posterHeight,
                        externalFocus: externalFocus,
                        focusValue: cardKey,
                        retainFocusAppearance: restrictFocusToCardKey == cardKey,
                        isWatched: TVHomeGridLayout.isWatched(item, watchedTitleKeys: watchedTitleKeys),
                        shouldRequestInitialFocus: shouldRequestInitialFocus,
                        onInitialFocusRequested: shouldRequestInitialFocus ? onInitialFocusRequested : nil,
                        onFocus: { onFocus($0) }
                    ) {
                        onSelect(item)
                    }
                    .disabled(restrictFocusToCardKey != nil && restrictFocusToCardKey != cardKey)
                }

                TVHomeSeeAllCard(
                    title: section.title,
                    externalFocus: externalFocus,
                    externalFocusValue: seeAllKey,
                    retainFocusAppearance: restrictFocusToCardKey == seeAllKey,
                    onFocus: onSeeAllFocus,
                    action: onSeeAll
                )
                .disabled(restrictFocusToCardKey != nil && restrictFocusToCardKey != seeAllKey)
            }
        }
        .padding(.horizontal, TVLayout.rowLeading)
    }
}


/// Full catalog reached from a Home grid's See All tile. It starts with the
/// already-loaded Home items and continues through pending/network pages as the
/// viewer approaches the end, avoiding a duplicate first-page request.
struct TVHomeCatalogBrowseView: View {
    let section: TVHomeSection
    let repository: CatalogRepository
    let watchedTitleKeys: Set<String>
    let onDismiss: () -> Void
    let onSelect: (NuvioMeta) -> Void
    var onLongPress: ((NuvioMeta) -> Void)? = nil

    @State private var items: [NuvioMeta]
    @State private var pendingItems: [NuvioMeta]
    @State private var nextSkip: Int
    @State private var hasMore: Bool
    @State private var isLoadingMore = false
    @FocusState private var focusedItemID: String?
    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue
    @AppStorage(SettingsKey.posterLabels) private var posterLabels = false
    @AppStorage(SettingsKey.smoothFocus) private var smoothFocus = true
    @AppStorage(SettingsKey.focusHighlighter) private var focusHighlighter = false

    init(
        section: TVHomeSection,
        repository: CatalogRepository,
        watchedTitleKeys: Set<String>,
        onDismiss: @escaping () -> Void,
        onSelect: @escaping (NuvioMeta) -> Void,
        onLongPress: ((NuvioMeta) -> Void)?
    ) {
        self.section = section
        self.repository = repository
        self.watchedTitleKeys = watchedTitleKeys
        self.onDismiss = onDismiss
        self.onSelect = onSelect
        self.onLongPress = onLongPress
        _items = State(initialValue: section.items)
        _pendingItems = State(initialValue: section.pendingItems)
        _nextSkip = State(initialValue: section.nextSkip ?? section.items.count)
        _hasMore = State(initialValue: section.hasMore || !section.pendingItems.isEmpty)
    }

    var body: some View {
        ZStack {
            Color.nuvioBackground(amoled: amoled, body: bodyColor).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(section.title)
                        .font(.system(size: 42, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text("1 catalog")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.white.opacity(0.55))
                }
                .padding(.horizontal, 60)
                .padding(.top, 48)

                ScrollView(.vertical) {
                    LazyVGrid(
                        columns: [GridItem(
                            .adaptive(
                                minimum: CollectionFolderGridMetrics.posterWidth,
                                maximum: CollectionFolderGridMetrics.posterWidth
                            ),
                            spacing: CollectionFolderGridMetrics.posterGap,
                            alignment: .top
                        )],
                        alignment: .leading,
                        spacing: CollectionFolderGridMetrics.posterGap
                    ) {
                        ForEach(items) { item in
                            CollectionFolderResultCard(
                                meta: item,
                                externalFocus: $focusedItemID
                            ) {
                                onSelect(item)
                            }
                            .onAppear {
                                loadMoreIfNeeded(currentItem: item)
                            }
                        }

                        if isLoadingMore {
                            ProgressView()
                                .tint(.white)
                                .scaleEffect(1.25)
                                .frame(
                                    width: CollectionFolderGridMetrics.posterWidth,
                                    height: CollectionFolderGridMetrics.posterHeight
                                )
                        }
                    }
                    .padding(.top, 16)
                    .padding(.horizontal, 60)

                    Color.clear.frame(height: 60)
                }
                .scrollIndicators(.hidden)
                .focusSection()
                .defaultFocusIfAvailable($focusedItemID, items.first?.id)
            }
        }
        .onExitCommand(perform: onDismiss)
    }

    @MainActor
    private func loadMoreIfNeeded(currentItem: NuvioMeta) {
        guard hasMore,
              !isLoadingMore,
              let index = items.firstIndex(where: { $0.id == currentItem.id }),
              index >= max(items.count - TVHomeRowPrefetchThreshold, 0) else { return }

        if !pendingItems.isEmpty {
            let batchCount = min(18, pendingItems.count)
            let batch = Array(pendingItems.prefix(batchCount))
            pendingItems.removeFirst(batchCount)
            // Same TMDB preparation the initial 18 Home items received, so
            // post-18 cards match their shelf artwork (logo/backdrop).
            isLoadingMore = true
            Task { @MainActor in
                defer { isLoadingMore = false }
                let enrichedBatch = await TmdbDetailsService.localizedMetadata(for: batch)
                let currentIDs = Set(items.map(\.id))
                items.append(contentsOf: enrichedBatch.filter { !currentIDs.contains($0.id) })
                hasMore = !pendingItems.isEmpty || (section.contentType != nil && section.catalogId != nil)
            }
            return
        }

        guard let contentType = section.contentType,
              let catalogId = section.catalogId else {
            hasMore = false
            return
        }

        isLoadingMore = true
        let requestedSkip = nextSkip
        Task { @MainActor in
            defer { isLoadingMore = false }
            do {
                let page = try await repository.browseCatalog(
                    addonId: section.addonId,
                    contentType: contentType,
                    catalogId: catalogId,
                    skip: requestedSkip,
                    genre: section.catalogGenre
                )
                let existingIDs = Set(items.map(\.id))
                let newItems = page.items.filter { !existingIDs.contains($0.id) }
                items.append(contentsOf: newItems)
                nextSkip = page.nextSkip ?? (requestedSkip + page.items.count)
                hasMore = page.hasMore && !newItems.isEmpty
            } catch {
                hasMore = false
            }
        }
    }
}
