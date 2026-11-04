import Foundation
import GRDB
import Testing
@testable import Petrichor

/// `DatabaseMigrator` carries every installed library from the schema it was
/// created with to the current one. Each case builds the database an older
/// build left on disk, then runs the remaining migrations one at a time and
/// checks that the library's rows survive every step.
@Suite struct DatabaseMigrationTests {
    private static let pendingBackgroundJobs: Set<String> = [
        "v8_background_convert_artwork_to_heic",
        "v9_background_rebuild_artist_associations",
        "v12_background_backfill_album_artists",
        "v13_background_fill_artwork_thumbnail",
        "v16_background_jpeg_thumbnails",
        "v16_background_move_artwork_columns_last"
    ]

    // MARK: - Step by step from v1

    @Test func everyStepFromTheFirstSchemaKeepsTheLibrary() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pool = try makeTestDatabasePool(in: root)
        let migrator = DatabaseMigrator.setupMigrator()
        let identifiers = migrator.migrations
        #expect(identifiers.first == "v1_initial_schema")

        try migrator.migrate(pool, upTo: "v1_initial_schema")
        let favoritedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try pool.write { db in try insertFirstSchemaLibrary(db, dateAdded: favoritedAt) }
        let before = try pool.read(LibrarySnapshot.init)

        for identifier in identifiers.dropFirst() {
            try migrator.migrate(pool, upTo: identifier)
            let after = try pool.read(LibrarySnapshot.init)
            #expect(after == before, "rows changed by \(identifier)")
        }

        try pool.read { db throws in
            #expect(try migrator.appliedIdentifiers(db) == Set(identifiers))

            // v2, v5, v15: new columns, with v15's favorites backfill.
            #expect(try db.columns(in: "folders").contains { $0.name == "shasum_hash" })
            #expect(try db.columns(in: "tracks").contains { $0.name == "lossless" })
            let favorited = try Date.fetchOne(db, sql: "SELECT date_favorited FROM tracks WHERE title = 'Above Your Hand'")
            #expect(favorited == favoritedAt)
            let notFavorited = try Row.fetchOne(db, sql: "SELECT date_favorited FROM tracks WHERE title = 'Группа крови'")
            #expect(notFavorited != nil)
            #expect((notFavorited?["date_favorited"] as Date?) == nil)

            // v3: the artist count leaves the duplicate copy out.
            #expect(try Int.fetchOne(db, sql: "SELECT total_tracks FROM artists WHERE name = 'Annabel'") == 1)

            // v4: search finds existing tracks, Cyrillic included, and new
            // tracks through the recreated triggers.
            #expect(try searchCount("Группа", in: db) == 1)
            #expect(try searchCount("Annabel", in: db) == 2)

            // v6 and v15 rewrote the seeded smart playlists.
            let mostPlayed = try String.fetchOne(
                db, sql: "SELECT smart_criteria FROM playlists WHERE name = ?", arguments: [DefaultPlaylists.mostPlayed]
            )
            #expect(mostPlayed?.contains(#""condition":"greaterThanOrEqual""#) == true)
            #expect(mostPlayed?.contains(#""condition":"greaterThan""#) == false)
            let favorites = try Playlist.filter(Playlist.Columns.name == DefaultPlaylists.favorites).fetchOne(db)
            #expect(favorites?.smartCriteria?.sortBy == "dateFavorited")
            #expect(favorites?.smartCriteria?.sortAscending == false)

            // v7..v16: one-time jobs queued for the background runner.
            let pending = try String.fetchSet(db, sql: "SELECT identifier FROM background_migrations WHERE completed_at IS NULL")
            #expect(pending == Self.pendingBackgroundJobs)

            // v11, v14, v17, v18.
            #expect(try db.tableExists("artist_aliases"))
            #expect(try db.tableExists("album_aliases"))
            #expect(try db.tableExists("playback_journal_cursor"))
            #expect(try !db.tableExists("pinned_items"))
            let indexes = try Set(["albums", "artists", "tracks"].flatMap { try db.indexes(on: $0).map(\.name) })
            #expect(indexes.isSuperset(of: ["idx_albums_listing", "idx_artists_listing", "idx_tracks_play_count", "idx_tracks_filename"]))
        }

