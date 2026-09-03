import SwiftUI
import Foundation
import UIKit
import ImageIO
import OSLog

/// Full-screen backdrop that crossfades between images without flashing the
/// placeholder colour. `AsyncImage(url:).id(url)` tears the current image down
/// the instant the URL changes and shows its placeholder until the next image
/// decodes — which is the "blink" seen when focus moves slowly poster-by-poster.
/// This keeps the current image on screen, decodes the next one in the
/// background, and only then fades it in. Rapid URL changes (fast scrolling)
/// cancel the in-flight load via `.task(id:)`, so the visible image never
/// changes mid-scroll.
///
/// `alignment` controls which edge of a taller/wider image stays visible when
/// aspect-filled (Android Modern Home uses top-trailing for hero art so faces
/// and subjects aren't cropped off the top).
struct CrossfadingBackdrop: View {
    let url: String?
    let placeholder: Color
    /// Crop anchor for `.fill`. Collection folder heroes use `.topTrailing`
    /// (Android `Alignment.TopEnd`); title posters keep center.
    var alignment: Alignment = .center

    @State private var image: UIImage?
    @State private var loadedURL: String?
    @State private var outgoingImage: UIImage?
    @State private var outgoingOpacity = 0.0
    @State private var imageOpacity = 1.0

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                placeholder
                if let outgoingImage {
                    backdropImage(outgoingImage, size: proxy.size)
                        .opacity(outgoingOpacity)
                }
                if let image {
                    backdropImage(image, size: proxy.size)
                        .opacity(imageOpacity)
                        .id(loadedURL)
                }
            }
            // Portrait poster fallbacks must be cropped inside the screen, not
            // enlarge the root Home layout and let tvOS pan the hero offscreen.
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .task(id: url) {
            guard let url, url != loadedURL, let imageURL = URL(string: url) else {
                outgoingImage = nil
                outgoingOpacity = 0
                return
            }
            guard let loaded = await BackdropImageCache.shared.image(for: imageURL) else { return }
            // Some catalog add-ons (including BetterPosters) only provide a
            // poster URL. PosterCard uses that same image for its landscape
            // state, so allow the full-screen aspect-fill to use it as well.
            // `.task(id:)` cancels when `url` changes, so reaching here means this
            // URL is still the focused one. Cancellation leaves the old image up.
            guard !Task.isCancelled else { return }
            let previousImage = image
            if previousImage != nil {
                outgoingImage = previousImage
                outgoingOpacity = 1
            }
            image = loaded
            loadedURL = url
            imageOpacity = previousImage == nil ? 1 : 0

            withAnimation(.easeInOut(duration: 0.30)) {
                imageOpacity = 1
                outgoingOpacity = 0
            }

            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, loadedURL == url else { return }
            outgoingImage = nil
            outgoingOpacity = 0
        }
    }

    @ViewBuilder
    private func backdropImage(_ uiImage: UIImage, size: CGSize) -> some View {
        Image(uiImage: uiImage)
            .resizable()
            .aspectRatio(contentMode: .fill)
            // Alignment anchors the crop when the filled image overflows the
            // screen — critical for tall hero art (collection folder backdrops).
            .frame(width: size.width, height: size.height, alignment: alignment)
            .clipped()
    }
}

extension CrossfadingBackdrop: Equatable {
    static func == (lhs: CrossfadingBackdrop, rhs: CrossfadingBackdrop) -> Bool {
        lhs.url == rhs.url
            && lhs.placeholder == rhs.placeholder
            && lhs.alignment == rhs.alignment
    }
}

/// Hero header while a collection folder card is focused.
/// Full-screen backdrop is driven by `homeBackdropURL` (folder hero backdrop).
/// This view only draws the title area: optional title logo, else emoji + name.
///
/// Unlike `TVHeroView` (title + meta + multi-line description that fills the
/// block), folder heroes are a single short line. They must sit at the bottom
/// of the hero frame — where a poster description's last line ends — matching
/// Android Modern Home. A large top padding (copied from poster heroes) was
/// making this line sit too high.
struct TVCollectionFolderHeroView: View {
    let folder: TVCollectionFolderItem
    @AppStorage(SettingsKey.homeLayout) private var homeLayout = "Modern"

