//
//  PosterCard.swift
//  NuvioTV
//
//  Reusable poster card component for iOS/tvOS
//

import CryptoKit
import ImageIO
import SwiftUI
#if os(tvOS)
import AVFoundation
import AVKit
import CoreMedia
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Card corner radius options available in Settings (matching Android TV & Apple TV styling)
enum CardCornerRadiusOption: String, CaseIterable, Identifiable {
    case sharp = "Sharp (0pt)"
    case subtle = "Subtle (8pt)"
    case classic = "Classic (16pt)"
    case rounded = "Rounded (22pt)"
    case pill = "Pill (28pt)"

    var id: String { rawValue }

    var radius: CGFloat {
        switch self {
        case .sharp: return 0
        case .subtle: return 8
        case .classic: return 16
        case .rounded: return 22
        case .pill: return 28
        }
    }

    var scale: CGFloat {
        radius / 16.0
    }

    static func from(rawValue: String?) -> CardCornerRadiusOption {
        guard let rawValue, !rawValue.isEmpty else { return .classic }
        if let match = CardCornerRadiusOption(rawValue: rawValue) {
            return match
        }
        let lower = rawValue.lowercased()
        if lower.contains("sharp") || rawValue == "0" { return .sharp }
        if lower.contains("subtle") || rawValue == "8" { return .subtle }
        if lower.contains("classic") || lower.contains("standard") || rawValue == "16" { return .classic }
        if lower.contains("rounded") || rawValue == "22" { return .rounded }
        if lower.contains("pill") || rawValue == "28" { return .pill }
        return .classic
    }
}


/// Global card styling resolver
enum AppCardStyle {
    static let defaultCornerRadiusRaw = CardCornerRadiusOption.classic.rawValue

    static func cornerRadius(for rawValue: String?, fallback: CGFloat = 16) -> CGFloat {
        guard let rawValue, !rawValue.isEmpty else { return fallback }
        return CardCornerRadiusOption.from(rawValue: rawValue).radius
    }

    static func cornerRadiusScale(for rawValue: String?) -> CGFloat {
        CardCornerRadiusOption.from(rawValue: rawValue).scale
    }




    static func episodeCornerRadius(for rawValue: String?) -> CGFloat {
        let opt = CardCornerRadiusOption.from(rawValue: rawValue)
        switch opt {
        case .sharp: return 0
        case .subtle: return 12
        case .classic: return 24
        case .rounded: return 30
        case .pill: return 38
        }
    }

    static func badgeCornerRadius(for rawValue: String?, base: CGFloat = 10) -> CGFloat {
        let opt = CardCornerRadiusOption.from(rawValue: rawValue)
        switch opt {
        case .sharp: return 0
        case .subtle: return max(4, base * 0.6)
        case .classic: return base
        case .rounded: return base * 1.3
        case .pill: return base * 1.8
        }
    }
}

/// Poster card component with focus animation (tvOS) and tap handling (iOS)
struct PosterCard: View {
    let meta: NuvioMeta
    var isLandscape: Bool = false
    var continueProgress: Double? = nil
    var continueRemainingText: String? = nil
    var continueEpisodeText: String? = nil
    var continueEpisodeTitleText: String? = nil
    /// The episode still is more useful than the series backdrop for an up-next
    /// card: it matches the episode title and the Android Continue Watching row.
    var continueEpisodeArtworkURL: String? = nil
    /// Fresh next-episode suggestion: the badge reads "Next Up" (or "New Episode"
    /// for a genuinely fresh drop) and the progress bar is hidden, since there's
    /// no real playback position yet.
    var continueIsUpNext: Bool = false
    var continueUpNextBadgeText: String? = nil
    var showsWatchedBadge: Bool = true
    var shouldRequestInitialFocus: Bool = false
    var onInitialFocusRequested: (() -> Void)? = nil
    var onFocus: ((NuvioMeta) -> Void)? = nil
    var onBlur: ((NuvioMeta) -> Void)? = nil
    /// Optional shared focus state so a parent can drive `.defaultFocus`
    /// restoration — e.g. returning to the exact card after the menu. Keyed by
    /// `externalFocusValue` (must be unique per card instance, since the same
    /// meta.id can appear in more than one row), falling back to meta.id.
    var externalFocus: FocusState<String?>.Binding? = nil
    var externalFocusValue: String? = nil
    /// Fired when the card is held (Siri Remote select press-and-hold), to raise
    /// the quick-actions menu. Nil disables the long-press.
    var onLongPress: ((NuvioMeta) -> Void)? = nil
    var onOpenDetails: (() -> Void)? = nil
    var onPlayManually: (() -> Void)? = nil
    var onStartFromBeginning: (() -> Void)? = nil
    var onRemoveFromContinueWatching: (() -> Void)? = nil
    var showPosterLabels: Bool = false
    var smoothFocusAnimations: Bool = true
    var focusHighlighterEnabled: Bool = false
    /// Lets Home retain off-window artwork without leaving every card in the
    /// tvOS focus graph.
    var allowsFocus: Bool = true
    var isWatched: Bool? = nil
    let onClick: () -> Void

    private let landscapeTransitionDuration: TimeInterval = 0.3

    #if os(tvOS)
    @FocusState private var isFocused: Bool
    @State private var didRequestInitialFocus = false
    @State private var landscapeArtworkPrepared = false
    @AppStorage(SettingsKey.trailersEnabled) private var trailersEnabled = true
    @AppStorage(SettingsKey.trailerDelay) private var trailerDelay = 7
    private let cardCornerRadiusSetting = AppCardStyle.defaultCornerRadiusRaw
    private let liquidGlassCards = true
    @State private var isTrailerPreviewActive = false
    @State private var isTrailerPreviewReady = false
    @State private var didFinishTrailerPreview = false
    /// Rapid navigation should not start a separate backdrop/episode-art decode
    /// for every card passed over. Arm that preload only after focus has settled,
    /// matching Home's hero debounce.
    @State private var landscapePreloadArmed = false
    #else
    private let cardCornerRadiusSetting = AppCardStyle.defaultCornerRadiusRaw
    private let liquidGlassCards = true
    #endif

    var body: some View {
        #if os(tvOS)
        Button(action: onClick) {
            // Equality boundary owned by the card itself: parents rebuild this
            // value with fresh closures on every focus move, so without it every
            // realized card in the row re-ran its body per remote press.
            PosterCardRenderGate(key: renderKey) { posterContent }
                .equatable()
        }
        .buttonStyle(PosterCardButtonStyle())
        .disabled(!allowsFocus)
        .focused($isFocused)
        .modifier(ExternalFocusBinding(binding: externalFocus, id: externalFocusValue ?? meta.id))
        .nuvioFocusEffectDisabledIfAvailable()
        .titleActionsContextMenu(
            meta: meta,
            onOpenDetails: onOpenDetails ?? onClick,
            continueProgress: continueProgress,
            continueIsUpNext: continueIsUpNext,
            onPlayManually: onPlayManually,
            onStartFromBeginning: onStartFromBeginning,
            onRemoveFromContinueWatching: onRemoveFromContinueWatching
        )
            .onChange(of: isFocused) { _, focused in
                if focused {
                    onFocus?(meta)
                    if didFinishTrailerPreview { didFinishTrailerPreview = false }
                } else {
                    if landscapePreloadArmed { landscapePreloadArmed = false }
                    cancelTrailerPreview()
                    onBlur?(meta)
                }
            }
            // A task keyed to the real rendered state cannot miss the landscape
            // transition. It is cancelled automatically if focus/landscape or
            // the setting changes before the full delay has elapsed.
            .task(id: trailerActivationIdentity) {
                await activateTrailerPreviewAfterDelay()
            }
            .onDisappear(perform: cancelTrailerPreview)
            .task(id: isFocused) {
                guard isFocused else { return }
                do {
                    try await Task.sleep(nanoseconds: 300_000_000)
                } catch {
                    return
                }
                guard !Task.isCancelled, isFocused else { return }
                landscapePreloadArmed = true
                TVHomeDebugTrace.log(
                    "card.preload.arm meta=\(meta.id) landscapeURL=\(landscapeArtworkURL != nil) "
                        + "episodeArt=\(continueEpisodeArtworkURL != nil)"
                )
            }
            .onAppear {
                guard shouldRequestInitialFocus, !didRequestInitialFocus else {
                    return
                }

                didRequestInitialFocus = true
                onInitialFocusRequested?()
                DispatchQueue.main.async {
                    isFocused = true
                }
            }
            // The row cell takes the full (landscape) width so neighbouring
            // cards are pushed aside rather than overlapped, while the focusable
            // surface stays portrait-width — keeping up/down navigation aligned.
            .frame(width: cardWidth, height: totalCardHeight, alignment: .topLeading)
            // Critically damped — no overshoot when expanding to landscape on Home.
            .animation(
                effectiveSmoothFocus
                    ? .spring(response: landscapeTransitionDuration, dampingFraction: 1.0)
                    : nil,
                value: effectiveLandscape
            )
        #else
        Button(action: onClick) {
            posterContent
        }
        .buttonStyle(PosterCardButtonStyle())
        .titleActionsContextMenu(
            meta: meta,
            onOpenDetails: onOpenDetails ?? onClick,
            continueProgress: continueProgress,
            continueIsUpNext: continueIsUpNext,
            onPlayManually: onPlayManually,
            onStartFromBeginning: onStartFromBeginning,
            onRemoveFromContinueWatching: onRemoveFromContinueWatching
        )
        .frame(width: cardWidth, height: totalCardHeight, alignment: .topLeading)
        #endif
    }

