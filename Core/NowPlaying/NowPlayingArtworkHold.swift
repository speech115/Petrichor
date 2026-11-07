//
// NowPlayingArtworkHold
//
// Which cover the now-playing surfaces draw while the current track changes.
//
// Queue entries are stored without artwork: a track becomes current with no
// cover, and `PlaybackManager` loads it from the database a moment later.
// Drawing `currentTrack.artworkData` directly blanks every player surface to
// a placeholder for that moment, on every track change. The hold keeps the
// previous cover on screen until the new track's artwork is known — loaded,
// or confirmed absent — so the surface goes straight from one cover to the
// next.
//

import Foundation

struct NowPlayingArtworkHold: Equatable {
    /// The cover to draw: the track it belongs to and its artwork bytes
    /// (nil means the placeholder). It may still be the previous track's while
    /// `pendingTrackID` names the current one.
    struct Shown: Equatable {
        let trackID: String
        let artwork: Data?
    }

    private(set) var shown: Shown?
    /// The current track, while its artwork is still loading.
    private(set) var pendingTrackID: String?

    // RED: today's behavior — the surfaces draw whatever the current track
    // carries, so a track without bytes yet draws the placeholder.
    mutating func trackChanged(to trackID: String?, artwork: Data?) {
        shown = trackID.map { Shown(trackID: $0, artwork: artwork) }
        pendingTrackID = artwork == nil ? trackID : nil
    }

    mutating func artworkResolved(for trackID: String, artwork: Data?) {
        guard shown?.trackID == trackID else { return }
        shown = Shown(trackID: trackID, artwork: artwork)
        pendingTrackID = nil
    }
}
