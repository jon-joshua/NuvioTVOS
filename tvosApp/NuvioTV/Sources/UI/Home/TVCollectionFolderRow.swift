import SwiftUI
import Foundation
import UIKit
import ImageIO
import OSLog

// MARK: - Collection folder row (Home)

/// Shared sizing for collection folder tiles.
/// All shapes share the same poster height; width varies by `tileShape`
/// (poster / square / landscape) so mixed shapes align on one baseline.
private enum TVCollectionFolderCardLayout {
    static func cardHeight(layoutMode: String) -> CGFloat {
        layoutMode == "Compact" ? 255 : 315
    }

    /// Width from fixed height × shape aspect ratio.
    /// Matches Settings `CollectionTileShapePreview` and keeps landscape/square
    /// the same height as portrait — only wider.
    static func cardWidth(shape: CollectionTileShape, layoutMode: String) -> CGFloat {
        let height = cardHeight(layoutMode: layoutMode)
        switch shape {
        case .poster:
            // Match catalog `PosterCard` portrait width exactly.
            return layoutMode == "Compact" ? 170 : 210
        case .landscape:
            // Match PosterCard's focused Home landscape width exactly.
            return layoutMode == "Compact" ? (height * CGFloat(shape.aspectRatio)).rounded() : 560
        case .square:
            return (height * CGFloat(shape.aspectRatio)).rounded()
        }
    }

    static func rowSpacing(layoutMode: String) -> CGFloat {
        layoutMode == "Compact" ? 22 : 28
    }

    /// Leading-edge offset of the card at `index` (sum of prior widths + gaps).
    static func scrollOffset(
        to index: Int,
        folders: [TVCollectionFolderItem],
        layoutMode: String
    ) -> CGFloat {
        guard index > 0 else { return 0 }
        let spacing = rowSpacing(layoutMode: layoutMode)
        var offset: CGFloat = 0
        let end = min(index, folders.count)
        for i in 0..<end {
            offset += cardWidth(shape: folders[i].tileShape, layoutMode: layoutMode) + spacing
        }
        return offset
    }
}

/// Home row for a synced collection — same structure as `TVCatalogRow`
/// (title + clipping poster strip + horizontal paging). Cards look like
/// `PosterCard`; tap opens the folder instead of title details.
struct TVCollectionFolderRow: View {
    let id: String
    let title: String
    let horizontalEdgeInset: CGFloat
    let folders: [TVCollectionFolderItem]
    let initialScrollIndex: Int
    /// See TVHomeView.resetRowsForRail.
    var resetGeneration: Int = 0
    let onScrollIndexChange: (Int) -> Void
    let initialFocusCardKey: String?
    var externalFocus: FocusState<String?>.Binding? = nil
    var restrictFocusToCardKey: String? = nil
    var retainFocusAppearanceForCardKey: String? = nil
    var suppressFocusAnimations = false
    var isRowFocused = false
    let onInitialFocusRequested: () -> Void
    let onFocus: (TVCollectionFolderItem) -> Void
    let onSelect: (TVCollectionFolderItem) -> Void

    @State private var scrollIndex: Int?
    @AppStorage(SettingsKey.homeLayout) private var homeLayout = "Modern"
    @AppStorage(SettingsKey.posterLabels) private var posterLabels = false
    @AppStorage(SettingsKey.smoothFocus) private var smoothFocus = true
    @AppStorage(SettingsKey.focusHighlighter) private var focusHighlighter = false

    private var effectiveScrollIndex: Int {
        let raw = scrollIndex ?? initialScrollIndex
        guard !folders.isEmpty else { return 0 }
        return min(max(raw, 0), folders.count - 1)
    }

    private var rowSpacing: CGFloat {
        TVCollectionFolderCardLayout.rowSpacing(layoutMode: homeLayout)
    }

    private var imageHeight: CGFloat {
        TVCollectionFolderCardLayout.cardHeight(layoutMode: homeLayout)
    }