    private var posterContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            CachedPosterArtwork(
                urlString: imageUrl,
                preloadURLString: landscapePreloadURL,
                width: cardWidth,
                height: cardHeight,
                maximumWidth: artworkDecodeWidth,
                preloadMaximumWidth: landscapeArtworkDecodeWidth,
                minimumSwapDelay: 0,
                onPreloadFinished: {
                    #if os(tvOS)
                    landscapeArtworkPrepared = true
                    #endif
                }
            ) {
                placeholderView
            }
            .frame(width: cardWidth, height: cardHeight)
            #if os(tvOS)
            // Cross-fade the landscape artwork away only once the resolved
            // trailer is ready to draw, avoiding a black frame on slow links.
            .opacity(isTrailerPreviewVisible ? 0 : 1)
            .overlay {
                // Mount only once focus has settled (the same 300 ms arm as the
                // landscape preload). Activation is always at least a second
                // away, so resolution still finishes ahead of playback; cards
                // merely passed over never allocate a player or hit the network.
                if isFocused && landscapePreloadArmed && trailersEnabled && !isContinueOrUpcomingCard && !didFinishTrailerPreview {
                    TrailerPreviewPlayer(
                        meta: meta,
                        isActive: isTrailerPreviewActive,
                        onPlaybackReady: {
                            guard isTrailerPreviewActive else { return }
                            isTrailerPreviewReady = true
                        },
                        onPlaybackFinished: finishTrailerPreview
                    )
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.32), value: isTrailerPreviewVisible)
            .animation(.easeInOut(duration: 0.32), value: didFinishTrailerPreview)
            #endif
            .overlay(alignment: .bottomLeading) {
                if effectiveLandscape {
                    landscapeOverlay
                        #if os(tvOS)
                        .opacity(isTrailerPreviewVisible ? 0 : 1)
                        #endif
                }
            }
            .overlay(alignment: .bottomLeading) {
                continueProgressOverlay
            }
            .overlay(alignment: .topTrailing) {
                continueBadge
            }
            .overlay(alignment: .topTrailing) {
                if showsWatchedBadge {
                    if let isWatched {
                        if isWatched {
                            WatchedCheckmarkIcon()
                        }
                    } else {
                        WatchedCheckmarkBadge(meta: meta)
                    }
                }
            }
            // Mask the complete card interior after composing both the trailer
            // and landscape artwork overlays. The focus border remains outside
            // this mask so its stroke stays crisp.
            .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
            .modifier(
                LiquidGlassCardModifier(
                    cornerRadius: cardCornerRadius,
                    isFocused: showsFocusedAppearance,
                    isEnabled: liquidGlassCards
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                    .stroke(focusedBorderColor, lineWidth: focusedBorderWidth)
            )
            .shadow(color: .black.opacity(shadowOpacity), radius: shadowRadius)

            if showsPosterTitle {
                Text(meta.name)
                    .font(.system(size: 20, weight: showsFocusedAppearance ? .semibold : .medium))
                    .foregroundColor(titleColor)
                    .lineLimit(1)
                    .frame(width: cardWidth, alignment: .leading)
            }
        }
        .frame(width: layoutWidth, height: totalCardHeight, alignment: .topLeading)
    }

    // MARK: - Helper Views

    private var placeholderView: some View {
        ArtworkPlaceholder(
            hasArtworkURL: imageUrl?.isEmpty == false,
            cornerRadius: cardCornerRadius
        )
    }

    @ViewBuilder
    private var landscapeOverlay: some View {
        ZStack(alignment: .bottomLeading) {
            if liquidGlassCards {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: .black.opacity(0.38), location: 0.35),
                        .init(color: .black.opacity(0.85), location: 0.85),
                        .init(color: .black.opacity(0.95), location: 1.0)
                    ],
                    startPoint: .center,
                    endPoint: .bottom
                )
            } else {
                LinearGradient(
                    colors: [.clear, .black.opacity(0.78)],
                    startPoint: .center,
                    endPoint: .bottom
                )
            }

            if continueEpisodeText != nil {
                continueLandscapeSummary
            } else if let logoURL = landscapeLogoURL {
                AsyncImage(url: logoURL) { phase in
                    if case .success(let image) = phase {
                        image
                            .resizable()
                            .scaledToFit()
                    } else {
                        fallbackTitle
                    }
                }
                .frame(width: landscapeLogoWidth, height: landscapeLogoHeight, alignment: .leading)
                .padding(22)
            } else {
                fallbackTitle
                    .frame(maxWidth: cardWidth * 0.62, alignment: .leading)
                    .padding(22)
            }
        }
    }

    private var continueLandscapeSummary: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let continueEpisodeText {
                Text(continueEpisodeText)
                    .font(.system(size: 25, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
            }

            Text(meta.name)
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.82)

            if let continueEpisodeTitleText, !continueEpisodeTitleText.isEmpty {
                Text(continueEpisodeTitleText)
                    .font(.system(size: 23, weight: .medium))
                    .foregroundColor(.white.opacity(0.66))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
        }
        .frame(maxWidth: cardWidth * 0.70, alignment: .leading)
        .padding(EdgeInsets(top: 22, leading: 22, bottom: 54, trailing: 22))
    }

    private var fallbackTitle: some View {
        Text(meta.name)
            .font(.custom("Inter-Bold", size: 34))
            .foregroundColor(.white)
            .lineLimit(2)
    }

    /// Source title logo trimmed of surrounding whitespace, or nil when blank
    /// or not a valid URL — in which case `landscapeOverlay` shows the title
    /// text fallback.
    private var landscapeLogoURL: URL? {
        guard let raw = meta.logoUrl?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty else {
            return nil
        }
        return URL(string: raw)
    }

    @ViewBuilder
    private var continueBadge: some View {
        if let continueBadgeDisplayText {
            let badgeRadius = AppCardStyle.badgeCornerRadius(for: cardCornerRadiusSetting, base: 10)
            Text(continueBadgeDisplayText)
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background {
                    if liquidGlassCards {
                        RoundedRectangle(cornerRadius: badgeRadius, style: .continuous)
                            .fill(continueBadgeFill.opacity(0.75))
                            .modifier(
                                LiquidGlassBadgeModifier(
                                    cornerRadius: badgeRadius,
                                    isFocused: showsFocusedAppearance
                                )
                            )
                    } else {
                        RoundedRectangle(cornerRadius: badgeRadius, style: .continuous)
                            .fill(continueBadgeFill)
                    }
                }
                .padding(16)
        }
    }

    private var continueBadgeFill: Color {
        guard continueIsUpNext else { return Color.black.opacity(0.72) }
        let badge = (continueUpNextBadgeText ?? "Next Up").uppercased()
        if badge == "NEW SEASON" {
            return Color(red: 0xB4 / 255, green: 0x53 / 255, blue: 0x09 / 255)
        } else if badge == "NEW EPISODE" {
            return Color(red: 0x1D / 255, green: 0x4E / 255, blue: 0xD8 / 255)
        } else if badge == "AIRING TODAY" {
            return Color(red: 0x05 / 255, green: 0x96 / 255, blue: 0x69 / 255)
        } else if badge.hasPrefix("AIRS IN") || badge == "COMING SOON" {
            return Color(red: 0x47 / 255, green: 0x55 / 255, blue: 0x69 / 255)
        } else {
            return Color.black.opacity(0.72)
        }
    }

    private var continueBadgeDisplayText: String? {
        if continueIsUpNext { return continueUpNextBadgeText ?? "Next Up" }
        guard let continueRemainingText else { return nil }
        if let continueEpisodeText {
            return "\(continueEpisodeText) • \(continueRemainingText)"
        }
        return continueRemainingText
    }

    @ViewBuilder
    private var continueProgressOverlay: some View {
        if let continueProgress, !continueIsUpNext {
            let progress = CGFloat(min(max(continueProgress, 0), 1))
            let width = max(0, cardWidth - 44)

            VStack {
                Spacer(minLength: 0)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.38))
                        .frame(width: width, height: 8)

                    Capsule()
                        .fill(Color.white)
                        .frame(width: max(8, width * progress), height: 8)
                }
                .padding(.leading, 22)
                .padding(.bottom, 16)
            }
            .frame(width: cardWidth, height: cardHeight, alignment: .bottomLeading)
        }
    }

    // MARK: - Computed Properties

    #if os(tvOS)

    private var effectivePosterLabels: Bool {
        showPosterLabels
    }

    private var effectiveSmoothFocus: Bool {
        smoothFocusAnimations
    }

    private var effectiveFocusHighlighter: Bool {
        focusHighlighterEnabled
    }

    private var effectiveLandscape: Bool {
        isLandscape && (landscapeArtworkPrepared || landscapeArtworkURL == nil)
    }

    private var cardWidth: CGFloat {
        if effectiveLandscape {
            return 560
        }
        return 210
    }

    /// Width the card occupies in the row layout — and therefore its focus
    /// frame. Always the portrait width, even while the landscape art is shown,
    /// so a focused landscape card does NOT widen its focus region and bump
    /// vertical navigation onto the neighbouring column. The 560pt landscape art
    /// overflows this frame to the right and is drawn above siblings (zIndex).
    private var layoutWidth: CGFloat {
        210
    }

    private var cardHeight: CGFloat {
        effectiveLandscape ? 315 : 315
    }

    private var totalCardHeight: CGFloat {
        cardHeight + (showsPosterTitle ? 36 : 0)
    }

    private var landscapeLogoWidth: CGFloat {
        275
    }

    private var landscapeLogoHeight: CGFloat {
        84
    }

    private var cardCornerRadius: CGFloat {
        AppCardStyle.cornerRadius(for: cardCornerRadiusSetting, fallback: 16)
    }

    private var landscapeArtworkURL: String? {
        if continueEpisodeText != nil,
           let continueEpisodeArtworkURL, !continueEpisodeArtworkURL.isEmpty {
            return continueEpisodeArtworkURL
        }
        return meta.backgroundUrl ?? meta.posterUrl
    }

    private var imageUrl: String? {
        effectiveLandscape ? landscapeArtworkURL : meta.posterUrl
    }

    private var landscapePreloadURL: String? {
        landscapePreloadArmed || isLandscape ? landscapeArtworkURL : nil
    }

    private var artworkDecodeWidth: CGFloat {
        effectiveLandscape ? 560 : cardWidth
    }

    private var landscapeArtworkDecodeWidth: CGFloat {
        560
    }

    private var focusedBorderColor: Color {
        guard showsFocusedAppearance else { return .clear }
        return AppFocusOutline.color
    }

    private var focusedBorderWidth: CGFloat {
        showsFocusedAppearance ? (effectiveFocusHighlighter ? AppFocusOutline.emphasizedWidth : AppFocusOutline.width) : 0
    }

    private var shadowOpacity: Double {
        showsFocusedAppearance ? 0.24 : 0.12
    }

    private var shadowRadius: CGFloat {
        showsFocusedAppearance ? 10 : 4
    }

    private var titleColor: Color {
        showsFocusedAppearance ? .white : .white.opacity(0.55)
    }

    private var showsFocusedAppearance: Bool {
        isFocused
    }

    private var showsPosterTitle: Bool {
        effectivePosterLabels
    }

    private var isContinueOrUpcomingCard: Bool {
        continueProgress != nil || continueIsUpNext || continueRemainingText != nil || continueEpisodeText != nil || continueUpNextBadgeText != nil
    }

    private var trailerActivationIdentity: String {
        "\(isFocused)\u{1f}\(effectiveLandscape)\u{1f}\(trailersEnabled)\u{1f}\(trailerDelay)\u{1f}\(isContinueOrUpcomingCard)"
    }

    /// Everything `posterContent` reads. Keep it complete: the render gate reuses
    /// the retained poster subtree whenever this key is unchanged, so a value
    /// missing here would be drawn stale.
    private var renderKey: PosterCardRenderKey {
        PosterCardRenderKey(
            base: staticKey,
            isFocused: isFocused,
            landscapeArtworkPrepared: landscapeArtworkPrepared,
            landscapePreloadArmed: landscapePreloadArmed,
            cardCornerRadiusSetting: cardCornerRadiusSetting,
            liquidGlassCards: liquidGlassCards,
            trailersEnabled: trailersEnabled,
            trailerDelay: trailerDelay,
            isTrailerPreviewActive: isTrailerPreviewActive,
            isTrailerPreviewReady: isTrailerPreviewReady,
            didFinishTrailerPreview: didFinishTrailerPreview
        )
    }

    private var isTrailerPreviewVisible: Bool {
        !isContinueOrUpcomingCard && isTrailerPreviewActive && isTrailerPreviewReady && !didFinishTrailerPreview
    }

    @MainActor
    private func activateTrailerPreviewAfterDelay() async {
        resetTrailerPreviewState()
        guard isFocused, effectiveLandscape, trailersEnabled, !isContinueOrUpcomingCard else { return }

        let delay = max(1, trailerDelay)
        do {
            try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
        } catch {
            return
        }
        guard !Task.isCancelled, isFocused, effectiveLandscape, trailersEnabled, !isContinueOrUpcomingCard else { return }
        isTrailerPreviewActive = true
    }

    // `@State` setters invalidate the view even when the value is unchanged, and
    // these run on every focus transition, so only write what actually differs.
    private func resetTrailerPreviewState() {
        cancelTrailerPreview()
        if didFinishTrailerPreview { didFinishTrailerPreview = false }
    }

    private func cancelTrailerPreview() {
        if isTrailerPreviewActive { isTrailerPreviewActive = false }
        if isTrailerPreviewReady { isTrailerPreviewReady = false }
    }

    private func finishTrailerPreview() {
        isTrailerPreviewActive = false
        isTrailerPreviewReady = false
        didFinishTrailerPreview = true
    }
    #else
    private var cardWidth: CGFloat {
        150
    }

    private var layoutWidth: CGFloat {
        150
    }

    private var cardHeight: CGFloat {
        225
    }

    private var cardCornerRadius: CGFloat {
        AppCardStyle.cornerRadius(for: cardCornerRadiusSetting, fallback: 8)
    }

    private var landscapeLogoWidth: CGFloat {
        0
    }

    private var landscapeLogoHeight: CGFloat {
        0
    }

    private var imageUrl: String? {
        meta.posterUrl
    }

    private var landscapePreloadURL: String? {
        nil
    }

    private var artworkDecodeWidth: CGFloat {
        cardWidth
    }

    private var landscapeArtworkDecodeWidth: CGFloat {
        cardWidth
    }

    private var effectiveLandscape: Bool {
        false
    }

    private var focusedBorderColor: Color {
        .clear
    }

    private var focusedBorderWidth: CGFloat {
        0
    }

    private var shadowOpacity: Double {
        0.2
    }

    private var shadowRadius: CGFloat {
        4
    }

    private var titleColor: Color {
        .primary
    }

    private var totalCardHeight: CGFloat {
        cardHeight
    }

    private var showsPosterTitle: Bool {
        false
    }
    #endif
}