        // The migrated file is usable through the app's own types.
        let manager = try DatabaseManager(pool: pool)
        let tracks = try manager.dbQueue.read { try Track.fetchAll($0) }
        #expect(Set(tracks.map(\.title)) == ["Above Your Hand", "Above Your Hand", "Группа крови"])
        try manager.dbQueue.write { db throws in
            try db.execute(sql: "UPDATE tracks SET title = 'Звезда по имени Солнце' WHERE title = 'Группа крови'")
        }
        try manager.dbQueue.read { db throws in
            #expect(try searchCount("Солнце", in: db) == 1)
            #expect(try searchCount("Группа", in: db) == 0)
        }
    }

    // MARK: - Fresh and reopened databases

    @Test func aFreshDatabaseReachesTheLatestSchemaAndReopensWithoutWork() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pool = try makeTestDatabasePool(in: root)

        _ = try DatabaseManager(pool: pool)
        let migrator = DatabaseMigrator.setupMigrator()
        let schemaAfterFirstOpen = try pool.read(SchemaSnapshot.init)
        try pool.read { db throws in
            #expect(try migrator.hasCompletedMigrations(db))
            #expect(try Playlist.fetchCount(db) == Playlist.createDefaultSmartPlaylists().count)
            #expect(try String.fetchSet(db, sql: "SELECT identifier FROM background_migrations") == Self.pendingBackgroundJobs)
        }

        // Reopening runs no migration again: no second seed, no duplicate job rows.
        _ = try DatabaseManager(pool: pool)
        #expect(try pool.read(SchemaSnapshot.init) == schemaAfterFirstOpen)
        try pool.read { db throws in
            #expect(try Playlist.fetchCount(db) == Playlist.createDefaultSmartPlaylists().count)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM background_migrations") == Self.pendingBackgroundJobs.count)
        }
    }

    /// Libraries created before the app adopted `DatabaseMigrator` have the
    /// tables but no `grdb_migrations` record; v1 must adopt them as-is.
    @Test func aDatabaseFromBeforeTheMigratorIsAdoptedAsTheBaseline() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pool = try makeTestDatabasePool(in: root)
        try pool.write { db throws in
            try DatabaseManager.setupDatabaseSchema(in: db)
            try db.execute(sql: "CREATE TABLE pinned_items (id INTEGER PRIMARY KEY, item_type TEXT)")
            try db.execute(sql: "INSERT INTO pinned_items (item_type) VALUES ('artist')")
            try insertFirstSchemaLibrary(db, dateAdded: Date(timeIntervalSince1970: 1_700_000_000))
        }
        let before = try pool.read(LibrarySnapshot.init)

        _ = try DatabaseManager(pool: pool)

        #expect(try pool.read(LibrarySnapshot.init) == before)
        try pool.read { db throws in
            #expect(try DatabaseMigrator.setupMigrator().hasCompletedMigrations(db))
            #expect(try !db.tableExists("pinned_items"))
            // Seeding is v1's fresh-database branch only; the existing playlists stay as they were.
            #expect(try Playlist.fetchCount(db) == Playlist.createDefaultSmartPlaylists().count + 1)
        }
    }

    // MARK: - Fixtures

    /// Rows as the v1 schema stores them, written with SQL because the app's
    /// record types already encode columns later migrations add.
    private func insertFirstSchemaLibrary(_ db: Database, dateAdded: Date) throws {
        let now = Date(timeIntervalSince1970: 1_600_000_000)
        try db.execute(
            sql: "INSERT INTO folders (name, path, track_count, date_added, date_updated) VALUES ('Music', 'Music', 3, ?, ?)",
            arguments: [now, now]
        )
        let folderId = db.lastInsertedRowID
        try db.execute(
            sql: """
                INSERT INTO artists (name, normalized_name, total_tracks, total_albums, created_at, updated_at)
                VALUES ('Annabel', 'annabel', 2, 1, ?, ?), ('Кино', 'кино', 1, 1, ?, ?)
                """,
            arguments: [now, now, now, now]
        )
        try db.execute(
            sql: "INSERT INTO albums (title, normalized_title, total_tracks, created_at, updated_at) VALUES ('Hand', 'hand', 2, ?, ?)",
            arguments: [now, now]
        )
        let albumId = db.lastInsertedRowID
        let tracks: [(path: String, title: String, artist: String, favorite: Bool, plays: Int, duplicate: Bool)] = [
            ("Music/Annabel - Above Your Hand.mp3", "Above Your Hand", "Annabel", true, 5, false),
            ("Music/Annabel - Above Your Hand (copy).mp3", "Above Your Hand", "Annabel", false, 0, true),
            ("Music/Кино - Группа крови.mp3", "Группа крови", "Кино", false, 12, false)
        ]
        for track in tracks {
            try db.execute(
                sql: """
                    INSERT INTO tracks (folder_id, album_id, path, filename, title, artist, album, composer, genre, year,
                                        duration, format, date_added, is_favorite, play_count, is_duplicate)
                    VALUES (?, ?, ?, ?, ?, ?, 'Hand', 'Unknown Composer', 'Unknown Genre', 'Unknown Year',
                            180, 'mp3', ?, ?, ?, ?)
                    """,
                arguments: [folderId, albumId, track.path, (track.path as NSString).lastPathComponent, track.title,
                            track.artist, dateAdded, track.favorite, track.plays, track.duplicate]
            )
            let trackId = db.lastInsertedRowID
            try db.execute(
                sql: "INSERT INTO track_artists (track_id, artist_id, role, position) SELECT ?, id, 'artist', 0 FROM artists WHERE name = ?",
                arguments: [trackId, track.artist]
            )
        }

        try db.execute(
            sql: """
                INSERT INTO playlists (id, name, type, is_user_editable, is_content_editable, date_created, date_modified)
                VALUES ('mix', 'Mix', 'regular', 1, 1, ?, ?)
                """,
            arguments: [now, now]
        )
        try db.execute(
            sql: "INSERT INTO playlist_tracks (playlist_id, track_id, position, date_added) SELECT 'mix', id, id, ? FROM tracks WHERE is_duplicate = 0",
            arguments: [now]
        )

        // The criteria the first releases seeded, which v6 and v15 rewrite.
        try db.execute(
            sql: """
                UPDATE playlists SET smart_criteria = REPLACE(smart_criteria, '"condition":"greaterThanOrEqual"', '"condition":"greaterThan"')
                WHERE name = ?
                """,
            arguments: [DefaultPlaylists.mostPlayed]
        )
        try db.execute(
            sql: "UPDATE playlists SET smart_criteria = REPLACE(smart_criteria, '\"sortBy\":\"dateFavorited\"', '\"sortBy\":\"dateAdded\"') WHERE name = ?",
            arguments: [DefaultPlaylists.favorites]
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("petrichor-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func searchCount(_ term: String, in db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks_fts WHERE tracks_fts MATCH ?", arguments: [term]) ?? 0
    }
}