    /// Same strip math as `TVCatalogRow`.
    private var stripHeight: CGFloat {
        imageHeight + (showsAnyLabels ? 48 : 0) + TVHomeLayout.stripVerticalPadding * 2
    }

    private var showsAnyLabels: Bool {
        posterLabels && folders.contains { !$0.hideTitle }
    }

    /// Match `TVCatalogRow`'s bounded focus graph while accounting for mixed
    /// poster, square, and landscape widths. Keep one complete screen ahead and
    /// four cards behind so the next focus target already exists before tvOS
    /// starts a horizontal move.
    private func materializedCardIndices(
        stripWidth: CGFloat,
        layoutMode: String
    ) -> [Int] {
        guard !folders.isEmpty else { return [] }

        let focusIndex = effectiveScrollIndex
        var lowerBound = max(0, focusIndex - 4)
        var upperBound = focusIndex
        let spacing = TVCollectionFolderCardLayout.rowSpacing(layoutMode: layoutMode)
        var coveredWidth: CGFloat = 0

        for index in focusIndex..<folders.count {
            coveredWidth += TVCollectionFolderCardLayout.cardWidth(
                shape: folders[index].tileShape,
                layoutMode: layoutMode
            ) + spacing
            upperBound = index
            if coveredWidth >= stripWidth { break }
        }

        // A restored focus target must be mounted even if the persisted scroll
        // index has not caught up with it yet.
        let rowPrefix = "\(id)\u{1}"
        for key in [initialFocusCardKey, restrictFocusToCardKey] {
            guard let key, key.hasPrefix(rowPrefix) else { continue }
            let folderID = String(key.dropFirst(rowPrefix.count))
            if let targetIndex = folders.firstIndex(where: { $0.id == folderID }) {
                lowerBound = min(lowerBound, targetIndex)
                upperBound = max(upperBound, targetIndex)
            }
        }

        return Array(lowerBound...upperBound)
    }