/// Every call-site value the card draws, with closures reduced to presence.
/// Single source of truth for `PosterCard.==` and for the in-card render gate,
/// so there is one list to keep complete. Numeric and optional-text inputs are
/// stringified so the key does not depend on their exact model types.
struct PosterCardStaticKey: Equatable {
    let metaID: String
    let metaName: String
    let metaType: String
    let posterURL: String?
    let backgroundURL: String?
    let logoURL: String?
    let imdbID: String?
    let tmdbID: String?
    let year: String?
    let trailerYtIds: [String]?
    let isLandscape: Bool
    let continueProgress: String?
    let continueRemainingText: String?
    let continueEpisodeText: String?
    let continueEpisodeTitleText: String?
    let continueEpisodeArtworkURL: String?
    let continueIsUpNext: Bool
    let continueUpNextBadgeText: String?
    let showsWatchedBadge: Bool
    let isWatched: Bool?
    let shouldRequestInitialFocus: Bool
    let externalFocusValue: String?
    let hasOnLongPress: Bool
    let hasOnOpenDetails: Bool
    let hasOnPlayManually: Bool
    let hasOnStartFromBeginning: Bool
    let hasOnRemoveFromContinueWatching: Bool
    let showPosterLabels: Bool
    let smoothFocusAnimations: Bool
    let focusHighlighterEnabled: Bool
    let allowsFocus: Bool
}

extension PosterCard {
    var staticKey: PosterCardStaticKey {
        PosterCardStaticKey(
            metaID: meta.id,
            metaName: meta.name,
            metaType: meta.type,
            posterURL: meta.posterUrl,
            backgroundURL: meta.backgroundUrl,
            logoURL: meta.logoUrl,
            imdbID: meta.imdbId,
            tmdbID: meta.tmdbId.map { "\($0)" },
            year: meta.year.map { "\($0)" },
            trailerYtIds: meta.trailerYtIds,
            isLandscape: isLandscape,
            continueProgress: continueProgress.map { "\($0)" },
            continueRemainingText: continueRemainingText.map { "\($0)" },
            continueEpisodeText: continueEpisodeText.map { "\($0)" },
            continueEpisodeTitleText: continueEpisodeTitleText.map { "\($0)" },
            continueEpisodeArtworkURL: continueEpisodeArtworkURL.map { "\($0)" },
            continueIsUpNext: continueIsUpNext,
            continueUpNextBadgeText: continueUpNextBadgeText.map { "\($0)" },
            showsWatchedBadge: showsWatchedBadge,
            isWatched: isWatched,
            shouldRequestInitialFocus: shouldRequestInitialFocus,
            externalFocusValue: externalFocusValue,
            hasOnLongPress: onLongPress != nil,
            hasOnOpenDetails: onOpenDetails != nil,
            hasOnPlayManually: onPlayManually != nil,
            hasOnStartFromBeginning: onStartFromBeginning != nil,
            hasOnRemoveFromContinueWatching: onRemoveFromContinueWatching != nil,
            showPosterLabels: showPosterLabels,
            smoothFocusAnimations: smoothFocusAnimations,
            focusHighlighterEnabled: focusHighlighterEnabled,
            allowsFocus: allowsFocus
        )
    }
}