    private var emoji: String? {
        let raw = folder.coverEmoji?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? nil : raw
    }

    private var displayTitle: String {
        folder.title.isEmpty ? "Folder" : folder.title
    }

    private var heroHeight: CGFloat {
        homeLayout == "Compact" ? 390 : 500
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Push the title line to the bottom of the fixed hero frame.
            Spacer(minLength: 0)

            Group {
                if let logoURL = folder.preferredTitleLogoURLString {
                    CachedHeroLogo(url: logoURL, title: displayTitle)
                } else {
                    HStack(alignment: .center, spacing: 18) {
                        if let emoji {
                            Text(emoji)
                                .font(.system(size: 52))
                        } else {
                            Image(systemName: "movieclapper")
                                .font(.system(size: 44, weight: .semibold))
                                .foregroundColor(.white.opacity(0.92))
                        }

                        Text(displayTitle)
                            .font(.custom("Inter-Bold", size: 48))
                            .foregroundColor(.white)
                            .lineLimit(2)
                            .minimumScaleFactor(0.7)
                    }
                }
            }
            .padding(.leading, TVLayout.rowLeading)
            // Match the gap under poster-hero descriptions so the first catalog
            // title sits the same distance below (Android-style).
            .padding(.bottom, TVHomeLayout.heroBottomPadding)
        }
        .foregroundColor(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: heroHeight, alignment: .bottomLeading)
    }
}

struct TVHeroView: View {
    let meta: NuvioMeta
    /// Continue Watching entry for this title, when one exists. Lets the hero
    /// say which episode is in progress, how much is left, and show the
    /// episode's own overview instead of the series blurb.
    var continueItem: ContinueWatchingItem? = nil
    let onSelect: () -> Void
    @AppStorage(SettingsKey.homeLayout) private var homeLayout = "Modern"

    var body: some View {
        let _ = TVHomeDebugTrace.log("hero.render meta=\(meta.id)")
        VStack(alignment: .leading, spacing: 18) {
            if let logoUrl = meta.logoUrl {
                CachedHeroLogo(url: logoUrl, title: meta.name)
            } else {
                Text(meta.name)
                    .font(.custom("Inter-Bold", size: 54))
                    .lineLimit(2)
                    .foregroundColor(.white)
            }

            TVHeroMetaLine(meta: meta, episodeLine: episodeLine)

            if let continueItem {
                Text(continueItem.isUpNextEntry ? continueItem.upNextBadgeText : continueItem.remainingText.uppercased())
                    .font(.custom("Inter-SemiBold", size: 22))
                    .foregroundColor(.white.opacity(0.66))
            }

            if let description = heroDescription {
                Text(description.wrappedEveryNWords(9))
                    .font(.custom("Inter-Regular", size: 24))
                    .foregroundColor(.white)
                    .lineSpacing(3)
                    .lineLimit(4)
                    .frame(maxWidth: 900, alignment: .leading)
                    .padding(.top, 4)
            }
        }
        .foregroundColor(.white)
        .padding(.leading, TVLayout.rowLeading)
        .padding(.top, homeLayout == "Compact" ? 82 : 140)
        .padding(.bottom, TVHomeLayout.heroBottomPadding)
        .frame(height: homeLayout == "Compact" ? 390 : 500, alignment: .bottomLeading)
    }

    /// "S1 E3 · Title" for the episode in progress; nil for movies or when the
    /// entry predates episode tracking.
    private var episodeLine: String? {
        continueItem?.episodeDisplayLine
    }

    /// Prefer the in-progress episode's overview; fall back to the series/movie
    /// description.
    private var heroDescription: String? {
        if let overview = continueItem?.episodeOverview, !overview.isEmpty {
            return overview
        }
        return meta.description
    }
}

