import Foundation
import GRDB
import Testing
@testable import Petrichor

/// Normalization (`DMNormalization`) turns a track's tag strings into the
/// artist, album and genre rows the library navigates; merging (`DMMerge`)
/// folds duplicates of those rows together and must survive the next scan.
@Suite(.serialized)
struct LibraryNormalizationTests {
    // MARK: - Artists

    @Test func trackArtistsAreLinkedPerRoleInTagOrder() async throws {
        let (manager, directory) = try makeTestDatabaseManager()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await manager.dbQueue.write { db throws in
            let track = try insertTestTrack(db, file: "a.mp3", title: "A", artist: "Сплин feat. Би-2 & Земфира",
                                            composer: "Александр Васильев")
            try manager.processTrackArtists(track, in: db)
            let id = try #require(track.trackId)

            #expect(try linkedArtistNames(trackId: id, role: TrackArtist.Role.artist, in: db) == ["Сплин", "Би-2", "Земфира"])
            #expect(try linkedArtistNames(trackId: id, role: TrackArtist.Role.composer, in: db) == ["Александр Васильев"])
            // No album-artist tag: the track artist stands in.
            #expect(try linkedArtistNames(trackId: id, role: TrackArtist.Role.albumArtist, in: db) == ["Сплин", "Би-2", "Земфира"])
        }
    }

    @Test func placeholderTagsLinkNoArtist() async throws {
        let (manager, directory) = try makeTestDatabaseManager()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await manager.dbQueue.write { db throws in
            let track = try insertTestTrack(db, file: "a.mp3", title: "A", artist: "Unknown Artist")
            try manager.processTrackArtists(track, in: db)
            #expect(try TrackArtist.fetchCount(db) == 0)
            #expect(try Artist.fetchCount(db) == 0)
        }
    }

    @Test func artistsMatchByNormalizedName() async throws {
        let (manager, directory) = try makeTestDatabaseManager()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await manager.dbQueue.write { db throws in
            let first = try manager.findOrCreateArtist("J. Cole", in: db)
            let second = try manager.findOrCreateArtist("j cole", in: db)
            #expect(first.id == second.id)
            #expect(try Artist.fetchCount(db) == 1)
        }
    }

    /// Two names on one tag can land on the same artist row (a merged-away
    /// name next to its canonical one). The second link used to violate the
    /// junction's primary key and drop the track's remaining processing.
    @Test func twoNamesForOneArtistLinkItOnce() async throws {
        let (manager, directory) = try makeTestDatabaseManager()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await manager.dbQueue.write { db throws in
            let pink = try insertTestTrack(db, file: "a.mp3", title: "A", artist: "Pink")
            let alias = try insertTestTrack(db, file: "b.mp3", title: "B", artist: "P!nk")
            try manager.processTrackArtists(pink, in: db)
            try manager.processTrackArtists(alias, in: db)
            try manager.mergeArtists(winnerName: "Pink", loserNames: ["P!nk"], newName: nil, in: db)

            let both = try insertTestTrack(db, file: "c.mp3", title: "C", artist: "Pink & P!nk", album: "Funhouse")
            try manager.processTrackArtists(both, in: db)
            var mutable = both
            try manager.processTrackAlbum(&mutable, in: db)
            let id = try #require(both.trackId)
            #expect(try linkedArtistNames(trackId: id, role: TrackArtist.Role.artist, in: db) == ["Pink"])
            let albumId = try #require(mutable.albumId)
            #expect(try albumArtistRows(albumId: albumId, in: db) == ["primary:Pink"])
        }
    }

    // MARK: - Albums