// Home's vertical offset animates at the parent level. Without an equality
// boundary, every parent focus update rebuilds the full poster subtree for
// every mounted row, even though almost every card is unchanged. Keep dynamic
// focus bindings inside the retained subtree while invalidating it only when a
// value that affects the card's rendering or focus eligibility changes.
extension PosterCard: Equatable {
    static func == (lhs: PosterCard, rhs: PosterCard) -> Bool {
        lhs.staticKey == rhs.staticKey
    }
}

#if os(tvOS)
/// The static key plus every piece of card-owned state `posterContent` reads.
/// Anything the content draws must appear here, or the gate will reuse a stale
/// subtree when that value changes.
struct PosterCardRenderKey: Equatable {
    let base: PosterCardStaticKey
    let isFocused: Bool
    let landscapeArtworkPrepared: Bool
    let landscapePreloadArmed: Bool
    let cardCornerRadiusSetting: String
    let liquidGlassCards: Bool
    let trailersEnabled: Bool
    let trailerDelay: Int
    let isTrailerPreviewActive: Bool
    let isTrailerPreviewReady: Bool
    let didFinishTrailerPreview: Bool
}

/// Equality boundary that ignores its content closure. With `.equatable()`,
/// SwiftUI compares `key` instead of structurally comparing the closure, so a
/// parent update that changes nothing the card draws leaves the whole poster
/// subtree (artwork, overlays, badges, trailer) untouched.
struct PosterCardRenderGate<Content: View>: View, Equatable {
    let key: PosterCardRenderKey
    private let content: () -> Content

    init(key: PosterCardRenderKey, @ViewBuilder content: @escaping () -> Content) {
        self.key = key
        self.content = content
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.key == rhs.key
    }

    var body: some View {
        content()
    }
}
#endif

#if os(tvOS)
final class TrailerPlayerLayerView: UIView {
    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }

    override static var layerClass: AnyClass {
        AVPlayerLayer.self
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        playerLayer.videoGravity = .resizeAspectFill
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        playerLayer.videoGravity = .resizeAspectFill
        backgroundColor = .clear
    }
}

struct TrailerPlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    let onReadyForDisplay: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onReadyForDisplay: onReadyForDisplay)
    }

    func makeUIView(context: Context) -> TrailerPlayerLayerView {
        let view = TrailerPlayerLayerView()
        view.playerLayer.player = player
        context.coordinator.observe(layer: view.playerLayer, player: player)
        return view
    }

    func updateUIView(_ uiView: TrailerPlayerLayerView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
            context.coordinator.observe(layer: uiView.playerLayer, player: player)
        }
    }

    final class Coordinator {
        private let onReadyForDisplay: () -> Void
        private var readyObserver: NSKeyValueObservation?
        private var timeObserver: Any?
        private weak var observedPlayer: AVPlayer?
        private var didNotify = false

        init(onReadyForDisplay: @escaping () -> Void) {
            self.onReadyForDisplay = onReadyForDisplay
        }

        func observe(layer: AVPlayerLayer, player: AVPlayer) {
            readyObserver?.invalidate()
            if let timeObserver, let observedPlayer {
                observedPlayer.removeTimeObserver(timeObserver)
            }
            self.observedPlayer = player
            self.didNotify = false

            if layer.isReadyForDisplay {
                notifyReady()
                return
            }

            readyObserver = layer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] layer, _ in
                if layer.isReadyForDisplay {
                    self?.notifyReady()
                }
            }

            timeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(value: 1, timescale: 30),
                queue: .main
            ) { [weak self] time in
                if time.seconds > 0 {
                    self?.notifyReady()
                }
            }
        }

        private func notifyReady() {
            guard !didNotify else { return }
            didNotify = true
            DispatchQueue.main.async { [weak self] in
                self?.onReadyForDisplay()
            }
        }

        deinit {
            readyObserver?.invalidate()
            if let timeObserver, let observedPlayer {
                observedPlayer.removeTimeObserver(timeObserver)
            }
        }
    }
}

/// Video preview for a settled, landscape Home card. The player is
/// created only after the configured trailer delay and is released as soon as
/// focus leaves, so scrolling never leaves background trailer audio or decoders.
private struct TrailerPreviewPlayer: View {
    let meta: NuvioMeta
    /// Resolution begins as soon as the card gains focus; playback waits for
    /// Home's configured delay to promote the card to landscape.
    let isActive: Bool
    let onPlaybackReady: () -> Void
    let onPlaybackFinished: () -> Void

    @State private var player = AVPlayer()
    @State private var isRenderReady = false
    @AppStorage(SettingsKey.trailerPreviewSound) private var trailerPreviewSound = false

    var body: some View {
        TrailerPlayerSurface(player: player) {
            guard !isRenderReady else { return }
            isRenderReady = true
            if isActive {
                onPlaybackReady()
            }
        }
        // Keep the landscape artwork visible while the trailer URL is
        // resolving and buffering, only revealing the video when decoded & ready.
        .opacity(isVisible ? 1 : 0)
        .animation(.easeInOut(duration: 0.32), value: isVisible)
        .allowsHitTesting(false)
        .task(id: previewIdentity) {
            await startPreview()
        }
        .onChange(of: isActive) { _, active in
            if active {
                player.play()
                if isRenderReady { onPlaybackReady() }
            } else {
                player.pause()
            }
        }
        .onChange(of: trailerPreviewSound) { _, soundEnabled in
            applySoundPreference(soundEnabled)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)
        ) { notification in
            guard let item = notification.object as? AVPlayerItem,
                  item == player.currentItem else {
                return
            }
            onPlaybackFinished()
        }
        .onDisappear {
            isRenderReady = false
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
    }

    private var previewIdentity: String {
        "\(meta.id)\u{1f}\(meta.trailerYtIds?.joined(separator: ",") ?? "")"
    }

    private var isVisible: Bool {
        isActive && isRenderReady
    }

    private func startPreview() async {
        isRenderReady = false

        // The shared resolver owns the 30-minute preview cache; a per-card
        // instance guaranteed a miss on every mount.
        guard let youtubeVideoId = await YouTubeTrailerResolver.preferredTrailerYouTubeId(for: meta),
              let playbackSource = await YouTubeTrailerResolver.shared.resolvePreview(
                  youtubeVideoId: youtubeVideoId,
                  title: meta.name,
                  year: meta.year.map(String.init)
              ),
              let url = URL(string: playbackSource.videoUrl),
              !Task.isCancelled else {
            return
        }

        let asset: AVURLAsset
        if let userAgent = playbackSource.requestHeaders["User-Agent"], !userAgent.isEmpty {
            asset = AVURLAsset(
                url: url,
                options: [AVURLAssetHTTPUserAgentKey: userAgent]
            )
        } else {
            asset = AVURLAsset(url: url)
        }
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 2.0
        item.preferredPeakBitRate = 0
        item.preferredMaximumResolution = .zero
        player.replaceCurrentItem(with: item)
        applySoundPreference(trailerPreviewSound)
        if isActive {
            player.play()
        }
    }

    private func applySoundPreference(_ soundEnabled: Bool) {
        player.isMuted = !soundEnabled
        player.volume = soundEnabled ? 1 : 0
        guard soundEnabled else { return }

        // Home previews do not pass through PlayerView, which normally
        // activates the movie-playback audio session for full-screen video.
        PlaybackAudioSession.activateMoviePlayback()
    }
}

#endif

#if canImport(UIKit)
/// Liquid Glass surface shared by collection folder covers and loading cards, so
/// the two cannot drift apart. tvOS 26+ uses real `glassEffect`; older systems
/// get frosted material.
struct LiquidGlassSurface: ViewModifier {
    let cornerRadius: CGFloat
    var prominent: Bool = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(tvOS)
        if #available(tvOS 26.0, *) {
            content
                .background(
                    Color.white.opacity(prominent ? 0.16 : 0.08),
                    in: shape
                )
                .glassEffect(.regular, in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .background(
                    Color.white.opacity(prominent ? 0.16 : 0.08),
                    in: shape
                )
        }
        #else
        content
            .background(.ultraThinMaterial, in: shape)
            .background(Color.white.opacity(prominent ? 0.16 : 0.08), in: shape)
        #endif
    }
}

/// Liquid Glass surface modifier for card shapes (posters, landscape cards, episode tiles).
/// Uses native frosted glass only while focused; unfocused cards retain the
/// specular highlight with a lightweight translucent fill.
struct LiquidGlassCardModifier: ViewModifier {
    let cornerRadius: CGFloat
    var isFocused: Bool = false
    var isEnabled: Bool = true

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content
                .background {
                    #if os(tvOS)
                    if isFocused {
                        if #available(tvOS 26.0, *) {
                            shape
                                .fill(Color.white.opacity(0.16))
                                .glassEffect(.regular, in: shape)
                        } else {
                            shape
                                .fill(.ultraThinMaterial)
                                .overlay(shape.fill(Color.white.opacity(0.14)))
                        }
                    } else {
                        shape
                            .fill(Color.white.opacity(0.07))
                    }
                    #else
                    if isFocused {
                        shape
                            .fill(.ultraThinMaterial)
                            .overlay(shape.fill(Color.white.opacity(0.14)))
                    } else {
                        shape.fill(Color.white.opacity(0.07))
                    }
                    #endif
                }
                .overlay {
                    // Apple TV liquid glass specular reflection border
                    shape
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(isFocused ? 0.55 : 0.28),
                                    Color.white.opacity(isFocused ? 0.20 : 0.08),
                                    Color.white.opacity(isFocused ? 0.35 : 0.12)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: isFocused ? 1.5 : 1.0
                        )
                }
        } else {
            content
        }
    }
}

