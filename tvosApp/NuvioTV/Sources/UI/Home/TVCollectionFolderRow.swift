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
    static func cardHeight() -> CGFloat {
        315
    }

    /// Width from fixed height × shape aspect ratio.
    /// Matches Settings `CollectionTileShapePreview` and keeps landscape/square
    /// the same height as portrait — only wider.
    static func cardWidth(shape: CollectionTileShape) -> CGFloat {
        let height = cardHeight()
        switch shape {
        case .poster:
            // Match catalog `PosterCard` portrait width exactly.
            return 210
        case .landscape:
            // Match PosterCard's focused Home landscape width exactly.
            return 560
        case .square:
            return (height * CGFloat(shape.aspectRatio)).rounded()
        }
    }

    static func rowSpacing() -> CGFloat {
        28
    }

    /// Leading-edge offset of the card at `index` (sum of prior widths + gaps).
    static func scrollOffset(
        to index: Int,
        folders: [TVCollectionFolderItem]
    ) -> CGFloat {
        guard index > 0 else { return 0 }
        let spacing = rowSpacing()
        var offset: CGFloat = 0
        let end = min(index, folders.count)
        for i in 0..<end {
            offset += cardWidth(shape: folders[i].tileShape) + spacing
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
    var suppressFocusAnimations = false
    var isRowFocused = false
    let onInitialFocusRequested: () -> Void
    let onFocus: (TVCollectionFolderItem) -> Void
    let onSelect: (TVCollectionFolderItem) -> Void

    @State private var scrollIndex: Int?
    @AppStorage(SettingsKey.posterLabels) private var posterLabels = false

    private var effectiveScrollIndex: Int {
        let raw = scrollIndex ?? initialScrollIndex
        guard !folders.isEmpty else { return 0 }
        return min(max(raw, 0), folders.count - 1)
    }

    private var rowSpacing: CGFloat {
        TVCollectionFolderCardLayout.rowSpacing()
    }

    private var imageHeight: CGFloat {
        TVCollectionFolderCardLayout.cardHeight()
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
        stripWidth: CGFloat
    ) -> [Int] {
        guard !folders.isEmpty else { return [] }

        let focusIndex = effectiveScrollIndex
        var lowerBound = max(0, focusIndex - 4)
        var upperBound = focusIndex
        let spacing = TVCollectionFolderCardLayout.rowSpacing()
        var coveredWidth: CGFloat = 0

        for index in focusIndex..<folders.count {
            coveredWidth += TVCollectionFolderCardLayout.cardWidth(
                shape: folders[index].tileShape
            ) + spacing
            upperBound = index
            if coveredWidth >= stripWidth { break }
        }

        // The initial focus target must be mounted even if the persisted scroll
        // index has not caught up with it yet.
        let rowPrefix = "\(id)\u{1}"
        if let key = initialFocusCardKey, key.hasPrefix(rowPrefix) {
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
            let rowSpacing = TVCollectionFolderCardLayout.rowSpacing()
            let scrollX = TVCollectionFolderCardLayout.scrollOffset(
                to: effectiveScrollIndex,
                folders: folders
            )
            let materializedIndices = materializedCardIndices(
                stripWidth: stripWidth
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
                        onSelect: { onSelect(folder) }
                    )
                    .disabled(!isRowFocused && index != effectiveScrollIndex)
                }
            }
            .padding(
                .leading,
                TVCollectionFolderCardLayout.scrollOffset(
                    to: materializedIndices.first ?? 0,
                    folders: folders
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
                !suppressFocusAnimations ? TVHomeLayout.scrollAnimation : nil,
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
        return lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.horizontalEdgeInset == rhs.horizontalEdgeInset
&& lhs.resetGeneration == rhs.resetGeneration
            && lhs.folders == rhs.folders
            && lhs.initialScrollIndex == rhs.initialScrollIndex
            && lhs.initialFocusCardKey == rhs.initialFocusCardKey
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
    let onSelect: () -> Void

    @FocusState private var isFocused: Bool
    @State private var didRequestInitialFocus = false
    @Environment(\.posterLabels) private var posterLabels

    /// All shapes share the same height; landscape/square only widen.
    private var cardWidth: CGFloat {
        TVCollectionFolderCardLayout.cardWidth(shape: folder.tileShape)
    }

    private var cardHeight: CGFloat {
        TVCollectionFolderCardLayout.cardHeight()
    }

    private var showsCaption: Bool { posterLabels && !folder.hideTitle }

    private var displayTitle: String {
        let t = folder.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Folder" : t
    }

    private var subtitle: String {
        let count = folder.sources.count
        return count == 1 ? "1 catalog" : "\(count) catalogs"
    }

    /// Image URL wins when present; otherwise a non-nil `coverEmoji` means the
    /// user picked emoji cover mode (value may still be empty).
    private var coverImageURL: URL? {
        guard let raw = folder.coverImageUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return URL(string: raw)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The system card style owns the focus treatment; the label is
            // exactly the cover plate, so the lift and clip follow its shape.
            Button(action: onSelect) {
                artTile
                    .frame(width: cardWidth, height: cardHeight)
            }
            .buttonStyle(.card)
            .focused($isFocused)
            .modifier(ExternalFocusBinding(binding: externalFocus, id: externalFocusValue ?? folder.id))

            if showsCaption {
                VStack(alignment: .leading, spacing: 3) {
                    Text(displayTitle)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.86))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
                .frame(width: cardWidth, alignment: .leading)
            }
        }
        .onChange(of: isFocused) { _, focused in
            if focused { onFocus?() }
        }
        .onAppear {
            guard shouldRequestInitialFocus, !didRequestInitialFocus else { return }
            didRequestInitialFocus = true
            onInitialFocusRequested?()
            DispatchQueue.main.async { isFocused = true }
        }
    }

    /// Cover image, emoji or folder glyph on a flat plate, with the focus GIF
    /// on top while focused.
    private var artTile: some View {
        ZStack {
            Rectangle().fill(Color.white.opacity(0.07))

            if let url = coverImageURL {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
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
                    }
                }
            } else {
                coverGlyph
            }

            // Same contract as Android TV: only while focused, only when set.
            if let gifURL = folder.activeFocusGifURLString {
                AnimatedRemoteGIFView(urlString: gifURL, isActive: isFocused)
                    .allowsHitTesting(false)
            }
        }
        .clipped()
    }

    @ViewBuilder
    private var coverGlyph: some View {
        if let emojiText {
            Text(emojiText)
                .font(.system(size: emojiFontSize))
        } else {
            Image(systemName: "folder")
                .font(.system(size: 40))
                .foregroundStyle(.white.opacity(0.25))
        }
    }
}
