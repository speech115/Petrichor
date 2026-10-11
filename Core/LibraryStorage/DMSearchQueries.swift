import Foundation
import PetrichorCore

extension DatabaseManager {
    func searchTracksUsingFTS(_ searchText: String, populateArtwork: Bool = true) -> [Track] {
        do {
            var tracks = try tracks(core.searchTracks(searchText: searchText, hideDuplicates: hideDuplicateTracks))
            if populateArtwork { populateAlbumArtworkForTracks(&tracks) }
            return tracks
        } catch {
            Logger.error("FTS search failed: \(error)")
            return []
        }
    }
}
