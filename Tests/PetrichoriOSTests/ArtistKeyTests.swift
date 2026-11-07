import Foundation
import GRDB
import Testing
@testable import Petrichor

/// `ArtistParser.normalizeArtistName` is the artist's identity: it is stored
/// as `artists.normalized_name` under a unique index and decides whether two
/// tags are one artist. Fuzzing found it was not idempotent — whitespace other
/// than a plain space, a space before a dot or a doubled dot survived the
/// initials rule — so `J.\u{00A0}Cole` and `J. Cole` became two artists.

// MARK: - The rule

@Test(arguments: FuzzText.seeds(200))
func artistNameNormalizationIsIdempotent(seed: UInt64) {
    var rng = SeededGenerator(seed: seed)
    let name = FuzzText.string(using: &rng)
    let once = ArtistParser.normalizeArtistName(name)

    #expect(ArtistParser.normalizeArtistName(once) == once, "\(name.debugDescription)")
}

@Test(arguments: [
    ("J.\u{00A0}Cole", "J. Cole"),
    ("J.\tCole", "J. Cole"),
    ("A .B", "A.B"),
    ("A..B", "A.B"),
    ("Jay\u{3000}Z", "Jay Z")
])
func artistNamesThatDifferOnlyInWhitespaceOrDotsShareAKey(variant: String, plain: String) {
    #expect(ArtistParser.normalizeArtistName(variant) == ArtistParser.normalizeArtistName(plain))
}

// MARK: - v19 re-keys the stored library

@Suite struct ArtistKeyMigrationTests {
    @Test func v19FoldsArtistsThatNowShareAKeyAndReKeysTheRest() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("petrichor-v19-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pool = try makeTestDatabasePool(in: root)
        let migrator = DatabaseMigrator.setupMigrator()
        try migrator.migrate(pool, upTo: "v18_listing_indexes")

        // The library as v18 left it: keys written by the old rule.
        let ids = try pool.write { db -> (cole: Int64, coleNBSP: Int64, dots: Int64, tracks: [Int64]) in
            let tracks = try ["a", "b", "c"].map { file in
                try insertTestTrack(db, file: "\(file).mp3", title: file, artist: "x").trackId ?? -1
            }
            func artist(_ name: String, key: String, tracks: Int, bio: String? = nil) throws -> Int64 {
                try db.execute(
                    sql: """
                        INSERT INTO artists (name, normalized_name, sort_name, total_tracks, total_albums, bio, created_at, updated_at)
                        VALUES (?, ?, ?, ?, 0, ?, ?, ?)
                        """,
                    arguments: [name, key, name, tracks, bio, Date(), Date()]
                )
                return db.lastInsertedRowID
            }
            let cole = try artist("J. Cole", key: "jcole", tracks: 2)
            let coleNBSP = try artist("J.\u{00A0}Cole", key: "j cole", tracks: 1, bio: "From the NBSP row")
            let dots = try artist("A..B", key: "a.b", tracks: 1)
            func link(_ track: Int64, _ artist: Int64) throws {
                try db.execute(
                    sql: "INSERT INTO track_artists (track_id, artist_id, role, position) VALUES (?, ?, 'artist', 0)",
                    arguments: [track, artist]
                )
            }
            try link(tracks[0], cole)
            try link(tracks[0], coleNBSP) // same track on both rows: must not duplicate
            try link(tracks[1], coleNBSP)
            try link(tracks[2], dots)
            try db.execute(
                sql: "INSERT INTO artist_aliases (normalized_alias, display_name, canonical_artist_id, created_at) VALUES (?, ?, ?, ?)",
                arguments: ["jermaine  cole", "Jermaine\u{00A0} Cole", coleNBSP, Date()]
            )
            return (cole, coleNBSP, dots, tracks)
        }

        try migrator.migrate(pool)

        try pool.read { db throws in
            let rows = try Row.fetchAll(db, sql: "SELECT id, name, normalized_name, total_tracks, bio FROM artists ORDER BY id")
            #expect(rows.map { $0["id"] as Int64 } == [ids.cole, ids.dots])
            for row in rows {
                let name: String = row["name"]
                #expect((row["normalized_name"] as String) == ArtistParser.normalizeArtistName(name), "\(name)")
            }
            #expect((rows.first?["total_tracks"] as Int?) == 2)
            #expect((rows.first?["bio"] as String?) == "From the NBSP row")

            #expect(try linkedArtistNames(trackId: ids.tracks[0], role: "artist", in: db) == ["J. Cole"])
            #expect(try linkedArtistNames(trackId: ids.tracks[1], role: "artist", in: db) == ["J. Cole"])
            #expect(try linkedArtistNames(trackId: ids.tracks[2], role: "artist", in: db) == ["A..B"])

            let alias = try Row.fetchOne(db, sql: "SELECT normalized_alias, canonical_artist_id FROM artist_aliases")
            #expect((alias?["normalized_alias"] as String?) == ArtistParser.normalizeArtistName("Jermaine\u{00A0} Cole"))
            #expect((alias?["canonical_artist_id"] as Int64?) == ids.cole)
        }
    }
}
