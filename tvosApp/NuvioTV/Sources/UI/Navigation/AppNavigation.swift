import Foundation
import SwiftUI

/// Which top-level surface the app is showing. This is app state, not
/// navigation: `main` hosts the tab view and the navigation stack, the other
/// two are gates that replace it.
enum AppPhase: Equatable {
    case login
    case profileSelection
    case main
}

/// Where the built-in player was launched from. Drives what the user lands on
/// when it dismisses (see `ContentView.dismissPlayer`) and rides along in the
/// PiP context so a restore lands them in the same place.
public enum PlaybackOrigin {
    case main
    case details
    case cloudLibrary
}

/// A screen pushed on top of the tab view. The `NavigationStack` path *is* the
/// back stack: Menu pops, and the screen underneath stays mounted.
enum Route: Hashable {
    case details(id: String, type: String)
    /// Browse titles inside one collection folder (catalogs grouped under it).
    case collectionFolder(TVCollectionFolderItem, collectionTitle: String)
    /// All titles from a production company or network.
    case productionBrowse(MetaCompany)
    /// Movies and series associated with a TMDB person.
    case personBrowse(TmdbPersonMetadata)
    case cloudLibrary

    /// `"<type>:<id>"` for a Details route, nil otherwise. Matches the key a
    /// `StreamPickerRequest` is addressed to.
    var detailsKey: String? {
        if case let .details(id, type) = self { return "\(type):\(id)" }
        return nil
    }
}

/// One built-in player session, presented as a full-screen cover over whatever
/// is on the stack. A fresh `id` per presentation means re-presenting the same
/// URL (PiP restore, "play again") still replaces the cover.
struct PlayerPresentation: Identifiable {
    let id: UUID
    let url: URL
    let meta: NuvioMeta
    let subtitle: String
    let httpHeaders: [String: String]
    let externalSubtitles: [NuvioSubtitle]
    let resumeFrom: Double?
    /// Series context so the player can offer/auto-play the next episode.
    /// Empty for movies and trailers.
    let episodes: [NuvioVideo]
    let currentEpisode: NuvioVideo?
    let origin: PlaybackOrigin

    init(
        url: URL,
        meta: NuvioMeta,
        subtitle: String,
        httpHeaders: [String: String],
        externalSubtitles: [NuvioSubtitle],
        resumeFrom: Double?,
        episodes: [NuvioVideo],
        currentEpisode: NuvioVideo?,
        origin: PlaybackOrigin
    ) {
        id = UUID()
        self.url = url
        self.meta = meta
        self.subtitle = subtitle
        self.httpHeaders = httpHeaders
        self.externalSubtitles = externalSubtitles
        self.resumeFrom = resumeFrom
        self.episodes = episodes
        self.currentEpisode = currentEpisode
        self.origin = origin
    }

    /// Rebuilds the presentation the PiP window was started from.
    init(from context: ActivePlaybackContext) {
        self.init(
            url: context.url,
            meta: context.meta,
            subtitle: context.subtitle,
            httpHeaders: context.httpHeaders,
            externalSubtitles: context.externalSubtitles,
            resumeFrom: context.resumeFrom,
            episodes: context.episodes,
            currentEpisode: context.currentEpisode,
            origin: context.playbackOrigin
        )
    }

    var isTrailer: Bool { subtitle == PlaybackMarkers.trailerSubtitle }
    var detailsKey: String { "\(meta.type):\(meta.id)" }
}

/// Asks the Details screen addressed by `detailsKey` to raise its stream
/// picker. A new token per request, so the same mounted screen can honour it
/// repeatedly (it is no longer re-created between visits).
struct StreamPickerRequest: Equatable {
    let token: UUID
    let detailsKey: String
    let episode: NuvioVideo?

    init(detailsKey: String, episode: NuvioVideo?) {
        token = UUID()
        self.detailsKey = detailsKey
        self.episode = episode
    }
}

/// Work deferred until the Player cover has fully dismissed. UIKit refuses a
/// new presentation while one is still animating out, so anything that pushes
/// or presents after the player closes runs from the cover's `onDismiss`.
enum PostPlayerAction {
    /// Replace the stack with this title (deep link, recommendation flows).
    case openDetailsRoot(id: String, type: String)
    /// Push this title on top of whatever is there (series played from Home).
    case pushDetails(id: String, type: String)
    case reopenStreamPicker(detailsKey: String, episode: NuvioVideo?)
    case playRecommendation(NuvioMeta, playManually: Bool)
    case openRecommendationDetails(NuvioMeta)
}

/// Owns the navigation path and the player cover for the `.main` phase.
///
/// A reference type rather than loose `@State` so the closures handed to
/// pushed screens capture the live object, and so `pendingPostPlayerAction`
/// can be written without invalidating the whole root view.
@MainActor
final class AppNavigationModel: ObservableObject {
    @Published var path: [Route] = []
    @Published var player: PlayerPresentation?
    @Published var streamPickerRequest: StreamPickerRequest?
    var pendingPostPlayerAction: PostPlayerAction?
    /// Set by the player once frames are actually rendering. A session that
    /// never got this far returns the user to the stream picker on dismiss.
    var playbackDidStart = false

    /// Opens Details as a fresh navigation (Home, search, a deep link). Any
    /// "More like this" chain belongs to the flow being left, so the stack is
    /// replaced and back from here returns to the tab view.
    func openDetailsRoot(id: String, type: String) {
        path = [.details(id: id, type: type)]
    }

    func push(_ route: Route) {
        path.append(route)
    }

    func pop() {
        guard !path.isEmpty else { return }
        path.removeLast()
    }

    /// Drops every pushed screen and any player. Used when the app leaves the
    /// `.main` phase (profile switch, sign in/out).
    func reset() {
        player = nil
        streamPickerRequest = nil
        pendingPostPlayerAction = nil
        playbackDidStart = false
        path.removeAll()
    }

    /// True while anything sits on top of the tab view.
    var isCoveringTabs: Bool {
        !path.isEmpty || player != nil
    }

    var topDetailsKey: String? {
        path.last?.detailsKey
    }
}