    @Test func albumsGroupByTitleAndPrimaryArtist() async throws {
        let (manager, directory) = try makeTestDatabaseManager()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await manager.dbQueue.write { db throws in
            var first = try insertTestTrack(db, file: "1.mp3", title: "1", artist: "Кино", album: "Группа крови")
            var second = try insertTestTrack(db, file: "2.mp3", title: "2", artist: "Кино feat. Земфира", album: "группа крови")
            var other = try insertTestTrack(db, file: "3.mp3", title: "3", artist: "Сплин", album: "Группа крови")
            var compilation = try insertTestTrack(db, file: "4.mp3", title: "4", artist: "Сплин", album: "Хиты")
            compilation.compilation = true
            for index in [0, 1, 2, 3] {
                switch index {
                case 0: try manager.processTrackAlbum(&first, in: db)
                case 1: try manager.processTrackAlbum(&second, in: db)
                case 2: try manager.processTrackAlbum(&other, in: db)
                default: try manager.processTrackAlbum(&compilation, in: db)
                }
            }

            #expect(first.albumId != nil)
            #expect(first.albumId == second.albumId)
            #expect(other.albumId != first.albumId)
            let firstAlbum = try #require(first.albumId)
            #expect(try albumArtistRows(albumId: firstAlbum, in: db) == ["primary:Кино", "featured:Земфира"])
            let compilationAlbum = try #require(compilation.albumId)
            #expect(try albumArtistRows(albumId: compilationAlbum, in: db) == ["primary:Various Artists", "featured:Сплин"])
        }
    }

    @Test func entityStatsCountOnlyOriginals() async throws {
        let (manager, directory) = try makeTestDatabaseManager()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await manager.dbQueue.write { db throws in
            for (file, duplicate) in [("1.mp3", false), ("1 copy.mp3", true), ("2.mp3", false)] {
                var track = try insertTestTrack(db, file: file, title: file, artist: "Кино", album: "Группа крови",
                                                isDuplicate: duplicate)
                try manager.processTrackArtists(track, in: db)
                try manager.processTrackAlbum(&track, in: db)
                try track.update(db)
            }
            try manager.updateEntityStats(in: db)

            #expect(try Int.fetchOne(db, sql: "SELECT total_tracks FROM artists WHERE name = 'Кино'") == 2)
            #expect(try Int.fetchOne(db, sql: "SELECT total_albums FROM artists WHERE name = 'Кино'") == 1)
            #expect(try Int.fetchOne(db, sql: "SELECT total_tracks FROM albums") == 2)
        }
    }

    // MARK: - Genres

    /// Multi-value genre tags repeat a genre ("Electronic; Electronic/Dance").
    /// The repeat used to violate `track_genres`' primary key.
    @Test func repeatedGenresLinkOnce() async throws {
        let (manager, directory) = try makeTestDatabaseManager()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await manager.dbQueue.write { db throws in
            let track = try insertTestTrack(db, file: "a.mp3", title: "A", artist: "Кино", genre: "Electronic; Electronic/Dance; Рок")
            try manager.processTrackGenres(track, in: db)
            let names = try String.fetchAll(db, sql: """
                SELECT genres.name FROM track_genres JOIN genres ON genres.id = track_genres.genre_id ORDER BY genres.name
                """)
            #expect(names == ["Dance", "Electronic", "Рок"])
        }
    }

    // MARK: - Compilation albums

    @Test func compilationTracksInOneFolderShareOneAlbum() async throws {
        let (manager, directory) = try makeTestDatabaseManager()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await manager.dbQueue.write { db throws in
            for (file, artist) in [("Hits/1.mp3", "Кино"), ("Hits/2.mp3", "Сплин"), ("Hits/3.mp3", "Кино")] {
                var track = try insertTestTrack(db, file: file, title: file, artist: artist, album: "Хиты")
                try manager.processTrackArtists(track, in: db)
                try manager.processTrackAlbum(&track, in: db)
                try track.update(db)
            }
            #expect(try Int64.fetchSet(db, sql: "SELECT DISTINCT album_id FROM tracks").count == 2)
        }

        try await manager.normalizeCompilationAlbums()

        try await manager.dbQueue.read { db throws in
            let albumIds = try Int64.fetchSet(db, sql: "SELECT DISTINCT album_id FROM tracks")
            #expect(albumIds.count == 1)
            let albumId = try #require(albumIds.first)
            #expect(try albumArtistRows(albumId: albumId, in: db) == ["primary:Various Artists", "featured:Кино", "featured:Сплин"])
        }
    }

