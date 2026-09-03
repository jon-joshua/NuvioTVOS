import SwiftUI
import Foundation
import UIKit
import ImageIO
import OSLog

// MARK: - Poster tile chrome

/// The two appearance settings every grid poster tile needs, resolved once per
/// screen instead of once per card. Before this existed each tile carried five
/// `@AppStorage` wrappers, so a grid of ~28 cards registered ~140 UserDefaults
/// observers and tore them down again on every scroll recycle.
struct PosterChromeStyle: Equatable {
    /// Whether the title/subtitle caption is drawn under the artwork.
    var posterLabels: Bool = false
    /// Debug aid from Advanced settings: thicker focus outline.
    var focusHighlighter: Bool = false

    /// Used by previews and any host that has not installed a provider.
    static let `default` = PosterChromeStyle()

    /// Fixed card geometry and material. The corner-radius, Liquid Glass and
    /// smooth-focus options were removed from Settings; every card now shares
    /// these defaults.
    var cornerRadius: CGFloat { 16 }
    var liquidGlass: Bool { true }

    var focusOutlineWidth: CGFloat {
        focusHighlighter ? AppFocusOutline.emphasizedWidth : AppFocusOutline.width
    }

    var focusAnimation: Animation? {
        .spring(response: 0.28, dampingFraction: 0.75)
    }

    var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }
}

private struct PosterChromeStyleKey: EnvironmentKey {
    static let defaultValue = PosterChromeStyle.default
}

extension EnvironmentValues {
    /// Appearance settings for grid poster tiles, published once per screen by
    /// `PosterChromeStyleProvider`.
    var posterChromeStyle: PosterChromeStyle {
        get { self[PosterChromeStyleKey.self] }
        set { self[PosterChromeStyleKey.self] = newValue }
    }
}

/// The single owner of the poster-tile appearance settings. Installed once in
/// `appContainer`, below `.defaultAppStorage(...)` so the values resolve against
/// the active profile's suite. A settings change re-evaluates this view,
/// republishes an equatable style, and SwiftUI invalidates only the views whose
/// bodies read it.
struct PosterChromeStyleProvider<Content: View>: View {
    @ViewBuilder var content: Content

    @AppStorage(SettingsKey.posterLabels) private var posterLabels = false
    @AppStorage(SettingsKey.focusHighlighter) private var focusHighlighter = false

    private var style: PosterChromeStyle {
        PosterChromeStyle(posterLabels: posterLabels, focusHighlighter: focusHighlighter)
    }

    var body: some View {
        content.environment(\.posterChromeStyle, style)
    }
}

/// Which surface sits under the artwork before the focus outline goes on.
enum PosterTileSurface {
    /// Clip the content to the card shape, then apply `LiquidGlassCardModifier`.
    case glassCard
    /// The caller already drew its own shaped surface (the See All tile uses
    /// `LiquidGlassSurface`); only outline, shadow and hover effect are added.
    case externalSurface
}

/// The one chrome chain shared by every full-width grid poster tile.
///
/// Order is load-bearing: clip first so the glass fill and outline follow the
/// card shape; the caller's badge above the glass border, as before; then the
/// accent outline; then the drop shadow at a CONSTANT radius; then the system
/// highlight outermost so its projection and specular sweep cover the whole
/// plate rather than tilting the artwork out from under its own border.
///
/// The shadow radius no longer animates. A fixed-radius shadow on fixed
/// geometry is a cached raster that Core Animation simply scales under the
/// enclosing 1.06 focus transform, and the only animated property is opacity,
/// which composites for free. Animating the radius forced a fresh Gaussian
/// blur every frame while the scale changed the source rect, so nothing could
/// be reused between frames.
struct PosterTileChrome<Badge: View>: ViewModifier {
    let style: PosterChromeStyle
    let isFocused: Bool
    var surface: PosterTileSurface = .glassCard
    @ViewBuilder var badge: Badge

    /// Constant on purpose; splits the old 6/16 pair. The 1.06 focus scale
    /// widens it visually at focus without re-blurring.
    private static var shadowRadius: CGFloat { 12 }

    func body(content: Content) -> some View {
        surfaced(content)
            .overlay(alignment: .topTrailing) { badge }
            .overlay(
                style.shape.stroke(
                    isFocused ? AppFocusOutline.color : .clear,
                    lineWidth: style.focusOutlineWidth
                )
            )
            .shadow(
                color: .black.opacity(isFocused ? 0.45 : 0.2),
                radius: Self.shadowRadius
            )
            .modifier(SystemHighlightEffect())
    }

