import Foundation
import GRDB
import Testing
@testable import Musify

/// Проверяет, что запросы, сравнивающие колонку `path` в базе, находят записи,
/// написанные швом путей — то есть дедупликация папок и поиск трека по пути
/// работают, даже когда в базе хранится относительный путь (iOS), а не
/// абсолютный.
@Test func folderLookupByURLFindsRowStoredThroughThePathSeam() throws {
    let dbQueue = try DatabaseQueue()
    try dbQueue.write { db in
        try db.create(table: "folders") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("path", .text).notNull()
            t.column("name", .text).notNull()
            t.column("track_count", .integer).notNull()
            t.column("date_added", .datetime).notNull()
            t.column("date_updated", .datetime).notNull()
            t.column("bookmark_data", .blob)
            t.column("shasum_hash", .text)
        }
    }

    let url = LibraryPathStore.libraryRoot.appendingPathComponent("Моя музыка/Spotify")
    let folder = Folder(url: url)
    try dbQueue.write { db in try folder.insert(db) }

    // This mirrors the lookup DMFolders.addFoldersAsync performs to decide
    // whether a folder is already in the library. Comparing the column
    // directly against `url.path` (an absolute path) would never match when
    // the seam stores a relative path, and the folder would be re-added.
    let found = try dbQueue.read { db in
        try Folder
            .filter(Folder.Columns.path == LibraryPathStore.storedPath(for: url))
            .fetchOne(db)
    }

    #expect(found != nil)
    #expect(found?.url.standardizedFileURL == url.standardizedFileURL)
}

@Test func findTrackByPathMatchesRowStoredThroughThePathSeam() throws {
    // `DatabaseManager` only exposes a parameterless `init()` that opens a
    // real file under Application Support, so it can't be pointed at an
    // in-memory queue here. This test instead exercises the exact predicate
    // `findTrackByPath` runs (DMQueries.swift): convert the incoming file
    // path to its stored form, then compare it against `Track.Columns.path`.
    // Before the fix, the method compared `Track.Columns.path == path`
    // directly against the caller-supplied absolute path, which never
    // matches a relatively-stored row.
    let dbQueue = try DatabaseQueue()
    try dbQueue.write { db in
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

    let storedPath = LibraryPathStore.storedPath(for: URL(fileURLWithPath: url.path))
    let found = try dbQueue.read { db in
        try Track.filter(Track.Columns.path == storedPath).fetchOne(db)
    }

    #expect(found?.url.standardizedFileURL == url.standardizedFileURL)
}