    // MARK: - Merge

    @Test func mergingArtistsMovesLinksAndSurvivesTheNextScan() async throws {
        let (manager, directory) = try makeTestDatabaseManager()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await manager.dbQueue.write { db throws in
            for (file, artist) in [("1.mp3", "Земфира"), ("2.mp3", "Zemfira"), ("3.mp3", "Zemfira & Кино")] {
                let track = try insertTestTrack(db, file: file, title: file, artist: artist)
                try manager.processTrackArtists(track, in: db)
            }
            let artwork = Data([1, 2, 3])
            try db.execute(sql: "UPDATE artists SET artwork_data = ?, bio = 'bio' WHERE name = 'Zemfira'", arguments: [artwork])
        }

        let result = try await manager.mergeArtists(winnerName: "Земфира", loserNames: ["Zemfira", "Unknown Artist"], newName: nil)
        #expect(result.mergedCount == 1)
        #expect(result.canonicalName == "Земфира")

        try await manager.dbQueue.write { db throws in
            #expect(try String.fetchAll(db, sql: "SELECT name FROM artists ORDER BY name") == ["Земфира", "Кино"])
            #expect(try Int.fetchOne(db, sql: "SELECT total_tracks FROM artists WHERE name = 'Земфира'") == 3)
            #expect(try String.fetchOne(db, sql: "SELECT bio FROM artists WHERE name = 'Земфира'") == "bio")
            #expect(try Data.fetchOne(db, sql: "SELECT artwork_data FROM artists WHERE name = 'Земфира'") == Data([1, 2, 3]))

            // A rescan of the old tag lands on the winner, not a new "Zemfira".
            let rescanned = try insertTestTrack(db, file: "4.mp3", title: "4", artist: "Zemfira")
            try manager.processTrackArtists(rescanned, in: db)
            let id = try #require(rescanned.trackId)
            #expect(try linkedArtistNames(trackId: id, role: TrackArtist.Role.artist, in: db) == ["Земфира"])
            #expect(try Artist.filter(Artist.Columns.name == "Zemfira").fetchCount(db) == 0)
        }
    }

    @Test func renamingAnArtistIntoAnotherFoldsItInAndKeepsBothOldNames() async throws {
        let (manager, directory) = try makeTestDatabaseManager()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await manager.dbQueue.write { db throws in
            for (file, artist) in [("1.mp3", "Kino"), ("2.mp3", "Кино")] {
                try manager.processTrackArtists(try insertTestTrack(db, file: file, title: file, artist: artist), in: db)
            }
        }

        let result = try await manager.mergeArtists(winnerName: "Kino", loserNames: [], newName: "Кино")
        #expect(result.canonicalName == "Кино")

        try await manager.dbQueue.write { db throws in
            #expect(try String.fetchAll(db, sql: "SELECT name FROM artists") == ["Кино"])
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track_artists WHERE role = 'artist'") == 2)
            #expect(try manager.findOrCreateArtist("Kino", in: db).name == "Кино")
            #expect(try manager.findOrCreateArtist("КИНО", in: db).name == "Кино")
            #expect(try Artist.fetchCount(db) == 1)
        }

        // Renaming back drops the alias that now names the live artist.
        try await manager.mergeArtists(winnerName: "Кино", loserNames: [], newName: "Kino")
        try await manager.dbQueue.read { db throws in
            #expect(try String.fetchAll(db, sql: "SELECT name FROM artists") == ["Kino"])
            #expect(try String.fetchSet(db, sql: "SELECT normalized_alias FROM artist_aliases") == ["кино"])
        }
    }