/// Frosted liquid glass pill/badge modifier for metadata tags, episode chips, and progress overlays.
struct LiquidGlassBadgeModifier: ViewModifier {
    let cornerRadius: CGFloat
    var isFocused: Bool = true

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if isFocused {
            #if os(tvOS)
            if #available(tvOS 26.0, *) {
                content
                    .glassEffect(.regular, in: shape)
                    .overlay(
                        shape.strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.40), Color.white.opacity(0.12)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                    )
            } else {
                content
                    .background(.ultraThinMaterial, in: shape)
                    .overlay(
                        shape.strokeBorder(Color.white.opacity(0.24), lineWidth: 1)
                    )
            }
            #else
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(
                    shape.strokeBorder(Color.white.opacity(0.24), lineWidth: 1)
                )
            #endif
        } else {
            content.overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.28), Color.white.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            )
        }
    }
}

extension View {
    func liquidGlassCard(cornerRadius: CGFloat, isFocused: Bool = false, isEnabled: Bool = true) -> some View {
        self.modifier(LiquidGlassCardModifier(cornerRadius: cornerRadius, isFocused: isFocused, isEnabled: isEnabled))
    }

    func liquidGlassBadge(cornerRadius: CGFloat, isFocused: Bool = true) -> some View {
        self.modifier(LiquidGlassBadgeModifier(cornerRadius: cornerRadius, isFocused: isFocused))
    }
}

/// A card standing in for one whose row has no data yet.
///
/// This is the one place a spinner still belongs: the row's catalog request is
/// genuinely outstanding and will either answer or fail, unlike a single poster
/// URL that can hang forever with nothing left to report. Uses the same
/// lightweight card modifier as loaded posters so loading rows remain cheap.
struct LoadingPosterCard: View {
    let width: CGFloat
    let height: CGFloat
    var cornerRadius: CGFloat = 16
    var isLiquidGlassEnabled: Bool = true

    var body: some View {
        ZStack {
            Color.clear

            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white.opacity(0.55))
        }
        .frame(width: width, height: height)
        .modifier(LiquidGlassCardModifier(
            cornerRadius: cornerRadius,
            isEnabled: isLiquidGlassEnabled
        ))
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// What a card shows when it has no artwork on screen.
///
/// Matches the Android app, where `AsyncImage` is given the same flat card
/// painter for `placeholder`, `error` and `fallback`: loading and failed look
/// identical, so a poster that never arrives is a quiet empty card rather than
/// a spinner with no exit. An add-on that generates art on demand answers some
/// titles in milliseconds and others never, and only the card knows which — a
/// progress indicator promises an arrival nothing can guarantee.
///
/// A title with no artwork URL at all keeps the glyph, the same distinction
/// Android draws with `MonochromePosterPlaceholder`.
struct ArtworkPlaceholder: View {
    let hasArtworkURL: Bool
    let cornerRadius: CGFloat

    var body: some View {
        ZStack {
            Color.clear

            if !hasArtworkURL {
                Image(systemName: "photo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 42, height: 42)
                    .foregroundColor(.white.opacity(0.38))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.white.opacity(0.07))
        )
    }
}

struct CachedPosterArtwork<Placeholder: View>: View {
    let urlString: String?
    var preloadURLString: String? = nil
    let width: CGFloat
    let height: CGFloat
    var maximumWidth: CGFloat? = nil
    var preloadMaximumWidth: CGFloat? = nil
    var minimumSwapDelay: TimeInterval = 0
    var onPreloadFinished: () -> Void = {}
    @ViewBuilder let placeholder: Placeholder

    init(
        urlString: String?,
        preloadURLString: String? = nil,
        width: CGFloat,
        height: CGFloat,
        maximumWidth: CGFloat? = nil,
        preloadMaximumWidth: CGFloat? = nil,
        minimumSwapDelay: TimeInterval = 0,
        onPreloadFinished: @escaping () -> Void = {},
        @ViewBuilder placeholder: () -> Placeholder
    ) {
        self.urlString = urlString
        self.preloadURLString = preloadURLString
        self.width = width
        self.height = height
        self.maximumWidth = maximumWidth
        self.preloadMaximumWidth = preloadMaximumWidth
        self.minimumSwapDelay = minimumSwapDelay
        self.onPreloadFinished = onPreloadFinished
        self.placeholder = placeholder()
    }

    @State private var image: UIImage?
    @State private var loadedKey: String?
    /// Keep the preceding artwork variant alive while the card changes shape.
    /// A Home card swaps between poster and backdrop URLs; retaining both lets
    /// the poster reappear immediately and crop down with the width animation
    /// instead of flashing the placeholder for a frame.
    @State private var previousImage: UIImage?
    @State private var previousLoadedKey: String?
    @State private var preloadedImage: UIImage?
    @State private var preloadedKey: String?

    private var maxPixelSize: Int {
        let displayScale = UIScreen.main.scale
        let targetMaxWidth = maximumWidth ?? width
        return max(160, Int(ceil(max(targetMaxWidth, height) * displayScale)))
    }

    private var preloadMaxPixelSize: Int {
        let displayScale = UIScreen.main.scale
        let targetMaxWidth = preloadMaximumWidth ?? maximumWidth ?? width
        return max(160, Int(ceil(max(targetMaxWidth, height) * displayScale)))
    }

    private var cacheKey: String {
        "\(urlString ?? "")#\(maxPixelSize)"
    }

    private var preloadCacheKey: String {
        "\(preloadURLString ?? "")#\(preloadMaxPixelSize)"
    }

    var body: some View {
        ZStack(alignment: .center) {
            if let image = displayedImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: width, height: height, alignment: .center)
                    .clipped()
            } else {
                placeholder
            }
        }
        .task(id: cacheKey) {
            await load()
        }
        .task(id: preloadCacheKey) {
            await preload()
        }
    }

    private var displayedImage: UIImage? {
        if loadedKey == cacheKey { return image }
        if preloadedKey == cacheKey { return preloadedImage }
        if previousLoadedKey == cacheKey { return previousImage }

        // A remounted card has fresh state but its artwork is usually still in
        // memory. `.task` only runs after the first render, so peek synchronously
        // here to avoid drawing the placeholder for that frame.
        if let urlString, let url = URL(string: urlString),
           let hit = PosterArtworkCache.cachedImage(for: url, maxPixelSize: maxPixelSize) {
            return hit
        }

        // While a brand-new variant is loading, keep real artwork on screen.
        // For landscape expansion this naturally starts with a zoomed poster;
        // for collapse the matching portrait is normally `previousImage`.
        return image ?? previousImage
    }

    @MainActor
    private func load() async {
        guard let urlString,
              let url = URL(string: urlString) else {
            image = nil
            loadedKey = nil
            previousImage = nil
            previousLoadedKey = nil
            return
        }

        let key = cacheKey
        let traceLoad = preloadURLString != nil
        let started = TVHomeDebugTrace.now()
        if traceLoad {
            TVHomeDebugTrace.log("art.load.begin host=\(url.host ?? "unknown") key=\(key)")
        }
        let loadStartedAt = Date()
        if loadedKey == key { return }

        if preloadedKey == key, let preloadedImage {
            previousImage = image
            previousLoadedKey = loadedKey
            image = preloadedImage
            loadedKey = key
            if traceLoad {
                TVHomeDebugTrace.log(
                    "art.load.end source=preloaded ms=\(TVHomeDebugTrace.elapsedMilliseconds(since: started))"
                )
            }
            return
        }

        // Moving back from landscape to portrait should be synchronous. The
        // portrait was retained when the landscape artwork replaced it, so
        // promote it without waiting for even an in-memory actor lookup.
        if previousLoadedKey == key, let previousImage {
            image = previousImage
            loadedKey = key
            self.previousImage = nil
            previousLoadedKey = nil
            if traceLoad {
                TVHomeDebugTrace.log(
                    "art.load.end source=previous ms=\(TVHomeDebugTrace.elapsedMilliseconds(since: started))"
                )
            }
            return
        }

        // Memory hit: adopt it without the actor hop, which always suspends and
        // would otherwise leave the placeholder up for at least one frame.
        if let hit = PosterArtworkCache.cachedImage(for: url, maxPixelSize: maxPixelSize) {
            previousImage = image
            previousLoadedKey = loadedKey
            image = hit
            loadedKey = key
            if traceLoad {
                TVHomeDebugTrace.log(
                    "art.load.end source=memory ms=\(TVHomeDebugTrace.elapsedMilliseconds(since: started))"
                )
            }
            return
        }

        if let cached = await PosterArtworkCache.shared.image(for: url, maxPixelSize: maxPixelSize) {
            let remainingDelay = minimumSwapDelay - Date().timeIntervalSince(loadStartedAt)
            if remainingDelay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(remainingDelay * 1_000_000_000))
            }
            guard !Task.isCancelled, key == cacheKey else { return }
            previousImage = image
            previousLoadedKey = loadedKey
            image = cached
            loadedKey = key
        }
        if traceLoad {
            TVHomeDebugTrace.log(
                "art.load.end source=cache ms=\(TVHomeDebugTrace.elapsedMilliseconds(since: started))"
            )
        }
    }

    @MainActor
    private func preload() async {
        guard let preloadURLString,
              let url = URL(string: preloadURLString) else {
            return
        }

        let key = preloadCacheKey
        let started = TVHomeDebugTrace.now()
        TVHomeDebugTrace.log(
            "art.preload.begin host=\(url.host ?? "unknown") key=\(key)"
        )
        if loadedKey == key, let image {
            preloadedImage = image
            preloadedKey = key
            onPreloadFinished()
            TVHomeDebugTrace.log(
                "art.preload.end source=loaded ms=\(TVHomeDebugTrace.elapsedMilliseconds(since: started))"
            )
            return
        }
        if preloadedKey == key {
            onPreloadFinished()
            TVHomeDebugTrace.log(
                "art.preload.end source=preloaded ms=\(TVHomeDebugTrace.elapsedMilliseconds(since: started))"
            )
            return
        }

        let cached = await PosterArtworkCache.shared.image(
            for: url,
            maxPixelSize: preloadMaxPixelSize
        )
        if let cached {
            guard !Task.isCancelled, key == preloadCacheKey else { return }
            preloadedImage = cached
            preloadedKey = key
        }
        onPreloadFinished()
        TVHomeDebugTrace.log(
            "art.preload.end source=cache hit=\(cached != nil) "
                + "ms=\(TVHomeDebugTrace.elapsedMilliseconds(since: started))"
        )
    }
}

