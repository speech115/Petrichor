import Foundation
import GRDB
import Testing
@testable import Petrichor

/// `getArtistsNeedingImageOrBio` decides which artists a fetch run asks
/// Apple Music about. Every artist the old sources tried before Apple Music
/// arrived is due once, found or not.
struct ArtistFetchQueueTests {
    @Test func artistsTriedBeforeAppleMusicAreDueWhetherOrNotTheOldSourcesFoundThem() async throws {
        let (manager, directory) = try makeTestDatabaseManager()
        defer { try? FileManager.default.removeItem(at: directory) }
        let beforeAppleMusic = ArtistInfoSource.appleMusicSince.addingTimeInterval(-60 * 60)

        try await manager.dbQueue.write { db throws in
            for (file, name) in [("a.mp3", "Found"), ("b.mp3", "Missed"), ("c.mp3", "Done")] {
                let track = try insertTestTrack(db, file: file, title: file, artist: name)
                try manager.processTrackArtists(track, in: db)
            }
            // The old sources found a photo and a bio.
            try db.execute(sql: """
                UPDATE artists SET image_source = 'musicbrainz', bio = 'x', bio_source = 'last.fm',
                image_updated_at = ?, bio_updated_at = ? WHERE name = 'Found'
                """, arguments: [beforeAppleMusic, beforeAppleMusic])
            // The old sources found nothing: stamped, sources left nil.
            try db.execute(sql: """
                UPDATE artists SET image_updated_at = ?, bio_updated_at = ? WHERE name = 'Missed'
                """, arguments: [beforeAppleMusic, beforeAppleMusic])
            // Apple Music already answered.
            try db.execute(sql: """
                UPDATE artists SET image_source = 'applemusic', bio = 'x', bio_source = 'applemusic',
                image_updated_at = ?, bio_updated_at = ? WHERE name = 'Done'
                """, arguments: [Date(), Date()])
        }

        let due = Set(manager.getArtistsNeedingImageOrBio().map(\.name))

        #expect(due == ["Found", "Missed"])
    }
}
