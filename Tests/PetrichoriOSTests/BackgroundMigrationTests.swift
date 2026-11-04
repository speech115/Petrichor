import Foundation
import GRDB
import Testing
@testable import Petrichor

/// `runPendingBackgroundMigrations` finishes, after launch, the one-time jobs
/// that schema migrations v8–v16 queue: artwork recompression, the artist
/// association rebuild, the album-artist backfill, thumbnails and the
/// artwork column move. A fresh `DatabaseManager` has all of them pending,
/// which is the state an upgraded library is in on first launch.
@Suite(.serialized)
struct BackgroundMigrationTests {
    @Test func anEmptyLibraryCompletesEveryJobAndStillMovesArtworkLast() async throws {
        let (manager, directory) = try makeTestDatabaseManager()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(await manager.runPendingBackgroundMigrations() == false)

        try await manager.dbQueue.read { db throws in
            #expect(try pendingJobs(db).isEmpty)
            #expect(try db.columns(in: "albums").map(\.name).suffix(2) == ["artwork_thumbnail", "artwork_data"])
            #expect(try db.columns(in: "artists").map(\.name).suffix(2) == ["artwork_thumbnail", "artwork_data"])
            #expect(try db.columns(in: "tracks").map(\.name).last == "track_artwork_data")
        }
        #expect(await manager.runPendingBackgroundMigrations() == false)
    }

    @Test func anUpgradedLibraryIsRebuiltWithoutLosingItsData() async throws {
        let (manager, directory) = try makeTestDatabaseManager()
        defer { try? FileManager.default.removeItem(at: directory) }
        let artwork = makeTestImage(width: 1200, height: 1200)

        // A library from before v9: albums and tracks exist, the junction rows
        // are whatever an older parser left (here: none), and artwork has no
        // thumbnail yet.
        try await manager.dbQueue.write { db throws in
            let album = Album(title: "Views")
            album.artworkData = artwork
            try album.insert(db)
            let artist = Artist(name: "Кино")
            artist.artworkData = artwork
            try artist.insert(db)
            try insertTestTrack(db, file: "Drake - One Dance.mp3", title: "One Dance",
                                artist: "Drake feat. Wizkid & Kyla", album: "Views", playCount: 7, albumId: album.id)
            try insertTestTrack(db, file: "Drake - One Dance (copy).mp3", title: "One Dance",
                                artist: "Drake feat. Wizkid & Kyla", album: "Views", isDuplicate: true, albumId: album.id)
            try insertTestTrack(db, file: "Кино - Группа крови.mp3", title: "Группа крови",
                                artist: "Кино", albumArtist: "Виктор Цой", composer: "Виктор Цой", playCount: 3)
            try db.execute(
                sql: """
                    INSERT INTO playlists (id, name, type, is_user_editable, is_content_editable, date_created, date_modified)
                    VALUES ('mix', 'Mix', 'regular', 1, 1, ?, ?)
                    """,
                arguments: [Date(), Date()]
            )
            try db.execute(sql: "INSERT INTO playlist_tracks (playlist_id, track_id, position, date_added) SELECT 'mix', id, id, ? FROM tracks",
                           arguments: [Date()])
        }
        let tracksBefore = try await manager.dbQueue.read { try trackRows($0) }

        #expect(await manager.runPendingBackgroundMigrations())

        try await manager.dbQueue.read { db throws in
            #expect(try pendingJobs(db).isEmpty)
            #expect(try trackRows(db) == tracksBefore)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playlist_tracks") == 3)

            // v9: associations come from the current parser, in tag order.
            let oneDance = try #require(try Int64.fetchOne(db, sql: "SELECT id FROM tracks WHERE title = 'One Dance' AND is_duplicate = 0"))
            #expect(try linkedArtistNames(trackId: oneDance, role: TrackArtist.Role.artist, in: db) == ["Drake", "Wizkid", "Kyla"])
            let blood = try #require(try Int64.fetchOne(db, sql: "SELECT id FROM tracks WHERE title = 'Группа крови'"))
            #expect(try linkedArtistNames(trackId: blood, role: TrackArtist.Role.composer, in: db) == ["Виктор Цой"])
            #expect(try linkedArtistNames(trackId: blood, role: TrackArtist.Role.albumArtist, in: db) == ["Виктор Цой"])

            // v12: a track without an album-artist tag still has one, from its artist.
            let duplicate = try #require(try Int64.fetchOne(db, sql: "SELECT id FROM tracks WHERE is_duplicate = 1"))
            #expect(try linkedArtistNames(trackId: duplicate, role: TrackArtist.Role.albumArtist, in: db) == ["Drake", "Wizkid", "Kyla"])

            // The album the tracks point at keeps its row, artwork and artists.
            let albumId = try #require(try Int64.fetchOne(db, sql: "SELECT album_id FROM tracks WHERE id = ?", arguments: [oneDance]))
            #expect(try Album.fetchCount(db) == 1)
            #expect(try albumArtistRows(albumId: albumId, in: db).first == "primary:Drake")
            #expect(try Int.fetchOne(db, sql: "SELECT total_tracks FROM albums WHERE id = ?", arguments: [albumId]) == 1)
            #expect(try Int.fetchOne(db, sql: "SELECT total_tracks FROM artists WHERE name = 'Drake'") == 1)

            // v8, v13, v16: artwork stays, thumbnails are JPEG, BLOBs are last.
            let albumArtwork = try #require(try Row.fetchOne(db, sql: "SELECT artwork_data, artwork_thumbnail FROM albums"))
            #expect((albumArtwork["artwork_data"] as Data?) != nil)
            let thumbnail = try #require(albumArtwork["artwork_thumbnail"] as Data?)
            #expect(ImageUtils.isJPEG(thumbnail))
            let artistThumbnail = try Data.fetchOne(db, sql: "SELECT artwork_thumbnail FROM artists WHERE name = 'Кино'")
            #expect(artistThumbnail.map(ImageUtils.isJPEG) == true)
            #expect(try db.columns(in: "albums").map(\.name).suffix(2) == ["artwork_thumbnail", "artwork_data"])
            #expect(try db.columns(in: "tracks").map(\.name).last == "track_artwork_data")

            // The table rebuild kept the search index and its triggers.
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks_fts WHERE tracks_fts MATCH 'крови'") == 1)
        }

        _ = try await manager.dbQueue.write { db throws in
            try insertTestTrack(db, file: "Земфира - Хочешь.mp3", title: "Хочешь", artist: "Земфира")
        }
        let found = try await manager.dbQueue.read { db throws in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks_fts WHERE tracks_fts MATCH 'Хочешь'")
        }
        #expect(found == 1)
    }