/// A decoded poster plus the moment it entered memory. Volatile hosts carry a
/// TTL so a rating overlay is refreshed on a schedule instead of never cached.
private final class PosterCacheEntry {
    let image: UIImage
    let storedAt: Date
    let ttl: TimeInterval?

    init(image: UIImage, storedAt: Date = Date(), ttl: TimeInterval?) {
        self.image = image
        self.storedAt = storedAt
        self.ttl = ttl
    }

    func isFresh(now: Date = Date()) -> Bool {
        guard let ttl else { return true }
        return PosterDiskCacheFreshness.isFresh(modified: storedAt, now: now, ttl: ttl)
    }
}

/// NSCache is thread-safe; this box states that so the actor can expose a
/// synchronous, nonisolated peek for the first frame of a mounting card.
private final class PosterMemoryCache: @unchecked Sendable {
    private let cache = NSCache<NSString, PosterCacheEntry>()

    init() {
        // Cost governs eviction. A count limit of 220 bound at roughly 62 MB of
        // 210x315 posters, long before the byte budget was ever reached.
        cache.countLimit = 0
        cache.totalCostLimit = 140 * 1024 * 1024
    }

    func entry(for key: NSString) -> PosterCacheEntry? {
        cache.object(forKey: key)
    }

    func store(_ entry: PosterCacheEntry, for key: NSString, cost: Int) {
        cache.setObject(entry, forKey: key, cost: cost)
    }
}

private actor PosterArtworkCache {
    static let shared = PosterArtworkCache()

    private nonisolated let memory = PosterMemoryCache()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    nonisolated static func cacheKey(for url: URL, maxPixelSize: Int) -> NSString {
        "\(url.absoluteString)#\(min(max(maxPixelSize, 160), 1400))" as NSString
    }

    /// Synchronous hit path. A mounting card can draw real artwork on its first
    /// frame instead of the placeholder it showed while awaiting the actor.
    nonisolated static func cachedImage(for url: URL, maxPixelSize: Int) -> UIImage? {
        guard let entry = shared.memory.entry(for: cacheKey(for: url, maxPixelSize: maxPixelSize)),
              entry.isFresh() else {
            return nil
        }
        return entry.image
    }

    func image(for url: URL, maxPixelSize: Int) async -> UIImage? {
        let boundedPixelSize = min(max(maxPixelSize, 160), 1400)
        let key = Self.cacheKey(for: url, maxPixelSize: boundedPixelSize)
        // Volatility now only shortens how long the bytes stay trusted; it no
        // longer disables caching, which re-downloaded on every card mount.
        let volatile = PosterArtworkCachePolicy.isVolatile(url)
        let diskTTL = PosterArtworkCachePolicy.freshnessTTL(
            for: url,
            defaultTTL: PosterDiskCache.freshnessTTL
        )

        if let entry = memory.entry(for: key), entry.isFresh() {
            return entry.image
        }

        if let task = inFlight[key as String] {
            return await task.value
        }

        let task = Task.detached(priority: .utility) { () -> UIImage? in
            // Disk before network, like Coil. The bytes are keyed by URL alone,
            // so one stored poster serves every size a card asks for.
            if let stored = await PosterDiskCache.shared.data(for: url, ttl: diskTTL),
               let image = await PosterDecodeLimiter.shared.image(
                   from: stored,
                   maxPixelSize: boundedPixelSize
               ) {
                return image
            }

            guard let data = await downloadPosterData(url: url, revalidate: volatile) else { return nil }
            await PosterDiskCache.shared.store(data, for: url)
            return await PosterDecodeLimiter.shared.image(
                from: data,
                maxPixelSize: boundedPixelSize
            )
        }

        inFlight[key as String] = task
        let image = await task.value
        inFlight[key as String] = nil

        if let image {
            memory.store(
                PosterCacheEntry(
                    image: image,
                    ttl: volatile ? PosterArtworkCachePolicy.volatileFreshnessTTL : nil
                ),
                for: key,
                cost: image.decodedByteCost
            )
        }
        return image
    }
}