extension TVHeroView: Equatable {
    static func == (lhs: TVHeroView, rhs: TVHeroView) -> Bool {
        lhs.meta.id == rhs.meta.id
            && lhs.meta.name == rhs.meta.name
            && lhs.meta.logoUrl == rhs.meta.logoUrl
            && lhs.meta.description == rhs.meta.description
            && lhs.meta.year == rhs.meta.year
            && lhs.meta.rating == rhs.meta.rating
            && lhs.meta.runtime == rhs.meta.runtime
            && lhs.meta.genres == rhs.meta.genres
            && lhs.continueItem?.meta.id == rhs.continueItem?.meta.id
            && lhs.continueItem?.episodeLabel == rhs.continueItem?.episodeLabel
            && lhs.continueItem?.remainingText == rhs.continueItem?.remainingText
    }
}

/// Grid View's featured carousel, matching Android TV's `HeroCarousel`: a
/// large near-full-screen banner, local backdrop/gradients, remote paging, Select to
/// open details, and auto-advance only while the hero is not focused.
struct TVGridHeroSlideshowView: View {
    let items: [NuvioMeta]
    @Binding var selectedIndex: Int
    let shouldRequestInitialFocus: Bool
    let onInitialFocusRequested: () -> Void
    /// Safe-area inset the artwork bleeds past on each side. Only the backdrop
    /// widens — the hero's frame, its text, and the focus geometry stay inside
    /// the safe area.
    var backdropBleed: CGFloat = 0
    var onFocusChange: ((Bool) -> Void)? = nil
    let onSelect: (NuvioMeta) -> Void

    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue
    @FocusState private var isFocused: Bool

    private var index: Int {
        guard !items.isEmpty else { return 0 }
        return min(max(selectedIndex, 0), items.count - 1)
    }

    private var activeItem: NuvioMeta? { items.indices.contains(index) ? items[index] : nil }

