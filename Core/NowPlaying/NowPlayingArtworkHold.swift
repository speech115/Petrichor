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

    /// The current track changed or was re-published (`trackID` nil when
    /// playback stopped). `artwork` is what the track carries right now.
    mutating func trackChanged(to trackID: String?, artwork: Data?) {
        guard let trackID else {
            shown = nil
            pendingTrackID = nil
            return
        }
        if let artwork {
            shown = Shown(trackID: trackID, artwork: artwork)
            pendingTrackID = nil
            return
        }
        // The same track again without bytes (a favorite toggle, a relocation)
        // keeps whatever it already shows or is waiting for. Going back to the
        // track whose cover is still held needs no wait either.
        if pendingTrackID == trackID { return }
        if shown?.trackID == trackID {
            pendingTrackID = nil
            return
        }
        pendingTrackID = trackID
        // Hold a real cover; with nothing to hold, the new track's placeholder
        // is as good as waiting.
        if shown?.artwork == nil {
            shown = Shown(trackID: trackID, artwork: nil)
        }
    }

    /// The artwork load for `trackID` finished; `artwork` nil means the track
    /// has no cover. A load for a track that is no longer current is ignored.
    mutating func artworkResolved(for trackID: String, artwork: Data?) {
        guard (pendingTrackID ?? shown?.trackID) == trackID else { return }
        shown = Shown(trackID: trackID, artwork: artwork)
        pendingTrackID = nil
    }
}