/// Coil naturally keeps decode work bounded. Match that behavior so mounting a
/// newly visible Home shelf cannot fan out into a burst of AppleJPEG workers.
private actor PosterDecodeLimiter {
    static let shared = PosterDecodeLimiter(maxConcurrentDecodes: 3)

    private let maxConcurrentDecodes: Int
    private var activeDecodes = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(maxConcurrentDecodes: Int) {
        self.maxConcurrentDecodes = max(1, maxConcurrentDecodes)
    }

    func image(from data: Data, maxPixelSize: Int) async -> UIImage? {
        await acquire()
        defer { release() }

        guard !Task.isCancelled else { return nil }
        return await Task.detached(priority: .utility) {
            downsamplePosterImage(data: data, maxPixelSize: maxPixelSize)
        }.value
    }

    private func acquire() async {
        if activeDecodes < maxConcurrentDecodes {
            activeDecodes += 1
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if waiters.isEmpty {
            activeDecodes -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Poster bytes that survive relaunch, mirroring the Android image loader's
/// 200 MB Coil disk cache.
///
/// tvOS gives `URLCache` no disk store, so without this every cold start
/// re-requests every poster. Against an add-on that renders art on demand that
/// also re-triggers every slow generation, which is why the same Home looks
/// worse on Apple TV than on Android for identical add-ons. Stored raw and
/// keyed by URL alone — decoding happens per card, at that card's size.
private actor PosterDiskCache {
    static let shared = PosterDiskCache()

    private let directory: URL
    private let maximumBytes = 200 * 1024 * 1024
    private let fileManager = FileManager.default
    /// Walking the directory on every write would cost more than the eviction
    /// saves, so the sweep runs once per batch of new artwork.
    private var bytesWrittenSinceTrim = 0
    private let trimInterval = 20 * 1024 * 1024
    static let freshnessTTL: TimeInterval = 24 * 60 * 60
    /// Refresh artwork cached by releases that treated generated poster bytes
    /// as immutable. Future freshness is governed by `freshnessTTL`.
    private static let storageVersion = "v2"

    init() {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("poster_artwork", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func data(for url: URL, ttl: TimeInterval = PosterDiskCache.freshnessTTL) -> Data? {
        let file = fileURL(for: url)
        guard let attributes = try? fileManager.attributesOfItem(atPath: file.path),
              let modified = attributes[.modificationDate] as? Date,
              PosterDiskCacheFreshness.isFresh(modified: modified, now: Date(), ttl: ttl) else {
            return nil
        }
        return try? Data(contentsOf: file, options: .mappedIfSafe)
    }

    func store(_ data: Data, for url: URL) {
        try? data.write(to: fileURL(for: url), options: .atomic)

        bytesWrittenSinceTrim += data.count
        guard bytesWrittenSinceTrim >= trimInterval else { return }
        bytesWrittenSinceTrim = 0
        trim()
    }

    private func fileURL(for url: URL) -> URL {
        // A poster URL can carry query parameters and characters a file name
        // cannot, so hash it rather than sanitising it.
        let digest = SHA256.hash(data: Data("\(Self.storageVersion):\(url.absoluteString)".utf8))
        return directory.appendingPathComponent(digest.map { String(format: "%02x", $0) }.joined())
    }

    private func trim() {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys
        ) else {
            return
        }

        var entries: [(url: URL, modified: Date, size: Int)] = []
        var total = 0
        for file in files {
            guard let values = try? file.resourceValues(forKeys: Set(keys)),
                  let size = values.fileSize else { continue }
            entries.append((file, values.contentModificationDate ?? .distantPast, size))
            total += size
        }

        guard total > maximumBytes else { return }
        for entry in entries.sorted(by: { $0.modified < $1.modified }) {
            guard total > maximumBytes else { break }
            try? fileManager.removeItem(at: entry.url)
            total -= entry.size
        }
    }
}

/// Pure freshness rule for deterministic boundary tests.
enum PosterDiskCacheFreshness {
    static func isFresh(modified: Date, now: Date, ttl: TimeInterval) -> Bool {
        let age = now.timeIntervalSince(modified)
        return age >= 0 && age <= ttl
    }
}

private let posterURLSession: URLSession = {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 10
    config.timeoutIntervalForResource = 20
    config.httpMaximumConnectionsPerHost = 10
    config.urlCache = URLCache(
        memoryCapacity: 20 * 1024 * 1024,
        diskCapacity: 100 * 1024 * 1024,
        diskPath: "nuvio_poster_urlcache"
    )
    return URLSession(configuration: config)
}()

/// Matches what the Android loader gets from OkHttp's defaults: a 10s ceiling
/// instead of `URLSession`'s 60s, and a non-2xx response treated as a failure
/// instead of being handed to the decoder as if it were image bytes.
enum PosterArtworkCachePolicy {
    private static let volatileHosts = [
        "xperience-app.com", "btttr.cc", "ratingposterdb.com", "top-posters.com",
        "easyratingsdb.com", "extendedratings.com", "postersplus.elfhosted.com"
    ]

    /// Volatile hosts render posters on demand (rating overlays), so their bytes
    /// are revalidated on a short schedule rather than never cached at all.
    static let volatileFreshnessTTL: TimeInterval = 30 * 60

    static func isVolatile(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return volatileHosts.contains { host == $0 || host.hasSuffix(".\($0)") }
    }

    static func freshnessTTL(for url: URL, defaultTTL: TimeInterval) -> TimeInterval {
        isVolatile(url) ? volatileFreshnessTTL : defaultTTL
    }
}

private func downloadPosterData(url: URL, revalidate: Bool = false) async -> Data? {
    var request = URLRequest(url: url)
    request.timeoutInterval = 10
    if revalidate { request.cachePolicy = .reloadIgnoringLocalCacheData }

    guard let (data, response) = try? await posterURLSession.data(for: request) else {
        return nil
    }
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
        return nil
    }
    return data.isEmpty ? nil : data
}

private func downsamplePosterImage(data: Data, maxPixelSize: Int) -> UIImage? {
    let sourceOptions: [CFString: Any] = [
        kCGImageSourceShouldCache: false
    ]
    guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
        return UIImage(data: data)
    }

    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
    ]

    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
        return UIImage(data: data)
    }
    return UIImage(cgImage: cgImage)
}

private extension UIImage {
    var decodedByteCost: Int {
        guard let cgImage else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
    }
}
#endif

/// Deduplicates full-series metadata requests made by catalog badges. Catalog
/// previews usually omit `videos`, so completion cannot be decided until the
/// episode guide is available. Only series with watched episode rows reach this
/// cache, avoiding a request for every untouched poster on screen.
@MainActor
private final class CatalogWatchedMetadataCache {
    static let shared = CatalogWatchedMetadataCache()

    private let repository = CinemetaCatalogRepository()
    private var metadataByKey: [String: NuvioMeta] = [:]
    private var inFlightByKey: [String: Task<NuvioMeta?, Never>] = [:]
    private var decisionsByKey: [String: Bool] = [:]

    init() {
        NotificationCenter.default.addObserver(
            forName: WatchedStore.changedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.decisionsByKey.removeAll()
            }
        }
    }

    func cachedDecision(for key: String) -> Bool? {
        decisionsByKey[key]
    }

    func setDecision(_ isWatched: Bool, for key: String) {
        decisionsByKey[key] = isWatched
    }

    func fullMetadata(metaId: String, type: String, preview: NuvioMeta?) async -> NuvioMeta? {
        let profile = WatchedStore.activeProfileId ?? "default"
        let key = "\(profile)\u{1f}\(type.lowercased())\u{1f}\(metaId.lowercased())"
        if let cached = metadataByKey[key] { return cached }
        if let inFlight = inFlightByKey[key] { return await inFlight.value }

        let task: Task<NuvioMeta?, Never> = Task(priority: .utility) {
            // Reuses memory/disk cached metadata instead of forcing full network downloads
            if let cached = try? await repository.getMetadata(id: metaId, type: type) {
                return cached
            }
            // Keep an already supplied guide as a useful offline fallback.
            return preview
        }
        inFlightByKey[key] = task
        let resolved = await task.value
        inFlightByKey[key] = nil
        if let resolved { metadataByKey[key] = resolved }
        return resolved
    }
}

struct WatchedCheckmarkIcon: View {
    var size: CGFloat = 38

    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: size * 0.48, weight: .bold))
            .foregroundColor(.white)
            .frame(width: size, height: size)
            .background(
                Circle()
                    .fill(Color(red: 0.10, green: 0.68, blue: 0.34))
            )
            .overlay(
                Circle()
                    .stroke(Color.white.opacity(0.45), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
            .padding(12)
    }
}

struct WatchedCheckmarkBadge: View {
    let metaId: String
    let type: String
    let meta: NuvioMeta?
    var size: CGFloat = 38

    @State private var isWatched = false
    @State private var refreshVersion = 0
    @Environment(\.isEnabled) private var isEnabled

    init(metaId: String, type: String, size: CGFloat = 38) {
        self.metaId = metaId
        self.type = type
        self.meta = nil
        self.size = size
    }

    init(meta: NuvioMeta, size: CGFloat = 38) {
        self.metaId = meta.id
        self.type = meta.type
        self.meta = meta
        self.size = size
    }

    var body: some View {
        // Keep the badge mounted while unwatched. Search remains alive behind
        // the Details overlay, and an EmptyView branch can miss the store
        // notification that should reveal the checkmark when Details closes.
        WatchedCheckmarkIcon(size: size)
            .opacity(isWatched ? 1 : 0)
            .accessibilityHidden(!isWatched)
            .task(id: refreshTaskIdentity) {
                await refresh()
            }
            .onReceive(NotificationCenter.default.publisher(for: WatchedStore.changedNotification)) { _ in
                // Re-key the SwiftUI task instead of starting an untracked Task.
                // Store sync and view recreation can otherwise overlap refreshes,
                // allowing an older result to overwrite a newer watched state.
                refreshVersion &+= 1
            }
    }

    /// Re-runs the lookup whenever the card's identity changes. Search results
    /// arrive IMDb-only and gain TMDB aliases when their background `/meta`
    /// enrichment lands — without those aliases in the identity, the badge
    /// would never recalculate and would miss a TMDB-first watched record.
    private var refreshIdentity: String {
        let imdb = meta?.imdbId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let tmdb = meta?.tmdbId.map(String.init) ?? ""
        return "\(WatchedStore.activeProfileId ?? "default")\u{1f}\(type.lowercased())\u{1f}\(metaId)\u{1f}\(imdb)\u{1f}\(tmdb)"
    }

    // `isEnabled` is deliberately not part of the identity. A row's `.disabled`
    // flips for every card in it on each vertical move, which re-armed every
    // badge's lookup; the store notification above already covers a watched
    // change that lands while the card is disabled behind an overlay.
    private var refreshTaskIdentity: String {
        "\(refreshIdentity)\u{1f}\(refreshVersion)"
    }

    @MainActor
    private func refresh() async {
        if let cached = CatalogWatchedMetadataCache.shared.cachedDecision(for: refreshIdentity) {
            isWatched = cached
            return
        }

        let snapshot = WatchedStore.currentSnapshot()
        let isSeries = ["series", "tv", "show", "tvshow"].contains(type.lowercased())
        guard isSeries else {
            let result = meta.map { snapshot.contains(meta: $0) }
                ?? snapshot.contains(metaId: metaId, type: type)
            isWatched = result
            CatalogWatchedMetadataCache.shared.setDecision(result, for: refreshIdentity)
            return
        }

        if meta.map({ snapshot.containsCatalogTitle(meta: $0) })
            ?? snapshot.contains(metaId: metaId, type: type) {
            isWatched = true
            CatalogWatchedMetadataCache.shared.setDecision(true, for: refreshIdentity)
            return
        }

        // No watched episodes means this cannot be a completed series, and it
        // also lets untouched catalog cards avoid a metadata network request.
        let previewWatchedKeys = meta.map { snapshot.catalogWatchedEpisodeKeys(meta: $0) }
            ?? snapshot.watchedEpisodeKeys(metaId: metaId)
        guard !previewWatchedKeys.isEmpty else {
            isWatched = false
            CatalogWatchedMetadataCache.shared.setDecision(false, for: refreshIdentity)
            return
        }

        // Search enrichment can carry the complete episode guide on the card.
        // Resolve it synchronously from that already-loaded data instead of
        // starting a second /meta request for every search result.
        if let videos = meta?.videos,
           CatalogWatchedPolicy.hasWatchedAllAiredEpisodes(
               videos: videos,
               watchedEpisodeKeys: previewWatchedKeys
           ) {
            isWatched = true
            CatalogWatchedMetadataCache.shared.setDecision(true, for: refreshIdentity)
            return
        }

        guard let fullMeta = await CatalogWatchedMetadataCache.shared.fullMetadata(
            metaId: metaId,
            type: type,
            preview: meta
        ), !Task.isCancelled else { return }

        let freshSnapshot = WatchedStore.currentSnapshot()
        let resolved = freshSnapshot.containsCatalogTitle(meta: fullMeta)
            || CatalogWatchedPolicy.hasWatchedAllAiredEpisodes(
                videos: fullMeta.videos,
                watchedEpisodeKeys: freshSnapshot.catalogWatchedEpisodeKeys(meta: fullMeta)
            )
        isWatched = resolved
        CatalogWatchedMetadataCache.shared.setDecision(resolved, for: refreshIdentity)
    }
}

