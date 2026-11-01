import Foundation
import GRDB
@testable import Petrichor

/// A migrated `DatabaseManager` on a throwaway file, for tests of the `DM*`
/// extensions. The directory is the caller's to remove.
func makeTestDatabaseManager() throws -> (manager: DatabaseManager, directory: URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("petrichor-db-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return (try DatabaseManager(pool: makeTestDatabasePool(in: directory)), directory)
}

/// Inserts the library-root folder row once and returns its id.
func insertLibraryRootFolder(_ db: Database) throws -> Int64 {
    if let id = try Int64.fetchOne(db, sql: "SELECT id FROM folders WHERE path = ''") {
        return id
    }
    try Folder(url: LibraryPathStore.libraryRoot).insert(db)
    return db.lastInsertedRowID
}

/// A track row as the scanner would store it, before any normalization pass.
@discardableResult
func insertTestTrack(
    _ db: Database,
    file: String,
    title: String,
    artist: String,
    album: String = "Unknown Album",
    albumArtist: String? = nil,
    composer: String = "Unknown Composer",
    genre: String = "Unknown Genre",
    playCount: Int = 0,
    isDuplicate: Bool = false,
    albumId: Int64? = nil
) throws -> FullTrack {
    var track = FullTrack(url: LibraryPathStore.libraryRoot.appendingPathComponent(file))
    track.folderId = try insertLibraryRootFolder(db)
    track.title = title
    track.artist = artist
    track.album = album
    track.albumArtist = albumArtist
    track.composer = composer
    track.genre = genre
    track.playCount = playCount
    track.isDuplicate = isDuplicate
    track.albumId = albumId
    try track.insert(db)
    // `FullTrack` is a value record: `insert` cannot write the id back.
    track.trackId = db.lastInsertedRowID
    return track
}

/// Names of the artists linked to a track in `role`, in `position` order.
func linkedArtistNames(trackId: Int64, role: String, in db: Database) throws -> [String] {
    try String.fetchAll(
        db,
        sql: """
            SELECT artists.name FROM track_artists
            JOIN artists ON artists.id = track_artists.artist_id
            WHERE track_artists.track_id = ? AND track_artists.role = ?
            ORDER BY track_artists.position
            """,
        arguments: [trackId, role]
    )
}

/// Album-artist rows of an album as "role:name", in `position` order.
func albumArtistRows(albumId: Int64, in db: Database) throws -> [String] {
    try String.fetchAll(
        db,
        sql: """
            SELECT album_artists.role || ':' || artists.name FROM album_artists
            JOIN artists ON artists.id = album_artists.artist_id
            WHERE album_artists.album_id = ?
            ORDER BY album_artists.position
            """,
        arguments: [albumId]
    )
}