    /// Backdrop + scrims. Drawn as a `background` so it can be widened past the
    /// hero without changing the hero's own frame — the focus engine routes a
    /// left press off that frame, and a hero reaching x=0 sits under the
    /// collapsed sidebar.
    @ViewBuilder
    private func artLayer(_ item: NuvioMeta) -> some View {
        let background = Color.nuvioBackground(amoled: amoled, body: bodyColor)

        ZStack {
            CrossfadingBackdrop(
                url: item.backgroundUrl ?? item.posterUrl,
                placeholder: background,
                alignment: .top
            )

            LinearGradient(
                stops: [
                    .init(color: background.opacity(0.98), location: 0),
                    .init(color: background.opacity(0.88), location: 0.16),
                    .init(color: background.opacity(0.56), location: 0.34),
                    .init(color: background.opacity(0.20), location: 0.56),
                    .init(color: .clear, location: 0.72)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.30),
                    .init(color: background.opacity(0.50), location: 0.60),
                    .init(color: background.opacity(0.85), location: 0.80),
                    .init(color: background, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .padding(.horizontal, -backdropBleed)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if let activeItem {
                gridHeroContent(activeItem)
                    .id(activeItem.id)
                    .transition(.opacity)
            }

            if items.count > 1 {
                HStack(spacing: 12) {
                    ForEach(items.indices, id: \.self) { dotIndex in
                        Capsule()
                            .fill(indicatorColor(for: dotIndex))
                            .frame(
                                width: dotIndex == index ? (isFocused ? 48 : 36) : 18,
                                height: isFocused && dotIndex == index ? 6 : 4
                            )
                    }
                }
                .animation(.easeInOut(duration: 0.30), value: index)
                .padding(.bottom, 24)
            }
        }
        .frame(maxWidth: .infinity)
        // Match the tall Android Grid hero. Besides giving the design the same
        // visual weight, this keeps 16:9 artwork from being vertically cropped
        // into an ultra-wide 5:1 strip where the subject disappears.
        .frame(height: 820)
        .clipped()
        // After `clipped()`, so the widened artwork isn't trimmed back to the
        // hero's frame.
        .background {
            if let activeItem { artLayer(activeItem) }
        }
        .contentShape(Rectangle())
        .focusable(true)
        .focusEffectDisabledIfAvailable()
        .focused($isFocused)
        .onAppear {
            guard shouldRequestInitialFocus else { return }
            onInitialFocusRequested()
            DispatchQueue.main.async { isFocused = true }
        }
        .onTapGesture {
            if let activeItem { onSelect(activeItem) }
        }
        .onMoveCommand { direction in
            switch direction {
            case .left where index > 0:
                setIndex(index - 1)
                // The sidebar sits to our left and the focus engine acts on this
                // same press, so paging back would also open the menu. Claim
                // focus again to keep the press here. At index 0 it is left
                // alone, so the first slide still exits to the menu.
                isFocused = true
                DispatchQueue.main.async { isFocused = true }
            case .right where index < items.count - 1:
                setIndex(index + 1)
            default:
                break
            }
        }
        .onChange(of: isFocused) { _, focused in
            onFocusChange?(focused)
        }
        .task(id: "\(items.map(\.id).joined(separator: "|"))|\(isFocused)") {
            guard items.count > 1 else { return }
            // Android lets the initial GPU/image work settle for 20 seconds,
            // then checks for the next unfocused advance every 10 seconds.
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled else { return }
                if !isFocused { setIndex((index + 1) % items.count) }
            }
        }
        .onChange(of: items.count) { _, count in
            if count == 0 { selectedIndex = 0 }
            else if selectedIndex >= count { selectedIndex = count - 1 }
        }
    }

    @ViewBuilder
    private func gridHeroContent(_ item: NuvioMeta) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let logoURL = item.logoUrl, !logoURL.isEmpty {
                CachedHeroLogo(url: logoURL, title: item.name)
                    .frame(maxHeight: 88, alignment: .leading)
            } else {
                Text(item.name)
                    .font(.custom("Inter-Bold", size: 46))
                    .foregroundColor(.white)
                    .lineLimit(2)
            }

            HStack(spacing: 18) {
                if let rating = item.rating {
                    Text(String(format: "IMDb %.1f", rating))
                }
                if let year = item.year {
                    Text(String(year))
                }
            }
            .font(.custom("Inter-SemiBold", size: 21))
            .foregroundColor(.white.opacity(0.80))

            if let genres = item.genres, !genres.isEmpty {
                HStack(spacing: 10) {
                    ForEach(Array(genres.prefix(3)), id: \.self) { genre in
                        Text(genre)
                            .font(.custom("Inter-Medium", size: 18))
                            .foregroundColor(.white.opacity(0.72))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }

            if let description = item.description, !description.isEmpty {
                Text(description)
                    .font(.custom("Inter-Regular", size: 21))
                    .foregroundColor(.white.opacity(0.72))
                    .lineLimit(2)
                    .lineSpacing(2)
            }
        }
        .frame(maxWidth: 860, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(.leading, TVLayout.rowLeading)
        .padding(.trailing, TVLayout.rowLeading)
        .padding(.bottom, 58)
    }

    private func indicatorColor(for dotIndex: Int) -> Color {
        if dotIndex == index { return AppFocusOutline.color }
        return isFocused ? AppFocusOutline.color.opacity(0.40) : Color.white.opacity(0.30)
    }

    private func setIndex(_ newIndex: Int) {
        withAnimation(.easeInOut(duration: 0.30)) {
            selectedIndex = newIndex
        }
    }
}

private struct CachedHeroLogo: View {
    let url: String
    let title: String

    @State private var image: UIImage?
    @State private var loadedURL: String?
    @State private var outgoingImage: UIImage?
    @State private var outgoingOpacity = 0.0
    @State private var imageOpacity = 1.0

    private var showsLogoImage: Bool {
        image != nil || outgoingImage != nil
    }

    var body: some View {
        // Size to the logo's intrinsic aspect (capped at 520×136) instead of a
        // fixed 114pt slot. A short/wide wordmark centered in a tall frame left
        // a dead band under the title before the first catalog row; text
        // fallback must not reserve that slot either.
        Group {
            if showsLogoImage {
                ZStack(alignment: .bottomLeading) {
                    if let outgoingImage {
                        Image(uiImage: outgoingImage)
                            .resizable()
                            .scaledToFit()
                            .opacity(outgoingOpacity)
                    }
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .opacity(imageOpacity)
                            .id(loadedURL)
                    }
                }
                .frame(maxWidth: 520, maxHeight: 136, alignment: .bottomLeading)
            } else {
                Text(title)
                    .font(.custom("Inter-Bold", size: 54))
                    .lineLimit(2)
                    .foregroundColor(.white)
            }
        }
        .task(id: url) {
            guard url != loadedURL, let imageURL = URL(string: url) else {
                outgoingImage = nil
                outgoingOpacity = 0
                return
            }
            guard let loaded = await BackdropImageCache.shared.image(for: imageURL) else {
                guard !Task.isCancelled else { return }
                image = nil
                loadedURL = nil
                outgoingImage = nil
                outgoingOpacity = 0
                return
            }
            guard !Task.isCancelled else { return }
            let previousImage = image
            if previousImage != nil {
                outgoingImage = previousImage
                outgoingOpacity = 1
            }
            image = loaded
            loadedURL = url
            imageOpacity = previousImage == nil ? 1 : 0

            withAnimation(.easeInOut(duration: 0.14)) {
                imageOpacity = 1
                outgoingOpacity = 0
            }

            try? await Task.sleep(nanoseconds: 140_000_000)
            guard !Task.isCancelled, loadedURL == url else { return }
            outgoingImage = nil
            outgoingOpacity = 0
        }
    }
}

private struct TVHeroMetaLine: View {
    let meta: NuvioMeta
    /// "S1 E3 · Title" for a series in progress; replaces the type/runtime
    /// items so the line reads "S1 E3 · Title • Crime • 2026–".
    var episodeLine: String? = nil
    @AppStorage(SettingsKey.showFullDates) private var showFullDates = true

