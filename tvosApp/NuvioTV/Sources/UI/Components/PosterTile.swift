import SwiftUI

/// The one poster. Owns the Button, the system card style, the focus plumbing,
/// the context menu, the badges, the progress bar and the caption, so every
/// screen's poster lifts, highlights and clips the same way. Screens map their
/// model onto these parameters and, at most, fill the overlay slot.
///
/// Nothing here draws chrome: no outline, no shadow, no scale, no hover effect.
/// `.buttonStyle(.card)` is the whole focus treatment, and it must wrap exactly
/// the artwork plate, so the caption sits outside the Button.
struct PosterTile<Overlay: View>: View {
    let meta: NuvioMeta
    /// Defaults to the poster. Home passes the landscape art while expanded.
    var artworkURL: String? = nil
    /// Artwork to decode ahead of a swap (Home's landscape art).
    var preloadURL: String? = nil
    /// Decode width for the preload when it will be shown wider than `size`.
    var preloadMaximumWidth: CGFloat? = nil
    /// Called when the preload has been decoded, or has failed.
    var onPreloadFinished: () -> Void = {}
    var size = CGSize(width: 210, height: 315)
    var watched: PosterWatched = .lookup
    /// 0...1 draws the bar; nil hides it.
    var progress: Double? = nil
    var badge: PosterBadge? = nil
    /// Drawn when poster labels are on, or always when `alwaysShowCaption`.
    var caption: PosterCaption? = nil
    var alwaysShowCaption = false
    var externalFocus: FocusState<String?>.Binding? = nil
    /// Defaults to `meta.id`. Rows pass a section-scoped key, since one title
    /// can appear in several rows.
    var focusValue: String? = nil
    var shouldRequestInitialFocus = false
    var onInitialFocusRequested: (() -> Void)? = nil
    var onFocusChange: ((Bool) -> Void)? = nil
    /// Directional-command hook on the Button itself; container handlers can
    /// miss commands the focus engine consumes first.
    var onMove: ((MoveCommandDirection) -> Void)? = nil
    /// Nil gives the plain "open details" menu.
    var contextActions: TitleActions? = nil
    @ViewBuilder var overlay: () -> Overlay
    let action: () -> Void

    @FocusState private var focused: Bool
    @State private var didRequestInitialFocus = false
    @Environment(\.posterLabels) private var posterLabels

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: action) {
                CachedPosterArtwork(
                    urlString: artworkURL ?? meta.posterUrl,
                    preloadURLString: preloadURL,
                    width: size.width,
                    height: size.height,
                    maximumWidth: size.width,
                    preloadMaximumWidth: preloadMaximumWidth,
                    minimumSwapDelay: 0,
                    onPreloadFinished: onPreloadFinished
                ) {
                    PosterTilePlaceholder(type: meta.type)
                }
                .frame(width: size.width, height: size.height)
                .overlay { overlay() }
                .overlay(alignment: .bottomLeading) { progressBar }
                .overlay(alignment: .topLeading) { chip }
                .overlay(alignment: .topTrailing) { watchedBadge }
            }
            .buttonStyle(.card)
            .focused($focused)
            .modifier(ExternalFocusBinding(binding: externalFocus, id: focusValue ?? meta.id))
            .modifier(PosterMoveCommandHandler(handler: onMove))
            .modifier(TitleActionsMenu(meta: meta, actions: contextActions ?? TitleActions(onOpenDetails: action)))

            if let caption, posterLabels || alwaysShowCaption {
                captionView(caption)
            }
        }
        .animation(NuvioMotion.focus, value: focused)
        .onChange(of: focused) { _, isFocused in onFocusChange?(isFocused) }
        .onAppear {
            guard shouldRequestInitialFocus, !didRequestInitialFocus else { return }
            didRequestInitialFocus = true
            onInitialFocusRequested?()
            DispatchQueue.main.async { focused = true }
        }
    }

    @ViewBuilder
    private var progressBar: some View {
        if let progress = PosterProgress.clamped(progress) {
            let track = size.width - 44
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.38))
                Capsule().fill(Color.white)
                    .frame(width: PosterProgress.fillWidth(track: track, progress: progress))
            }
            .frame(width: track, height: 8)
            .padding(.leading, 22)
            .padding(.bottom, 16)
        }
    }

    @ViewBuilder
    private var chip: some View {
        if let badge {
            Text(badge.text)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(badge.tint.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(16)
        }
    }

    @ViewBuilder
    private var watchedBadge: some View {
        switch watched {
        case .hidden:
            EmptyView()
        case .lookup:
            WatchedCheckmarkBadge(meta: meta)
        case .resolved(let isWatched):
            if isWatched { WatchedCheckmarkIcon() }
        }
    }

    private func captionView(_ caption: PosterCaption) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(caption.title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(focused ? .white : .white.opacity(0.78))
                .lineLimit(1)
            if let subtitle = caption.subtitle {
                Text(subtitle)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
        }
        .frame(width: size.width, alignment: .leading)
    }
}

