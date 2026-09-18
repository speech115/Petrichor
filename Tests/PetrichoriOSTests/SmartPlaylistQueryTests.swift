import Foundation
import GRDB
import Testing
@testable import Petrichor

@Test func smartPlaylistQueriesPreserveSortingFilteringAndCounts() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try DatabaseManager(pool: makeTestDatabasePool(in: root))
    try await database.dbQueue.write { db in
        let folder = Folder(url: LibraryPathStore.libraryRoot)
        try folder.insert(db)
        let folderID = try #require(try Int64.fetchOne(db, sql: "SELECT id FROM folders LIMIT 1"))
        for (index, name) in ["C", "A", "B"].enumerated() {
            var track = FullTrack(url: LibraryPathStore.libraryRoot.appendingPathComponent("\(name).mp3"))
            track.folderId = folderID
            track.title = name
            track.artist = name
            track.album = name
            track.genre = name
            track.composer = name
            track.year = name
            track.playCount = Int(name.utf8.first!)
            track.duration = Double(track.playCount)
            track.trackNumber = track.playCount
            track.discNumber = track.playCount
            track.dateAdded = Date(timeIntervalSince1970: Double(track.playCount))
            track.lastPlayedDate = index == 0 ? nil : track.dateAdded
            track.dateFavorited = index == 0 ? nil : track.dateAdded
            try track.insert(db)
        }
    }
    let fields = ["title", "artist", "album", "playCount", "dateAdded", "duration",
                  "year", "genre", "trackNumber", "discNumber", "filename", "lastPlayedDate", "dateFavorited"]
    for field in fields {
        for ascending in [true, false] {
            let criteria = SmartPlaylistCriteria(sortBy: field, sortAscending: ascending)
            let tracks = try await database.getTracksForSmartPlaylist(Playlist(name: "Test", criteria: criteria), populateArtwork: false)
            let expected: [String]
            if field == "lastPlayedDate" {
                expected = ascending ? ["C", "A", "B"] : ["C", "B", "A"]
            } else if field == "dateFavorited" {
                expected = ascending ? ["C", "A", "B"] : ["B", "A", "C"]
            } else {
                expected = ascending ? ["A", "B", "C"] : ["C", "B", "A"]
            }
            #expect(tracks.map(\.title) == expected, "\(field), ascending=\(ascending)")
        }
    }
    for field in ["artist", "genre", "composer"] {
        for condition in [SmartPlaylistCriteria.Condition.equals, .contains, .startsWith, .endsWith, .regex] {
            let criteria = SmartPlaylistCriteria(rules: [.init(field: field, condition: condition, value: "a")])
            let playlist = Playlist(name: "Test", criteria: criteria)
            // REGEXP's case behavior is intentionally left to the existing SQL function.
            if condition != .regex {
                #expect(database.getTracksForSmartPlaylistSync(playlist, populateArtwork: false).map(\.title) == ["A"])
            }
            #expect(await database.countMatchesForCriteria(criteria) == database.getTracksForSmartPlaylistSync(playlist, populateArtwork: false).count)
        }
    }
    let limited = Playlist(name: "Limited", criteria: SmartPlaylistCriteria(limit: 2, sortBy: "title"))
    #expect(database.getTracksForSmartPlaylistSync(limited, populateArtwork: false).map(\.title) == ["A", "B"])
    #expect(await database.getSmartPlaylistTrackCounts([limited])[limited.id] == 2)
    #expect(await database.countMatchesForCriteria(limited.smartCriteria!) == 3)
    let invalidSort = Playlist(name: "Unknown", criteria: SmartPlaylistCriteria(sortBy: "title; DROP TABLE tracks"))
    #expect(database.getTracksForSmartPlaylistSync(invalidSort, populateArtwork: false).count == 3)
}
