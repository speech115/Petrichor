import Foundation
import PetrichorCore

extension DatabaseManager {
    func updateTrackFavoriteStatus(trackId: Int64, isFavorite: Bool) async throws {
        try await Task.detached {
            try self.core.updateTrackFavorite(
                trackId: trackId, favorite: isFavorite, now: Date().timeIntervalSince1970)
        }.value
    }
    func updatePlayingTrackMetadata(trackId: Int64, playCount: Int, lastPlayedDate: Date)
        async throws
    {
        try await Task.detached {
            try self.core.updateTrackPlayback(
                trackId: trackId, playCount: Int64(playCount),
                lastPlayed: lastPlayedDate.timeIntervalSince1970)
        }.value
    }
    func updateTrackLyrics(for fullTrack: FullTrack, lyrics: String) async throws {
        guard let id = fullTrack.trackId else { throw DatabaseError.invalidTrackId }
        try await Task.detached { try self.core.updateTrackLyrics(trackId: id, lyrics: lyrics) }
            .value
    }
}
