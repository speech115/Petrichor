import Foundation
import GRDB
import Testing
@testable import Petrichor

/// Regression harness «петля замера» (ticket 01, снято в тикете 08): seeds a
/// database directly (no file scan) — 100 albums with ~10 KB thumbnails,
/// 1500 tracks, one playlist with 1200 positions — and asserts the invariants
/// the playlist screens rely on. During the perf phase (tickets 01–07) it
/// also printed timing medians; those prints were removed here.
///
/// The fixture intentionally has no duplicate track in the playlist: the
/// schema forbids it (composite PK `(playlist_id, track_id)` in
/// `DMSetup.createPlaylistTracksTable` + `onConflict: .ignore` in
/// `PlaylistTrack.insertMany`), so 1200 positions mean 1200 unique tracks.
@Test func playlistLoadTimingOnSeededDatabase() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("petrichor-perf-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let dbManager = try DatabaseManager(pool: makeTestDatabasePool(in: root))
    let playlistID = try seedPerfDatabase(dbManager)

    // Correctness first: 1200 tracks, position order preserved, no duplicate
    // trackIds (schema guarantee, asserted anyway), thumbnails filled.
    let expectedOrder: [Int64] = try dbManager.dbQueue.read { db in
        try Int64.fetchAll(db, sql: "SELECT id FROM tracks ORDER BY id LIMIT 1200")
    }
    #expect(expectedOrder.count == 1200)

    for _ in 0..<5 {
        var tracks = dbManager.loadTracksForPlaylist(playlistID, populateArtwork: false)
        dbManager.populateAlbumArtworkThumbnailsForTracks(&tracks)

        #expect(tracks.count == 1200)
        #expect(tracks.compactMap { $0.trackId } == expectedOrder)
        #expect(Set(tracks.compactMap { $0.trackId }).count == 1200)
        #expect(tracks.allSatisfy { $0.albumArtworkThumbnail != nil })
    }
}

// MARK: - Seeding

private func seedPerfDatabase(_ dbManager: DatabaseManager) throws -> UUID {
    try dbManager.dbQueue.write { db in
        let thumbnail = Data((0..<10_000).map { _ in UInt8.random(in: 0...255) })

        // Tracks.folder_id is NOT NULL, so a Folder row comes first (the
        // library root, exactly like the iOS scan registers it).
        let folder = Folder(url: LibraryPathStore.libraryRoot)
        try folder.insert(db)
        guard let folderId = try Int64.fetchOne(db, sql: "SELECT id FROM folders ORDER BY id LIMIT 1") else {
            throw TestSeedError.missingFolderID
        }

        var albumIDs: [Int64] = []
        for albumIndex in 0..<100 {
            let album = Album(title: "Perf Album \(albumIndex)")
            album.artworkThumbnail = thumbnail
            try album.insert(db)
            albumIDs.append(album.id!)
        }

        for trackIndex in 0..<1500 {
            let albumIndex = trackIndex / 15
            let relativePath = "Music/Perf Album \(albumIndex)/\(String(format: "%04d", trackIndex)).mp3"
            let url = LibraryPathStore.libraryRoot.appendingPathComponent(relativePath)
            var track = FullTrack(url: url)
            track.folderId = folderId
            track.title = "Track \(trackIndex)"
            track.artist = "Artist \(albumIndex)"
            track.album = "Perf Album \(albumIndex)"
            track.albumId = albumIDs[albumIndex]
            try track.insert(db)
        }

        let playlist = Playlist(name: "Perf Big Playlist")
        try playlist.insert(db)

        let trackIds: [Int64] = try Int64.fetchAll(db, sql: "SELECT id FROM tracks ORDER BY id LIMIT 1200")
        let now = Date()
        let rows: [PlaylistTrack] = trackIds.enumerated().map { position, trackId in
            PlaylistTrack(
                playlistId: playlist.id.uuidString,
                trackId: trackId,
                position: position,
                dateAdded: now.addingTimeInterval(TimeInterval(position))
            )
        }
        try PlaylistTrack.insertMany(rows, db: db)

        return playlist.id
    }
}

private enum TestSeedError: Error {
    case missingFolderID
}