    @ViewBuilder
    private func surfaced(_ content: Content) -> some View {
        switch surface {
        case .glassCard:
            content
                .clipShape(style.shape)
                .modifier(
                    LiquidGlassCardModifier(
                        cornerRadius: style.cornerRadius,
                        isFocused: isFocused,
                        isEnabled: style.liquidGlass
                    )
                )
        case .externalSurface:
            content
        }
    }
}

/// tvOS's own focus treatment: a projection with a specular highlight plus
/// parallax motion, applied whenever this view is inside a focused view.
/// Replaces the hand-rolled lift the cards used to approximate.
private struct SystemHighlightEffect: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(tvOS)
        content.hoverEffect(.highlight)
        #else
        content
        #endif
    }
}

extension View {
    /// Shared grid-poster chrome. See `PosterTileChrome`.
    func posterTileChrome<Badge: View>(
        style: PosterChromeStyle,
        isFocused: Bool,
        surface: PosterTileSurface = .glassCard,
        @ViewBuilder badge: () -> Badge
    ) -> some View {
        modifier(PosterTileChrome(style: style, isFocused: isFocused, surface: surface, badge: badge))
    }

    /// Chrome with no badge (the See All tile).
    func posterTileChrome(
        style: PosterChromeStyle,
        isFocused: Bool,
        surface: PosterTileSurface = .glassCard
    ) -> some View {
        posterTileChrome(style: style, isFocused: isFocused, surface: surface) { EmptyView() }
    }
}

// MARK: - Grid tiles

#if os(tvOS)
/// Poster tile for the full-width grids: Search results and the Grid Home
/// previews. The system card style owns the whole focus treatment (lift,
/// specular highlight, parallax, shadow, scale), so the tile draws nothing but
/// the artwork, the watched badge and the caption underneath.
///
/// Distinct from `PosterCard`, which is the row-strip card: that one also has to
/// expand to landscape artwork, carry Continue Watching progress, and stay
/// cheap while a whole strip of it is mounted.
struct PosterGridCard: View {
    let meta: NuvioMeta
    var width: CGFloat = 210
    var height: CGFloat = 315
    var externalFocus: FocusState<String?>.Binding? = nil
    /// Defaults to `meta.id`. Home passes a section-scoped key, since the same
    /// title can appear in more than one catalog.
    var focusValue: String? = nil
    /// Pre-resolved watched state; `nil` lets the badge look it up itself.
    var isWatched: Bool? = nil
    var shouldRequestInitialFocus = false
    var onInitialFocusRequested: (() -> Void)? = nil
    var onFocus: ((NuvioMeta) -> Void)? = nil
    /// Forces the title/subtitle caption to render regardless of the user's
    /// global poster-labels setting (used by Search's grids).
    var forceShowLabels = false
    let action: () -> Void

    @FocusState private var focused: Bool
    @State private var didRequestInitialFocus = false
    /// Only `posterLabels` is read; the card style replaces the rest.
    @Environment(\.posterChromeStyle) private var chrome

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: action) {
                CachedPosterArtwork(
                    urlString: meta.posterUrl,
                    preloadURLString: nil,
                    width: width,
                    height: height,
                    maximumWidth: width,
                    minimumSwapDelay: 0,
                    onPreloadFinished: {}
                ) {
                    placeholder
                }
                .frame(width: width, height: height)
                .overlay(alignment: .topTrailing) {
                    if let isWatched {
                        if isWatched { WatchedCheckmarkIcon() }
                    } else {
                        WatchedCheckmarkBadge(meta: meta)
                    }
                }
            }
            .buttonStyle(.card)
            .focused($focused)
            .modifier(ExternalFocusBinding(binding: externalFocus, id: focusValue ?? meta.id))
            .titleActionsContextMenu(
                meta: meta,
                onOpenDetails: action
            )

            if chrome.posterLabels || forceShowLabels {
                VStack(alignment: .leading, spacing: 3) {
                    Text(meta.name)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(focused ? .white : .white.opacity(0.78))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
                .frame(width: width, alignment: .leading)
                .animation(NuvioMotion.focus, value: focused)
            }
        }
        .onChange(of: focused) { _, isFocused in
            if isFocused { onFocus?(meta) }
        }
        .onAppear {
            guard shouldRequestInitialFocus, !didRequestInitialFocus else { return }
            didRequestInitialFocus = true
            onInitialFocusRequested?()
            DispatchQueue.main.async { focused = true }
        }
    }

    private var placeholder: some View {
        ZStack {
            Rectangle().fill(Color.white.opacity(0.07))
            Image(systemName: meta.type == "series" ? "tv" : "film")
                .font(.system(size: 40))
                .foregroundColor(.white.opacity(0.25))
        }
    }

    private var subtitle: String {
        let typeLabel = meta.type == "series"
            ? L10n.string("type_series", fallback: "Series")
            : L10n.string("type_movie", fallback: "Movie")
        var parts: [String] = [typeLabel]
        if let year = meta.year { parts.append(String(year)) }
        if let rating = meta.rating, rating > 0 { parts.append(String(format: "★ %.1f", rating)) }
        return parts.joined(separator: "  ·  ")
    }
}