    /// A rebuild interrupted after some batches resumes from the saved offset
    /// and keeps what the finished batches wrote.
    @Test func anInterruptedArtistRebuildResumesWithoutClearingFinishedBatches() async throws {
        let (manager, directory) = try makeTestDatabaseManager()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await manager.dbQueue.write { db throws in
            let first = try insertTestTrack(db, file: "a.mp3", title: "A", artist: "Кино & Земфира")
            try manager.processTrackArtists(first, in: db)
            try insertTestTrack(db, file: "b.mp3", title: "B", artist: "Сплин feat. Би-2")
            try db.execute(sql: "UPDATE background_migrations SET completed_at = ? WHERE identifier != 'v9_background_rebuild_artist_associations'",
                           arguments: [Date()])
            try db.execute(sql: #"UPDATE background_migrations SET progress = '{"offset":1}' WHERE completed_at IS NULL"#)
        }

        #expect(await manager.runPendingBackgroundMigrations())

        try await manager.dbQueue.read { db throws in
            #expect(try pendingJobs(db).isEmpty)
            let ids = try Int64.fetchAll(db, sql: "SELECT id FROM tracks ORDER BY id")
            #expect(try linkedArtistNames(trackId: ids[0], role: TrackArtist.Role.artist, in: db) == ["Кино", "Земфира"])
            #expect(try linkedArtistNames(trackId: ids[1], role: TrackArtist.Role.artist, in: db) == ["Сплин", "Би-2"])
        }
    }

    @Test func aFailedJobStaysPendingAndAnUnknownJobIsSkipped() async throws {
        let (manager, directory) = try makeTestDatabaseManager()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await manager.dbQueue.write { db throws in
            try insertTestTrack(db, file: "a.mp3", title: "A", artist: "Кино")
            try db.execute(sql: "UPDATE background_migrations SET completed_at = ?", arguments: [Date()])
            try db.execute(sql: "INSERT INTO background_migrations (identifier, resumable) VALUES ('v99_from_a_newer_build', 1)")
        }

        #expect(await manager.runPendingBackgroundMigrations())
        // A job this build does not know is left for the build that queued it.
        #expect(try await manager.dbQueue.read { try pendingJobs($0) } == ["v99_from_a_newer_build"])
    }
}

// MARK: - Helpers

private func pendingJobs(_ db: Database) throws -> [String] {
    try String.fetchAll(db, sql: "SELECT identifier FROM background_migrations WHERE completed_at IS NULL ORDER BY identifier")
}

private func trackRows(_ db: Database) throws -> [String] {
    try String.fetchAll(db, sql: """
        SELECT id || '|' || path || '|' || title || '|' || artist || '|' || IFNULL(album_id, '') || '|' ||
               play_count || '|' || is_duplicate
        FROM tracks ORDER BY id
        """)
}