extension PosterTile where Overlay == EmptyView {
    init(
        meta: NuvioMeta,
        artworkURL: String? = nil,
        size: CGSize = CGSize(width: 210, height: 315),
        watched: PosterWatched = .lookup,
        progress: Double? = nil,
        badge: PosterBadge? = nil,
        caption: PosterCaption? = nil,
        alwaysShowCaption: Bool = false,
        externalFocus: FocusState<String?>.Binding? = nil,
        focusValue: String? = nil,
        shouldRequestInitialFocus: Bool = false,
        onInitialFocusRequested: (() -> Void)? = nil,
        onFocusChange: ((Bool) -> Void)? = nil,
        onMove: ((MoveCommandDirection) -> Void)? = nil,
        contextActions: TitleActions? = nil,
        action: @escaping () -> Void
    ) {
        self.meta = meta
        self.artworkURL = artworkURL
        self.size = size
        self.watched = watched
        self.progress = progress
        self.badge = badge
        self.caption = caption
        self.alwaysShowCaption = alwaysShowCaption
        self.externalFocus = externalFocus
        self.focusValue = focusValue
        self.shouldRequestInitialFocus = shouldRequestInitialFocus
        self.onInitialFocusRequested = onInitialFocusRequested
        self.onFocusChange = onFocusChange
        self.onMove = onMove
        self.contextActions = contextActions
        self.overlay = { EmptyView() }
        self.action = action
    }
}

// MARK: - Pieces

/// Whether a tile shows the watched checkmark.
enum PosterWatched {
    /// Never show the badge.
    case hidden
    /// Let the badge observe the watched store for the tile's title.
    case lookup
    /// The caller already knows.
    case resolved(Bool)
}

/// Everything the title context menu can offer. Maps 1:1 onto
/// `titleActionsContextMenu`.
struct TitleActions {
    var onOpenDetails: (() -> Void)? = nil
    var continueProgress: Double? = nil
    var continueIsUpNext = false
    var onPlayManually: (() -> Void)? = nil
    var onStartFromBeginning: (() -> Void)? = nil
    var onRemoveFromContinueWatching: (() -> Void)? = nil
}

private struct TitleActionsMenu: ViewModifier {
    let meta: NuvioMeta
    let actions: TitleActions

    func body(content: Content) -> some View {
        content.titleActionsContextMenu(
            meta: meta,
            onOpenDetails: actions.onOpenDetails,
            continueProgress: actions.continueProgress,
            continueIsUpNext: actions.continueIsUpNext,
            onPlayManually: actions.onPlayManually,
            onStartFromBeginning: actions.onStartFromBeginning,
            onRemoveFromContinueWatching: actions.onRemoveFromContinueWatching
        )
    }
}

private struct PosterMoveCommandHandler: ViewModifier {
    let handler: ((MoveCommandDirection) -> Void)?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let handler {
            content.onMoveCommand(perform: handler)
        } else {
            content
        }
    }
}

/// What a tile shows before, or instead of, its artwork.
struct PosterTilePlaceholder: View {
    let type: String

    var body: some View {
        ZStack {
            Rectangle().fill(Color.white.opacity(0.07))
            Image(systemName: type == "series" ? "tv" : "film")
                .font(.system(size: 40))
                .foregroundStyle(.white.opacity(0.25))
        }
    }
}

private extension PosterBadgeTint {
    var color: Color {
        switch self {
        case .neutral: return Color.black.opacity(0.72)
        case .newSeason: return Color(red: 0xB4 / 255, green: 0x53 / 255, blue: 0x09 / 255)
        case .newEpisode: return Color(red: 0x1D / 255, green: 0x4E / 255, blue: 0xD8 / 255)
        case .airingToday: return Color(red: 0x05 / 255, green: 0x96 / 255, blue: 0x69 / 255)
        case .upcoming: return Color(red: 0x47 / 255, green: 0x55 / 255, blue: 0x69 / 255)
        }
    }
}

// MARK: - Poster labels setting

/// The one poster setting left. Published once per screen so a grid registers
/// a single UserDefaults observer rather than one per card.
private struct PosterLabelsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var posterLabels: Bool {
        get { self[PosterLabelsKey.self] }
        set { self[PosterLabelsKey.self] = newValue }
    }
}

/// Installed once in the app container, below `.defaultAppStorage(...)` so the
/// value resolves against the active profile's suite.
struct PosterLabelsProvider<Content: View>: View {
    @ViewBuilder var content: Content
    @AppStorage(SettingsKey.posterLabels) private var posterLabels = false

    var body: some View {
        content.environment(\.posterLabels, posterLabels)
    }
}