#endif

struct DiscoverCard: View {
    let meta: NuvioMeta
    var externalFocus: FocusState<String?>.Binding? = nil
    var onFocusChange: ((Bool) -> Void)? = nil
    var retainFocusAppearance = false
    let action: () -> Void
    @FocusState private var focused: Bool
    @Environment(\.posterChromeStyle) private var chrome

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .bottom) {
                    CachedPosterArtwork(
                        urlString: meta.posterUrl,
                        width: DiscoverGridMetrics.posterWidth,
                        height: DiscoverGridMetrics.posterHeight,
                        maximumWidth: DiscoverGridMetrics.posterWidth
                    ) {
                        ZStack {
                            Rectangle().fill(Color.white.opacity(0.07))
                            Image(systemName: meta.type == "series" ? "tv" : "film")
                                .font(.system(size: 40))
                                .foregroundColor(.white.opacity(0.25))
                        }
                    }
                    .frame(width: DiscoverGridMetrics.posterWidth, height: DiscoverGridMetrics.posterHeight)

                    if metaLine != nil {
                        LinearGradient(
                            colors: [.clear, .black.opacity(0.85)],
                            startPoint: .center,
                            endPoint: .bottom
                        )
                        .frame(height: 120)
                        .frame(maxWidth: .infinity, alignment: .bottom)

                        if let metaLine {
                            Text(metaLine)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.white.opacity(0.95))
                                .lineLimit(1)
                                .padding(.horizontal, 12)
                                .padding(.bottom, 10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(width: DiscoverGridMetrics.posterWidth, height: DiscoverGridMetrics.posterHeight)
                .posterTileChrome(style: chrome, isFocused: showsFocusedAppearance) {
                    WatchedCheckmarkBadge(meta: meta)
                }

                if chrome.posterLabels {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(meta.name)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(showsFocusedAppearance ? .white : .white.opacity(0.78))
                            .lineLimit(1)
                        if let year = meta.year {
                            Text(String(year))
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(.white.opacity(0.45))
                        }
                    }
                    .frame(width: DiscoverGridMetrics.posterWidth, alignment: .leading)
                }
            }
            .scaleEffect(showsFocusedAppearance ? 1.06 : 1.0)
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focused)
        .modifier(ExternalFocusBinding(binding: externalFocus, id: meta.id))
        .titleActionsContextMenu(
            meta: meta,
            onOpenDetails: action
        )
        .onChange(of: focused) { _, isFocused in onFocusChange?(isFocused) }
        .animation(chrome.focusAnimation, value: showsFocusedAppearance)
    }

    /// "Genre · ★ Rating" overlay, omitting whichever piece is missing.
    private var metaLine: String? {
        var parts: [String] = []
        if let genre = meta.genres?.first, !genre.isEmpty { parts.append(genre) }
        if let rating = meta.rating, rating > 0 { parts.append(String(format: "★ %.1f", rating)) }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    private var showsFocusedAppearance: Bool {
        focused || retainFocusAppearance
    }
}

struct LibraryItemButton: View {
    let item: StremioMeta
    var externalFocus: FocusState<String?>.Binding? = nil
    var retainFocusAppearance = false
    let action: () -> Void

