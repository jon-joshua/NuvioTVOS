import SwiftUI

// Screen-specific wrappers around `PosterTile`. Each one maps its own model
// onto the tile's parameters and draws nothing itself.

/// Discover grid: a poster with a "Genre  ·  ★ Rating" line over the art.
struct DiscoverCard: View {
    let meta: NuvioMeta
    var externalFocus: FocusState<String?>.Binding? = nil
    var onFocusChange: ((Bool) -> Void)? = nil
    let action: () -> Void

    var body: some View {
        PosterTile(
            meta: meta,
            size: CGSize(width: DiscoverGridMetrics.posterWidth, height: DiscoverGridMetrics.posterHeight),
            caption: PosterCaption(title: meta.name, subtitle: meta.year.map(String.init)),
            externalFocus: externalFocus,
            onFocusChange: onFocusChange,
            overlay: {
                if let line = PosterCaption.metaLine(genre: meta.genres?.first, rating: meta.rating) {
                    VStack {
                        Spacer()
                        LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                            .frame(height: 120)
                            .overlay(alignment: .bottomLeading) {
                                Text(line)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.95))
                                    .lineLimit(1)
                                    .padding(.horizontal, 12)
                                    .padding(.bottom, 10)
                            }
                    }
                }
            },
            action: action
        )
    }
}

/// Library grid.
struct LibraryItemButton: View {
    let item: StremioMeta
    var externalFocus: FocusState<String?>.Binding? = nil
    let action: () -> Void

    var body: some View {
        let meta = item.asNuvioMeta
        PosterTile(
            meta: meta,
            size: CGSize(width: LibraryGridMetrics.posterWidth, height: LibraryGridMetrics.posterHeight),
            caption: PosterCaption(
                title: item.name,
                subtitle: PosterCaption.subtitle(
                    typeLabel: typeLabel(for: item.contentType),
                    year: item.year.map(String.init),
                    rating: item.imdbRating.flatMap(Double.init)
                )
            ),
            externalFocus: externalFocus,
            action: action
        )
    }
}

/// "Series" / "Movie" for a caption, localised.
func typeLabel(for type: String) -> String {
    type == "series"
        ? L10n.string("type_series", fallback: "Series")
        : L10n.string("type_movie", fallback: "Movie")
}

extension PosterCaption {
    /// The standard "Type  ·  Year  ·  ★ Rating" caption for a catalog title.
    static func standard(for meta: NuvioMeta) -> PosterCaption {
        PosterCaption(
            title: meta.name,
            subtitle: subtitle(typeLabel: typeLabel(for: meta.type), year: meta.year.map(String.init), rating: meta.rating)
        )
    }
}
