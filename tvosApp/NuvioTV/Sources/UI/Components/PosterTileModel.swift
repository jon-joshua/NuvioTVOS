import Foundation

// Pure values a poster tile renders from. No SwiftUI here so every rule that
// decides what a tile shows is a plain function with a unit test.

/// Caption drawn under a poster tile.
struct PosterCaption: Equatable {
    var title: String
    var subtitle: String?

    /// "Series  ·  2019  ·  ★ 7.8". Missing parts are omitted; a rating of
    /// zero or less is treated as missing.
    static func subtitle(typeLabel: String, year: String?, rating: Double?) -> String {
        var parts = [typeLabel]
        if let year, !year.isEmpty { parts.append(year) }
        if let rating, rating > 0 { parts.append(String(format: "★ %.1f", rating)) }
        return parts.joined(separator: "  ·  ")
    }

    /// "Drama  ·  ★ 7.8", the line Discover draws over the artwork. Nil when
    /// there is nothing to say.
    static func metaLine(genre: String?, rating: Double?) -> String? {
        var parts: [String] = []
        if let genre, !genre.isEmpty { parts.append(genre) }
        if let rating, rating > 0 { parts.append(String(format: "★ %.1f", rating)) }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }
}

enum PosterProgress {
    /// Nil stays nil; anything else lands in 0...1.
    static func clamped(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(max(value, 0), 1)
    }

    /// Width of the filled capsule. Never thinner than its own height, so a
    /// title that has barely started still shows a dot rather than nothing.
    static func fillWidth(track: CGFloat, progress: Double, minimum: CGFloat = 8) -> CGFloat {
        max(minimum, track * CGFloat(progress))
    }
}

/// Fill behind the Continue Watching chip, resolved from the chip text so the
/// mapping is testable without a Color.
enum PosterBadgeTint: Equatable {
    case neutral, newSeason, newEpisode, airingToday, upcoming
}

/// The chip in the top-leading corner of a Continue Watching card.
struct PosterBadge: Equatable {
    var text: String
    var tint: PosterBadgeTint

    /// Up Next entries show their badge text ("Next Up" by default) on a tint
    /// picked from that text. Progress entries show "<episode> • <remaining>"
    /// and need a remaining-time text to show anything at all.
    static func make(isUpNext: Bool, upNextText: String?, episodeText: String?, remainingText: String?) -> PosterBadge? {
        if isUpNext {
            let text = upNextText ?? "Next Up"
            return PosterBadge(text: text, tint: tint(for: text))
        }
        guard let remainingText, !remainingText.isEmpty else { return nil }
        if let episodeText, !episodeText.isEmpty {
            return PosterBadge(text: "\(episodeText) • \(remainingText)", tint: .neutral)
        }
        return PosterBadge(text: remainingText, tint: .neutral)
    }

    private static func tint(for text: String) -> PosterBadgeTint {
        let badge = text.uppercased()
        if badge == "NEW SEASON" { return .newSeason }
        if badge == "NEW EPISODE" { return .newEpisode }
        if badge == "AIRING TODAY" { return .airingToday }
        if badge.hasPrefix("AIRS IN") || badge == "COMING SOON" { return .upcoming }
        return .neutral
    }
}

enum PosterArtworkChoice {
    /// Landscape art for an expanded card: the episode still for an episode
    /// entry, else the backdrop, else the poster. Empty strings count as missing.
    static func landscapeURL(episodeText: String?, episodeArtworkURL: String?,
                             backgroundURL: String?, posterURL: String?) -> String? {
        if episodeText?.isEmpty == false, let still = episodeArtworkURL, !still.isEmpty { return still }
        if let backgroundURL, !backgroundURL.isEmpty { return backgroundURL }
        if let posterURL, !posterURL.isEmpty { return posterURL }
        return nil
    }
}