    var body: some View {
        let values = [
            episodeLine ?? meta.type.capitalized,
            meta.genres?.first,
            episodeLine == nil ? formattedRuntime : nil,
            episodeLine == nil ? releaseDate : (meta.releaseInfo ?? meta.year.map(String.init))
        ].compactMap { $0 }.filter { !$0.isEmpty }

        let badge = meta.statusBadgeLabel
        let rating = meta.rating.map { String(format: "IMDb %.1f", $0) }
        // Movies have no status badge, so their rating would sit alone on the
        // second line; ride it on the primary line right after the date instead.
        let isMovie = !meta.isSeries
        let primaryValues = isMovie ? values + [rating].compactMap { $0 } : values
        let showSecondLine = !isMovie && (badge != nil || rating != nil)
        // An empty `Text("")` still consumes a full line height and, with the
        // hero VStack spacing, opens a dead gap between the title and the first
        // catalog row (e.g. "The Chi" → "gg"). Collapse entirely when blank.
        let hasPrimary = !primaryValues.isEmpty

        if hasPrimary || showSecondLine {
            VStack(alignment: .leading, spacing: 10) {
                if hasPrimary {
                    Text(primaryValues.joined(separator: "  •  "))
                        .font(.custom("Inter-SemiBold", size: 22))
                        .foregroundColor(.white.opacity(0.66))
                        .lineLimit(1)
                }

                // Second line, like the Android hero: "[ONGOING] • IMDb 7.4".
                if showSecondLine {
                    HStack(spacing: 14) {
                        if let badge {
                            Text(badge)
                                .font(.custom("Inter-SemiBold", size: 17))
                                .foregroundColor(.white.opacity(0.88))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .stroke(Color.white.opacity(0.45), lineWidth: 1.5)
                                )
                        }

                        if let rating {
                            Text(badge != nil ? "•  \(rating)" : rating)
                                .font(.custom("Inter-SemiBold", size: 22))
                                .foregroundColor(.white.opacity(0.66))
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
    }

    private var formattedRuntime: String? {
        NuvioRuntimeDisplay.formatted(meta.runtime)
    }

    private var releaseDate: String? {
        if showFullDates, let released = meta.released, !released.isEmpty {
            return NuvioDateDisplay.formattedDate(released)
        }
        return meta.year.map(String.init)
    }
}