/// Custom button style for poster cards
struct PosterCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            #if os(tvOS)
            .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
            #else
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            #endif
            .animation(.easeInOut(duration: 0.2), value: configuration.isPressed)
    }
}

#if os(tvOS)
private extension View {
    @ViewBuilder
    func nuvioFocusEffectDisabledIfAvailable() -> some View {
        if #available(tvOS 17.0, *) {
            focusEffectDisabled()
        } else {
            self
        }
    }
}

/// Binds a view's focus to a shared `FocusState<String?>` (no-op when nil),
/// so a parent can track/restore which card is focused.
struct ExternalFocusBinding: ViewModifier {
    let binding: FocusState<String?>.Binding?
    let id: String

    func body(content: Content) -> some View {
        if let binding {
            content.focused(binding, equals: id)
        } else {
            content
        }
    }
}

struct DefaultFocusBindingModifier<V: Hashable>: ViewModifier {
    let binding: FocusState<V?>.Binding?
    let value: V?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let binding, let value {
            if #available(tvOS 17.0, *) {
                content.defaultFocus(binding, value)
            } else {
                content
            }
        } else {
            content
        }
    }
}

extension View {
    /// `.defaultFocus` guarded for tvOS 17+ (no-op below). Lets a focus scope
    /// restore to a specific value when it regains focus (e.g. from the menu,
    /// or returning to a sidebar's selected item).
    @ViewBuilder
    func defaultFocusIfAvailable<V: Hashable>(_ binding: FocusState<V>.Binding, _ value: V) -> some View {
        if #available(tvOS 17.0, *) {
            self.defaultFocus(binding, value)
        } else {
            self
        }
    }

    @ViewBuilder
    func defaultFocusIfAvailable<V: Hashable>(_ binding: FocusState<V?>.Binding?, _ value: V?) -> some View {
        self.modifier(DefaultFocusBindingModifier(binding: binding, value: value))
    }
}
#endif

// MARK: - Preview

#if DEBUG
struct PosterCard_Previews: PreviewProvider {
    static var previews: some View {
        let sampleMeta = NuvioMeta(
            id: "1",
            name: "Sample Movie",
            description: "A sample movie description",
            posterUrl: "https://via.placeholder.com/300x450",
            backgroundUrl: nil,
            logoUrl: nil,
            imdbId: "tt1234567",
            tmdbId: nil,
            type: "movie",
            year: 2024,
            genres: ["Action", "Drama"],
            rating: 8.5,
            releaseInfo: nil,
            runtime: "120 min",
            cast: nil,
            director: nil,
            writer: nil,
            certification: nil,
            country: nil,
            released: nil
        )

        PosterCard(meta: sampleMeta) {
            print("Tapped!")
        }
        .previewLayout(.sizeThatFits)
        .padding()
        .background(Color.black)
    }
}
#endif

// MARK: - Title actions native context menu

/// Native tvOS/iOS context menu for titles (Go to details / Add to library / Mark as watched / Continue watching actions)
struct TitleActionsMenuContent: View {
    let meta: NuvioMeta
    var onOpenDetails: (() -> Void)? = nil
    var continueProgress: Double? = nil
    var continueIsUpNext: Bool = false
    var onPlayManually: (() -> Void)? = nil
    var onStartFromBeginning: (() -> Void)? = nil
    var onRemoveFromContinueWatching: (() -> Void)? = nil
    var body: some View {
        contextMenuContent
    }

    @ViewBuilder
    private var contextMenuContent: some View {
        if continueProgress != nil || continueIsUpNext {
            Button {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
                    onOpenDetails?()
                }
            } label: {
                Label(L10n.string("action_go_to_details", fallback: "Go to details"), systemImage: "info.circle")
            }

            if let onPlayManually {
                Button {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
                        onPlayManually()
                    }
                } label: {
                    Label(L10n.string("action_play_manually", fallback: "Play manually"), systemImage: "play.fill")
                }
            }

            if let onStartFromBeginning, !continueIsUpNext {
                Button {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
                        onStartFromBeginning()
                    }
                } label: {
                    Label(L10n.string("action_start_from_beginning", fallback: "Start from beginning"), systemImage: "arrow.counterclockwise")
                }
            }

            if let onRemoveFromContinueWatching {
                Button(role: .destructive) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
                        onRemoveFromContinueWatching()
                    }
                } label: {
                    Label(L10n.string("action_remove", fallback: "Remove"), systemImage: "trash")
                }
            }
        } else {
            let inLibrary = LibraryStore.contains(metaId: meta.id, type: meta.type)
            let isItemWatched = WatchedStore.contains(meta: meta)

            Button {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
                    onOpenDetails?()
                }
            } label: {
                Label(L10n.string("action_go_to_details", fallback: "Go to details"), systemImage: "info.circle")
            }

            Button {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
                    toggleLibrary(currentlyInLibrary: inLibrary)
                }
            } label: {
                Label(
                    inLibrary
                        ? L10n.string("action_remove_from_library", fallback: "Remove from library")
                        : L10n.string("action_add_to_library", fallback: "Add to library"),
                    systemImage: inLibrary ? "checkmark" : "plus"
                )
            }

            Button {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
                    toggleWatched()
                }
            } label: {
                Label(
                    isItemWatched
                        ? L10n.string("details_mark_as_unwatched", fallback: "Mark as unwatched")
                        : L10n.string("details_mark_as_watched", fallback: "Mark as watched"),
                    systemImage: isItemWatched ? "eye.slash" : "eye"
                )
            }
        }
    }

    private func toggleLibrary(currentlyInLibrary: Bool) {
        guard TraktSettingsStore.librarySourceMode != .local else {
            _ = LibraryStore.toggle(meta: meta)
            return
        }

        guard SelectedLibraryService.isSelectedAndAuthenticated else { return }

        let desiredMembership = !currentlyInLibrary
        Task {
            _ = await SelectedLibraryService.setWatchlist(
                meta,
                isInWatchlist: desiredMembership
            )
        }
    }

    private func toggleWatched() {
        let isSeries = ["series", "tv", "show", "tvshow"].contains(meta.type.lowercased())
        guard isSeries else {
            _ = WatchedStore.toggle(meta: meta)
            return
        }

        Task {
            let fullMeta = await CatalogWatchedMetadataCache.shared.fullMetadata(
                metaId: meta.id,
                type: meta.type,
                preview: meta
            ) ?? meta
            guard !Task.isCancelled else { return }
            _ = WatchedStore.toggle(meta: fullMeta)
        }
    }
}

struct TitleActionsContextMenu: ViewModifier {
    let meta: NuvioMeta
    var onOpenDetails: (() -> Void)? = nil
    var continueProgress: Double? = nil
    var continueIsUpNext: Bool = false
    var onPlayManually: (() -> Void)? = nil
    var onStartFromBeginning: (() -> Void)? = nil
    var onRemoveFromContinueWatching: (() -> Void)? = nil

    func body(content: Content) -> some View {
        content
            .contextMenu {
                TitleActionsMenuContent(
                    meta: meta,
                    onOpenDetails: onOpenDetails,
                    continueProgress: continueProgress,
                    continueIsUpNext: continueIsUpNext,
                    onPlayManually: onPlayManually,
                    onStartFromBeginning: onStartFromBeginning,
                    onRemoveFromContinueWatching: onRemoveFromContinueWatching
                )
            }
    }
}

extension View {
    func titleActionsContextMenu(
        meta: NuvioMeta,
        onOpenDetails: (() -> Void)? = nil,
        continueProgress: Double? = nil,
        continueIsUpNext: Bool = false,
        onPlayManually: (() -> Void)? = nil,
        onStartFromBeginning: (() -> Void)? = nil,
        onRemoveFromContinueWatching: (() -> Void)? = nil
    ) -> some View {
        modifier(
            TitleActionsContextMenu(
                meta: meta,
                onOpenDetails: onOpenDetails,
                continueProgress: continueProgress,
                continueIsUpNext: continueIsUpNext,
                onPlayManually: onPlayManually,
                onStartFromBeginning: onStartFromBeginning,
                onRemoveFromContinueWatching: onRemoveFromContinueWatching
            )
        )
    }
}