    @Test func mergingAnUnknownArtistFails() async throws {
        let (manager, directory) = try makeTestDatabaseManager()
        defer { try? FileManager.default.removeItem(at: directory) }

        await #expect(throws: EntityMergeError.self) {
            try await manager.mergeArtists(winnerName: "Nobody", loserNames: ["Somebody"], newName: nil)
        }
    }

    @Test func mergingAlbumsMovesTracksArtworkAndSurvivesTheNextScan() async throws {
        let (manager, directory) = try makeTestDatabaseManager()
        defer { try? FileManager.default.removeItem(at: directory) }

        let ids = try await manager.dbQueue.write { db -> [Int64] in
            var albumIds: [Int64] = []
            for (file, album) in [("1.mp3", "Группа крови"), ("2.mp3", "Группа Крови (Remastered)"), ("3.mp3", "Gruppa Krovi")] {
                var track = try insertTestTrack(db, file: file, title: file, artist: "Кино", album: album)
                try manager.processTrackArtists(track, in: db)
                try manager.processTrackAlbum(&track, in: db)
                try track.update(db)
                albumIds.append(try #require(track.albumId))
            }
            try db.execute(sql: "UPDATE albums SET artwork_data = ? WHERE id = ?", arguments: [makeTestImage(width: 600, height: 600), albumIds[2]])
            try manager.updateEntityStats(in: db)
            return albumIds
        }
        #expect(Set(ids).count == 3)

        let result = try await manager.mergeAlbums(winnerId: ids[0], loserIds: [ids[1], ids[2], ids[0]], newTitle: nil)
        #expect(result.mergedCount == 2)

        try await manager.dbQueue.write { db throws in
            #expect(try Album.fetchCount(db) == 1)
            #expect(try String.fetchSet(db, sql: "SELECT album FROM tracks") == ["Группа крови"])
            #expect(try Int64.fetchSet(db, sql: "SELECT album_id FROM tracks") == [ids[0]])
            #expect(try Int.fetchOne(db, sql: "SELECT total_tracks FROM albums") == 3)
            #expect(try Data.fetchOne(db, sql: "SELECT artwork_thumbnail FROM albums") != nil)
            #expect(try albumArtistRows(albumId: ids[0], in: db) == ["primary:Кино"])

            // The next scan of a merged-away title lands on the winner.
            var rescanned = try insertTestTrack(db, file: "4.mp3", title: "4", artist: "Кино", album: "Gruppa Krovi")
            try manager.processTrackAlbum(&rescanned, in: db)
            #expect(rescanned.albumId == ids[0])
        }
    }

    /// Merging duplicates of one album and renaming the result in the same
    /// step writes the old title's alias twice (once for the loser, once for
    /// the renamed winner).
    @Test func mergingAndRenamingDuplicateAlbumsKeepsOneAlias() async throws {
        let (manager, directory) = try makeTestDatabaseManager()
        defer { try? FileManager.default.removeItem(at: directory) }

        let ids = try await manager.dbQueue.write { db -> [Int64] in
            var albumIds: [Int64] = []
            for file in ["1.mp3", "2.mp3"] {
                let album = Album(title: "Группа крови")
                try album.insert(db)
                let albumId = try #require(album.id)
                let artist = try manager.findOrCreateArtist("Кино", in: db)
                try AlbumArtist(albumId: albumId, artistId: try #require(artist.id)).insert(db)
                try insertTestTrack(db, file: file, title: file, artist: "Кино", album: "Группа крови", albumId: albumId)
                albumIds.append(albumId)
            }
            return albumIds
        }

        let result = try await manager.mergeAlbums(winnerId: ids[0], loserIds: [ids[1]], newTitle: "Группа крови (1988)")
        #expect(result.canonicalName == "Группа крови (1988)")

        try await manager.dbQueue.write { db throws in
            #expect(try String.fetchAll(db, sql: "SELECT title FROM albums") == ["Группа крови (1988)"])
            let aliases = try Row.fetchAll(db, sql: "SELECT normalized_key, canonical_album_id FROM album_aliases")
            #expect(aliases.count == 1)
            #expect((aliases.first?["canonical_album_id"] as Int64?) == ids[0])
            var rescanned = try insertTestTrack(db, file: "3.mp3", title: "3", artist: "Кино", album: "Группа крови")
            try manager.processTrackAlbum(&rescanned, in: db)
            #expect(rescanned.albumId == ids[0])
        }
    }
}
