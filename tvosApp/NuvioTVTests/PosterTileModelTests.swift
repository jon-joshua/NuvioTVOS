import XCTest
@testable import NuvioTV

final class PosterTileModelTests: XCTestCase {
    // MARK: Caption

    func testSubtitleJoinsAllParts() {
        XCTAssertEqual(PosterCaption.subtitle(typeLabel: "Series", year: "2019", rating: 7.8), "Series  ·  2019  ·  ★ 7.8")
    }

    func testSubtitleOmitsMissingYearAndZeroRating() {
        XCTAssertEqual(PosterCaption.subtitle(typeLabel: "Movie", year: nil, rating: 0), "Movie")
        XCTAssertEqual(PosterCaption.subtitle(typeLabel: "Movie", year: "", rating: nil), "Movie")
        XCTAssertEqual(PosterCaption.subtitle(typeLabel: "Movie", year: "2001", rating: nil), "Movie  ·  2001")
    }

    func testMetaLine() {
        XCTAssertEqual(PosterCaption.metaLine(genre: "Drama", rating: 7.8), "Drama  ·  ★ 7.8")
        XCTAssertEqual(PosterCaption.metaLine(genre: nil, rating: 6.0), "★ 6.0")
        XCTAssertEqual(PosterCaption.metaLine(genre: "", rating: 0), nil)
        XCTAssertEqual(PosterCaption.metaLine(genre: nil, rating: nil), nil)
    }

    // MARK: Progress

    func testProgressClamps() {
        XCTAssertEqual(PosterProgress.clamped(-0.2), 0)
        XCTAssertEqual(PosterProgress.clamped(1.4), 1)
        XCTAssertEqual(PosterProgress.clamped(0.5), 0.5)
        XCTAssertNil(PosterProgress.clamped(nil))
        XCTAssertNil(PosterProgress.clamped(.nan))
    }

    func testProgressFillWidthFloorsAtMinimum() {
        XCTAssertEqual(PosterProgress.fillWidth(track: 166, progress: 0.01), 8)
        XCTAssertEqual(PosterProgress.fillWidth(track: 166, progress: 0.5), 83)
    }

    // MARK: Badge

    func testUpNextBadgeDefaultsToNextUp() {
        XCTAssertEqual(PosterBadge.make(isUpNext: true, upNextText: nil, episodeText: nil, remainingText: nil),
                       PosterBadge(text: "Next Up", tint: .neutral))
    }

    func testUpNextBadgeTintsFromText() {
        XCTAssertEqual(PosterBadge.make(isUpNext: true, upNextText: "new season", episodeText: nil, remainingText: nil)?.tint, .newSeason)
        XCTAssertEqual(PosterBadge.make(isUpNext: true, upNextText: "New Episode", episodeText: nil, remainingText: nil)?.tint, .newEpisode)
        XCTAssertEqual(PosterBadge.make(isUpNext: true, upNextText: "Airing Today", episodeText: nil, remainingText: nil)?.tint, .airingToday)
        XCTAssertEqual(PosterBadge.make(isUpNext: true, upNextText: "Airs in 3 days", episodeText: nil, remainingText: nil)?.tint, .upcoming)
        XCTAssertEqual(PosterBadge.make(isUpNext: true, upNextText: "Coming Soon", episodeText: nil, remainingText: nil)?.tint, .upcoming)
    }

    func testProgressBadgeNeedsRemainingTime() {
        XCTAssertEqual(PosterBadge.make(isUpNext: false, upNextText: nil, episodeText: "S1E2", remainingText: "12 min left"),
                       PosterBadge(text: "S1E2 • 12 min left", tint: .neutral))
        XCTAssertEqual(PosterBadge.make(isUpNext: false, upNextText: nil, episodeText: nil, remainingText: "12 min left")?.text, "12 min left")
        XCTAssertNil(PosterBadge.make(isUpNext: false, upNextText: nil, episodeText: "S1E2", remainingText: nil))
    }

    // MARK: Landscape artwork

    func testLandscapeURLPrefersEpisodeStillThenBackdropThenPoster() {
        XCTAssertEqual(PosterArtworkChoice.landscapeURL(episodeText: "S1E2", episodeArtworkURL: "still", backgroundURL: "bg", posterURL: "poster"), "still")
        XCTAssertEqual(PosterArtworkChoice.landscapeURL(episodeText: "S1E2", episodeArtworkURL: "", backgroundURL: "bg", posterURL: "poster"), "bg")
        XCTAssertEqual(PosterArtworkChoice.landscapeURL(episodeText: nil, episodeArtworkURL: "still", backgroundURL: "bg", posterURL: "poster"), "bg")
        XCTAssertEqual(PosterArtworkChoice.landscapeURL(episodeText: nil, episodeArtworkURL: nil, backgroundURL: nil, posterURL: "poster"), "poster")
        XCTAssertNil(PosterArtworkChoice.landscapeURL(episodeText: nil, episodeArtworkURL: nil, backgroundURL: nil, posterURL: nil))
    }
}