    private var defaultFocusFolderKey: String? {
        guard !folders.isEmpty else { return nil }
        let idx = effectiveScrollIndex
        return "\(id)\u{1}\(folders[idx].id)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.custom("Inter-Bold", size: 30))
                .foregroundColor(.white)
                .padding(.leading, TVLayout.rowLeading)
                .offset(y: 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .zIndex(2)

            cardStrip
                .zIndex(0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
.onChange(of: resetGeneration) { _, _ in resetToStart() }
        .defaultFocusIfAvailable(externalFocus, defaultFocusFolderKey)
    }

    private var cardStrip: some View {
        GeometryReader { geo in
            let stripWidth = max(1920, geo.size.width + horizontalEdgeInset * 2)
            let rowHomeLayout = homeLayout
            let rowPosterLabels = posterLabels
            let rowSmoothFocus = smoothFocus
            let rowFocusHighlighter = focusHighlighter
            let rowSpacing = TVCollectionFolderCardLayout.rowSpacing(layoutMode: rowHomeLayout)
            let scrollX = TVCollectionFolderCardLayout.scrollOffset(
                to: effectiveScrollIndex,
                folders: folders,
                layoutMode: rowHomeLayout
            )
            let materializedIndices = materializedCardIndices(
                stripWidth: stripWidth,
                layoutMode: rowHomeLayout
            )

            HStack(alignment: .top, spacing: rowSpacing) {
                ForEach(materializedIndices, id: \.self) { index in
                    let folder = folders[index]
                    let cardKey = "\(id)\u{1}\(folder.id)"
                    let shouldRequestInitialFocus = cardKey == initialFocusCardKey
                    TVCollectionFolderCard(
                        folder: folder,
                        shouldRequestInitialFocus: shouldRequestInitialFocus,
                        onInitialFocusRequested: shouldRequestInitialFocus ? onInitialFocusRequested : nil,
                        externalFocus: externalFocus,
                        externalFocusValue: cardKey,
                        onFocus: {
                            if effectiveScrollIndex != index {
                                scrollIndex = index
                                onScrollIndexChange(index)
                            }
                            onFocus(folder)
                        },
                        layoutMode: rowHomeLayout,
                        showPosterLabels: rowPosterLabels,
                        smoothFocusAnimations: rowSmoothFocus,
                        focusHighlighterEnabled: rowFocusHighlighter,
                        retainFocusAppearance: retainFocusAppearanceForCardKey == cardKey,
                        allowsFocus: true,
                        onSelect: { onSelect(folder) }
                    )
                    .disabled(
                        (restrictFocusToCardKey != nil && restrictFocusToCardKey != cardKey)
                            || (!isRowFocused && index != effectiveScrollIndex)
                    )
                }
            }
            .padding(
                .leading,
                TVCollectionFolderCardLayout.scrollOffset(
                    to: materializedIndices.first ?? 0,
                    folders: folders,
                    layoutMode: rowHomeLayout
                )
            )
            .padding(.vertical, TVHomeLayout.stripVerticalPadding)
            .offset(x: horizontalEdgeInset + TVLayout.rowLeading - scrollX)
            .frame(
                width: stripWidth,
                height: stripHeight,
                alignment: .topLeading
            )
            .clipped()
            .offset(x: -horizontalEdgeInset)
            .animation(
                rowSmoothFocus && !suppressFocusAnimations ? TVHomeLayout.scrollAnimation : nil,
                value: effectiveScrollIndex
            )
        }
        .frame(height: stripHeight)
    }

    /// Animate this row back to its first card (rail opened, see TVHomeView).
    private func resetToStart() {
        withAnimation(TVHomeLayout.scrollAnimation) { scrollIndex = 0 }
        onScrollIndexChange(0)
    }
}

// Keep row identity and horizontal state stable, while allowing the focused
// vertical window to swap lightweight shells for real folder cards.
extension TVCollectionFolderRow: Equatable {
    static func == (lhs: TVCollectionFolderRow, rhs: TVCollectionFolderRow) -> Bool {
        let lhsRestrictInRow = lhs.restrictFocusToCardKey?.hasPrefix("\(lhs.id)\u{1}") == true
        let rhsRestrictInRow = rhs.restrictFocusToCardKey?.hasPrefix("\(rhs.id)\u{1}") == true
        let restrictEqual = (lhsRestrictInRow == rhsRestrictInRow)
            && (!lhsRestrictInRow || lhs.restrictFocusToCardKey == rhs.restrictFocusToCardKey)

        let lhsRetainInRow = lhs.retainFocusAppearanceForCardKey?.hasPrefix("\(lhs.id)\u{1}") == true
        let rhsRetainInRow = rhs.retainFocusAppearanceForCardKey?.hasPrefix("\(rhs.id)\u{1}") == true
        let retainEqual = (lhsRetainInRow == rhsRetainInRow)
            && (!lhsRetainInRow || lhs.retainFocusAppearanceForCardKey == rhs.retainFocusAppearanceForCardKey)

        return lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.horizontalEdgeInset == rhs.horizontalEdgeInset
&& lhs.resetGeneration == rhs.resetGeneration
            && lhs.folders == rhs.folders
            && lhs.initialScrollIndex == rhs.initialScrollIndex
            && lhs.initialFocusCardKey == rhs.initialFocusCardKey
            && restrictEqual
            && retainEqual
            && lhs.suppressFocusAnimations == rhs.suppressFocusAnimations
            && lhs.isRowFocused == rhs.isRowFocused
    }
}

/// Folder tile chrome matching Search / Library cards (`SearchResultCard`):
/// scale on focus, stronger shadow, label styling. Select opens the folder.
private struct TVCollectionFolderCard: View {
    let folder: TVCollectionFolderItem
    var shouldRequestInitialFocus: Bool = false
    var onInitialFocusRequested: (() -> Void)? = nil
    var externalFocus: FocusState<String?>.Binding? = nil
    var externalFocusValue: String? = nil
    var onFocus: (() -> Void)? = nil
    var layoutMode: String = "Modern"
    var showPosterLabels: Bool = false
    var smoothFocusAnimations: Bool = true
    var focusHighlighterEnabled: Bool = false
    var retainFocusAppearance: Bool = false
    var allowsFocus = true
    let onSelect: () -> Void

    @FocusState private var isFocused: Bool
    @State private var didRequestInitialFocus = false
    @AppStorage(SettingsKey.cardCornerRadius) private var cardCornerRadiusSetting = AppCardStyle.defaultCornerRadiusRaw

    private var showFocus: Bool { isFocused || retainFocusAppearance }

    /// All shapes share the same height; landscape/square only widen.
    private var cardWidth: CGFloat {
        TVCollectionFolderCardLayout.cardWidth(shape: folder.tileShape, layoutMode: layoutMode)
    }

    private var cardHeight: CGFloat {
        TVCollectionFolderCardLayout.cardHeight(layoutMode: layoutMode)
    }

    /// Keep the focus surface identical to the visible card, matching normal
    /// collection folders and allowing tvOS to navigate Left natively.
    private var layoutWidth: CGFloat { cardWidth }

    /// Search-style labels use two lines (title + subtitle); reserve space.
    private var totalCardHeight: CGFloat {
        cardHeight + (showPosterLabels && !folder.hideTitle ? 48 : 0)
    }

    private var displayTitle: String {
        let t = folder.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Folder" : t
    }

    private var subtitle: String {
        let count = folder.sources.count
        return count == 1 ? "1 catalog" : "\(count) catalogs"
    }

    private var cardCornerRadius: CGFloat {
        AppCardStyle.cornerRadius(for: cardCornerRadiusSetting, fallback: 16)
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
    }

    /// Image URL wins when present; otherwise a non-nil `coverEmoji` means the
    /// user picked emoji cover mode (value may still be empty).
    private var coverImageURL: URL? {
        guard let raw = folder.coverImageUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    private var usesEmojiCover: Bool {
        coverImageURL == nil && folder.coverEmoji != nil
    }

    private var usesLogoCoverPresentation: Bool {
        let style = folder.presentationStyle?.uppercased()
        return style == "STREAMING_SERVICE"
            || style == "STUDIO_FRANCHISE"
            || style == "BRAND_COLLECTION"
    }

    private var emojiText: String? {
        let t = folder.coverEmoji?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? nil : t
    }

    private var emojiFontSize: CGFloat {
        min(cardWidth, cardHeight) * 0.28
    }

    private var focusedBorderColor: Color {
        guard showFocus else { return .clear }
        return AppFocusOutline.color
    }

    private var focusedBorderWidth: CGFloat {
        showFocus ? (focusHighlighterEnabled ? AppFocusOutline.emphasizedWidth : AppFocusOutline.width) : 0
    }

    /// Match SearchResultCard / LibraryItemButton shadow.
    private var shadowOpacity: Double { showFocus ? 0.5 : 0.2 }
    private var shadowRadius: CGFloat { showFocus ? 16 : 6 }

    /// Focus GIF overlay — same contract as Android TV: only while focused
    /// (or focus retained under an overlay) and only when enabled + URL set.
    private var focusGifURLString: String? {
        folder.activeFocusGifURLString
    }

    var body: some View {
        // Home rows keep focusable + tap (like PosterCard) so external focus
        // restoration and strip paging stay intact; chrome matches Search cards.
        cardContent
            .contentShape(Rectangle())
            .focusable(allowsFocus)
            .focused($isFocused)
            .modifier(ExternalFocusBinding(binding: externalFocus, id: externalFocusValue ?? folder.id))
            .focusEffectDisabledIfAvailable()
            .onTapGesture(perform: onSelect)
            .onChange(of: isFocused) { _, focused in
                if focused { onFocus?() }
            }
            .onAppear {
                guard shouldRequestInitialFocus, !didRequestInitialFocus else { return }
                didRequestInitialFocus = true
                onInitialFocusRequested?()
                DispatchQueue.main.async {
                    isFocused = true
                }
            }
            .frame(width: cardWidth, height: totalCardHeight, alignment: .topLeading)
            .zIndex(showFocus ? 1 : 0)
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            artTile

            if showPosterLabels && !folder.hideTitle {
                VStack(alignment: .leading, spacing: 3) {
                    Text(displayTitle)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.white.opacity(0.86))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white.opacity(0.45))
                        .lineLimit(1)
                }
                .frame(width: cardWidth, alignment: .leading)
                .animation(nil, value: showFocus)
            }
        }
        .frame(width: layoutWidth, height: totalCardHeight, alignment: .topLeading)
    }