/// The user data a migration must never lose, read with SQL so the snapshot
/// itself does not depend on columns a later migration adds.
private struct LibrarySnapshot: Equatable {
    let tracks: [String]
    let folders: [String]
    let artists: [String]
    let albums: [String]
    let trackArtists: Int
    let playlists: [String]
    let playlistTracks: [String]

    init(_ db: Database) throws {
        tracks = try String.fetchAll(db, sql: """
            SELECT id || '|' || path || '|' || title || '|' || artist || '|' || IFNULL(album_id, '') || '|' ||
                   is_favorite || '|' || play_count || '|' || is_duplicate
            FROM tracks ORDER BY id
            """)
        folders = try String.fetchAll(db, sql: "SELECT id || '|' || path || '|' || track_count FROM folders ORDER BY id")
        artists = try String.fetchAll(db, sql: "SELECT id || '|' || name FROM artists ORDER BY id")
        albums = try String.fetchAll(db, sql: "SELECT id || '|' || title FROM albums ORDER BY id")
        trackArtists = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track_artists") ?? 0
        playlists = try String.fetchAll(db, sql: "SELECT id || '|' || name || '|' || type FROM playlists ORDER BY id")
        playlistTracks = try String.fetchAll(
            db, sql: "SELECT playlist_id || '|' || track_id || '|' || position FROM playlist_tracks ORDER BY playlist_id, position"
        )
    }
}

private struct SchemaSnapshot: Equatable {
    let objects: [String]

    init(_ db: Database) throws {
        objects = try String.fetchAll(db, sql: "SELECT type || ' ' || name || ' ' || IFNULL(sql, '') FROM sqlite_master ORDER BY type, name")
    }
}
