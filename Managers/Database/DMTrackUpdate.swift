//
// DatabaseManager class extension
//
// This extension contains methods for updating individual tracks based on user
// interaction events like marking as favorite, play count, last played, etc.
//

import Foundation
import GRDB

extension DatabaseManager {
    // Updates a track's favorite status
    func updateTrackFavoriteStatus(trackId: Int64, isFavorite: Bool) async throws {
        _ = try await dbQueue.write { db in
            try Track
                .filter(Track.Columns.trackId == trackId)
                .updateAll(
                    db,
                    Track.Columns.isFavorite.set(to: isFavorite),
                    Track.Columns.dateFavorited.set(to: isFavorite ? Date() : nil)
                )
        }
    }

    // Updates a track's play count and last played date
    /// One listen, counted in a single statement: a read-then-write pair lost
    /// whichever increment or journal write landed between them (I-7.4, D-5).
    /// Returns the new count, nil when the track is gone.
    func incrementPlayCount(trackId: Int64, lastPlayedDate: Date) async throws -> Int? {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE tracks SET play_count = play_count + 1, last_played_date = ? WHERE id = ?",
                arguments: [lastPlayedDate, trackId]
            )
            return try Int.fetchOne(db, sql: "SELECT play_count FROM tracks WHERE id = ?", arguments: [trackId])
        }
    }

    /// Updates a track's lyrics in extended_metadata
    func updateTrackLyrics(for fullTrack: FullTrack, lyrics: String) async throws {
        guard fullTrack.trackId != nil else {
            throw DatabaseError.invalidTrackId
        }
        
        var updatedTrack = fullTrack
        var extendedMetadata = updatedTrack.extendedMetadata ?? ExtendedMetadata()
        extendedMetadata.lyrics = lyrics
        updatedTrack.extendedMetadata = extendedMetadata
        
        let trackToSave = updatedTrack
        try await dbQueue.write { db in
            try trackToSave.update(db)
        }
    }
}