    @ViewBuilder
    private var artTile: some View {
        if let url = coverImageURL {
            imageCover(url: url)
        } else if usesEmojiCover {
            emojiGlassCover
        } else {
            emptyCover
        }
    }

    /// Shared focus-GIF layer drawn over cover image / emoji / empty chrome.
    @ViewBuilder
    private var focusGifOverlay: some View {
        if let gifURL = focusGifURLString {
            AnimatedRemoteGIFView(urlString: gifURL, isActive: showFocus)
                .frame(width: cardWidth, height: cardHeight)
                .clipped()
                // Prefetch while the row is on screen so focus feels instant.
                .opacity(1)
                .allowsHitTesting(false)
        }
    }

    private func imageCover(url: URL) -> some View {
        ZStack {
            if usesLogoCoverPresentation {
                Color.clear
                    .frame(width: cardWidth, height: cardHeight)
                    .modifier(
                        LiquidGlassSurface(
                            cornerRadius: cardCornerRadius,
                            prominent: showFocus
                        )
                    )
            }
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    if usesLogoCoverPresentation {
                        image
                            .resizable()
                            .scaledToFit()
                            .padding(.horizontal, cardWidth * 0.10)
                            .padding(.vertical, cardHeight * 0.10)
                    } else {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }
                default:
                    // Loading / failed image falls back to empty art chrome.
                    emptyCoverFill
                }
            }
            focusGifOverlay
        }
        .frame(width: cardWidth, height: cardHeight)
        .clipped()
        .clipShape(cardShape)
        .overlay(cardShape.stroke(focusedBorderColor, lineWidth: focusedBorderWidth))
        .shadow(color: .black.opacity(shadowOpacity), radius: shadowRadius)
    }

    /// Liquid-glass tile when the folder uses an emoji cover (not a flat grey plate).
    /// Glass + emoji sit underneath; the focus GIF paints on top when active.
    private var emojiGlassCover: some View {
        ZStack {
            ZStack {
                coverGlyph
            }
            .frame(width: cardWidth, height: cardHeight)
            .modifier(LiquidGlassSurface(cornerRadius: cardCornerRadius, prominent: showFocus))

            focusGifOverlay
                .clipShape(cardShape)
        }
        .frame(width: cardWidth, height: cardHeight)
        .overlay(cardShape.stroke(focusedBorderColor, lineWidth: focusedBorderWidth))
        .shadow(color: .black.opacity(shadowOpacity), radius: shadowRadius)
    }

    private var emptyCover: some View {
        ZStack {
            emptyCoverFill
            coverGlyph
            focusGifOverlay
        }
        .frame(width: cardWidth, height: cardHeight)
        .clipShape(cardShape)
        .overlay(cardShape.stroke(focusedBorderColor, lineWidth: focusedBorderWidth))
        .shadow(color: .black.opacity(shadowOpacity), radius: shadowRadius)
    }

    /// Flat grey fill for non-emoji empty / image-loading states (matches Search cards).
    private var emptyCoverFill: some View {
        Rectangle()
            .fill(Color.white.opacity(0.07))
    }

    @ViewBuilder
    private var coverGlyph: some View {
        if let emojiText {
            Text(emojiText)
                .font(.system(size: emojiFontSize))
        } else {
            Image(systemName: "folder")
                .font(.system(size: 40))
                .foregroundColor(.white.opacity(0.25))
        }
    }
}
