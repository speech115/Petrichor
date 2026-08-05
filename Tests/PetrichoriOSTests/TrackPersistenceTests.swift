import Foundation
import GRDB
import Testing
@testable import Petrichor

@Test func trackWritesRelativePathAndReadsItBack() throws {
    let dbQueue = try DatabaseQueue()
    try dbQueue.write { db in
        // NOTE: extended beyond the plan's minimal schema (path/title/artist/album) —
        // `Track.encode(to:)` writes every column below, and GRDB's insert fails with
        // "table tracks has no column named ..." if any of them is missing.
        try db.create(table: "tracks") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("folder_id", .integer)
            t.column("path", .text).notNull()
            t.column("title", .text)
            t.column("artist", .text)
            t.column("album", .text)
            t.column("composer", .text)
            t.column("genre", .text)
            t.column("year", .text)
            t.column("duration", .double)
            t.column("format", .text)
            t.column("lossless", .boolean)
            t.column("date_added", .datetime)
            t.column("is_favorite", .boolean)
            t.column("play_count", .integer)
            t.column("last_played_date", .datetime)
            t.column("album_artist", .text)
            t.column("track_number", .integer)
            t.column("disc_number", .integer)
            t.column("album_id", .integer)
        }
    }

    let url = LibraryPathStore.libraryRoot.appendingPathComponent("Моя музыка/track.mp3")
    let track = Track(url: url)

    try dbQueue.write { db in try track.insert(db) }

    let storedPath = try dbQueue.read { db in
        try String.fetchOne(db, sql: "SELECT path FROM tracks LIMIT 1")
    }
    #expect(storedPath == "Моя музыка/track.mp3")

    let loaded = try dbQueue.read { db in try Track.fetchOne(db) }
    #expect(loaded?.url.standardizedFileURL == url.standardizedFileURL)
}