    @FocusState private var isFocused: Bool
    @Environment(\.posterChromeStyle) private var chrome

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                CachedPosterArtwork(
                    urlString: item.poster,
                    width: LibraryGridMetrics.posterWidth,
                    height: LibraryGridMetrics.posterHeight,
                    maximumWidth: LibraryGridMetrics.posterWidth
                ) {
                    ZStack {
                        Rectangle()
                            .fill(Color.white.opacity(0.07))
                        Image(systemName: item.contentType == "series" ? "tv" : "film")
                            .font(.system(size: 40))
                            .foregroundColor(.white.opacity(0.25))
                    }
                }
                .frame(width: LibraryGridMetrics.posterWidth, height: LibraryGridMetrics.posterHeight)
                .posterTileChrome(style: chrome, isFocused: showsFocusedAppearance) {
                    WatchedCheckmarkBadge(metaId: item.id, type: item.contentType)
                }

                if chrome.posterLabels {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(showsFocusedAppearance ? .white : .white.opacity(0.78))
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.white.opacity(0.45))
                            .lineLimit(1)
                    }
                    .frame(width: LibraryGridMetrics.posterWidth, alignment: .leading)
                }
            }
            .scaleEffect(showsFocusedAppearance ? 1.06 : 1.0)
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($isFocused)
        .modifier(ExternalFocusBinding(binding: externalFocus, id: item.id))
        .titleActionsContextMenu(
            meta: item.asNuvioMeta,
            onOpenDetails: action
        )
        .animation(chrome.focusAnimation, value: showsFocusedAppearance)
        .zIndex(showsFocusedAppearance ? 1 : 0)
    }

    private var subtitle: String {
        let typeLabel = item.contentType == "series"
            ? L10n.string("type_series", fallback: "Series")
            : L10n.string("type_movie", fallback: "Movie")
        var parts = [typeLabel]
        if let year = item.year { parts.append(String(year)) }
        if let rating = item.imdbRating.flatMap(Double.init), rating > 0 {
            parts.append(String(format: "★ %.1f", rating))
        }
        return parts.joined(separator: "  ·  ")
    }

    private var showsFocusedAppearance: Bool {
        isFocused || retainFocusAppearance
    }
}


/// Poster card chrome matching Search / Library grids (Tabs view mode).
struct CollectionFolderResultCard: View {
    let meta: NuvioMeta
    var externalFocus: FocusState<String?>.Binding? = nil
    var isWatched: Bool? = nil
    let action: () -> Void

    @FocusState private var focused: Bool
    @Environment(\.posterChromeStyle) private var chrome

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                CachedPosterArtwork(
                    urlString: meta.posterUrl,
                    width: CollectionFolderGridMetrics.posterWidth,
                    height: CollectionFolderGridMetrics.posterHeight,
                    maximumWidth: CollectionFolderGridMetrics.posterWidth
                ) {
                    ZStack {
                        Rectangle().fill(Color.white.opacity(0.07))
                        Image(systemName: meta.type == "series" ? "tv" : "film")
                            .font(.system(size: 40))
                            .foregroundColor(.white.opacity(0.25))
                    }
                }
                .frame(
                    width: CollectionFolderGridMetrics.posterWidth,
                    height: CollectionFolderGridMetrics.posterHeight
                )
                .posterTileChrome(style: chrome, isFocused: focused) {
                    if let isWatched {
                        if isWatched { WatchedCheckmarkIcon() }
                    } else {
                        WatchedCheckmarkBadge(meta: meta)
                    }
                }

                if chrome.posterLabels {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(meta.name)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(focused ? .white : .white.opacity(0.78))
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.white.opacity(0.45))
                            .lineLimit(1)
                    }
                    .frame(width: CollectionFolderGridMetrics.posterWidth, alignment: .leading)
                }
            }
            .scaleEffect(focused ? 1.06 : 1.0)
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focused)
        .modifier(ExternalFocusBinding(binding: externalFocus, id: meta.id))
        .titleActionsContextMenu(
            meta: meta,
            onOpenDetails: action
        )
        .animation(chrome.focusAnimation, value: focused)
        .zIndex(focused ? 1 : 0)
    }

    private var subtitle: String {
        var parts: [String] = [meta.type == "series" ? "Series" : "Movie"]
        if let year = meta.year { parts.append(String(year)) }
        if let rating = meta.rating, rating > 0 { parts.append(String(format: "★ %.1f", rating)) }
        return parts.joined(separator: "  ·  ")
    }
}

