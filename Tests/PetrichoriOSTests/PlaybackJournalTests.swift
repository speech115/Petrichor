import Foundation
import Testing
@testable import Petrichor

@Test func playbackJournalEventRoundTripsThroughJSONL() throws {
    let played = PlaybackJournalEvent.played(
        path: "Моя музыка/Spotify/0239 - Jeune Ras.mp3",
        at: ISO8601DateFormatter().date(from: "2026-08-09T14:32:11Z")!
    )
    let favorite = PlaybackJournalEvent.favorite(
        path: "Моя музыка/Spotify/other.mp3",
        value: true,
        at: ISO8601DateFormatter().date(from: "2026-08-09T14:40:00Z")!
    )

    let playedLine = try PlaybackJournalCodec.encodeLine(played)
    let favoriteLine = try PlaybackJournalCodec.encodeLine(favorite)

    #expect(playedLine.contains("\"type\":\"played\""))
    #expect(playedLine.contains("Моя музыка/Spotify/0239 - Jeune Ras.mp3"))
    #expect(!playedLine.contains("\"value\""))
    #expect(favoriteLine.contains("\"type\":\"favorite\""))
    #expect(favoriteLine.contains("\"value\":true"))

    #expect(try PlaybackJournalCodec.decodeLine(playedLine) == played)
    #expect(try PlaybackJournalCodec.decodeLine(favoriteLine) == favorite)

    let blob = playedLine + "\n" + favoriteLine + "\n"
    #expect(try PlaybackJournalCodec.decodeLines(blob) == [played, favorite])
}

@Test func playbackJournalSuffixMatchingIsExactOrTrailing() {
    #expect(
        PlaybackJournalApply.matches(
            storedPath: "/Users/me/Music/Моя музыка/track.mp3",
            eventPath: "Моя музыка/track.mp3"
        )
    )
    #expect(
        PlaybackJournalApply.matches(
            storedPath: "Моя музыка/track.mp3",
            eventPath: "Моя музыка/track.mp3"
        )
    )
    #expect(
        !PlaybackJournalApply.matches(
            storedPath: "/Users/me/Music/other/track.mp3",
            eventPath: "Моя музыка/track.mp3"
        )
    )
    // Suffix without a path separator boundary must not match.
    #expect(
        !PlaybackJournalApply.matches(
            storedPath: "/Users/me/Music/prefixМоя музыка/track.mp3",
            eventPath: "Моя музыка/track.mp3"
        )
    )
}

@Test func playbackJournalApplyIsIdempotentWithCursor() {
    var tracks = [
        PlaybackJournalTrackState(
            path: "/Users/me/Music/Моя музыка/a.mp3",
            playCount: 2,
            isFavorite: false,
            lastPlayedDate: nil
        ),
        PlaybackJournalTrackState(
            path: "/Users/me/Music/Моя музыка/b.mp3",
            playCount: 0,
            isFavorite: false,
            lastPlayedDate: nil
        )
    ]

    let t1 = ISO8601DateFormatter().date(from: "2026-08-09T14:32:11Z")!
    let t2 = ISO8601DateFormatter().date(from: "2026-08-09T14:40:00Z")!
    let events = [
        PlaybackJournalEvent.played(path: "Моя музыка/a.mp3", at: t1),
        PlaybackJournalEvent.favorite(path: "Моя музыка/b.mp3", value: true, at: t2)
    ]

    let first = PlaybackJournalApply.apply(events: events, to: &tracks, cursor: nil)
    #expect(first.applied == 2)
    #expect(first.skipped == 0)
    #expect(first.cursor == t2)
    #expect(tracks[0].playCount == 3)
    #expect(tracks[0].lastPlayedDate == t1)
    #expect(tracks[1].isFavorite)

    let second = PlaybackJournalApply.apply(events: events, to: &tracks, cursor: first.cursor)
    #expect(second.applied == 0)
    #expect(second.skipped == 0)
    #expect(second.cursor == t2)
    #expect(tracks[0].playCount == 3)
    #expect(tracks[1].isFavorite)
}

@Test func playbackJournalApplySkipsAmbiguousAndMissingPaths() {
    var tracks = [
        PlaybackJournalTrackState(
            path: "/Users/me/Music/shared/track.mp3",
            playCount: 0,
            isFavorite: false,
            lastPlayedDate: nil
        ),
        PlaybackJournalTrackState(
            path: "/Users/other/Music/shared/track.mp3",
            playCount: 0,
            isFavorite: false,
            lastPlayedDate: nil
        )
    ]

    let ts = ISO8601DateFormatter().date(from: "2026-08-09T15:00:00Z")!
    let events = [
        PlaybackJournalEvent.played(path: "shared/track.mp3", at: ts),
        PlaybackJournalEvent.played(path: "missing/track.mp3", at: ts)
    ]

    let result = PlaybackJournalApply.apply(events: events, to: &tracks, cursor: nil)
    #expect(result.applied == 0)
    #expect(result.skipped == 2)
    #expect(tracks[0].playCount == 0)
    #expect(tracks[1].playCount == 0)
}

@Test func playbackJournalFavoriteLastWriteWins() {
    var tracks = [
        PlaybackJournalTrackState(
            path: "/Users/me/Music/a.mp3",
            playCount: 0,
            isFavorite: false,
            lastPlayedDate: nil
        )
    ]
    let t1 = ISO8601DateFormatter().date(from: "2026-08-09T15:00:00Z")!
    let t2 = ISO8601DateFormatter().date(from: "2026-08-09T16:00:00Z")!
    let events = [
        PlaybackJournalEvent.favorite(path: "a.mp3", value: true, at: t1),
        PlaybackJournalEvent.favorite(path: "a.mp3", value: false, at: t2)
    ]

    let result = PlaybackJournalApply.apply(events: events, to: &tracks, cursor: nil)
    #expect(result.applied == 2)
    #expect(!tracks[0].isFavorite)
}

@Test func playbackJournalPlayedUsesMaxLastPlayedDate() {
    let earlier = ISO8601DateFormatter().date(from: "2026-08-01T00:00:00Z")!
    let later = ISO8601DateFormatter().date(from: "2026-08-09T14:32:11Z")!
    var tracks = [
        PlaybackJournalTrackState(
            path: "/Users/me/Music/a.mp3",
            playCount: 1,
            isFavorite: false,
            lastPlayedDate: later
        )
    ]
    let events = [
        PlaybackJournalEvent.played(path: "a.mp3", at: earlier)
    ]

    _ = PlaybackJournalApply.apply(events: events, to: &tracks, cursor: nil)
    #expect(tracks[0].playCount == 2)
    #expect(tracks[0].lastPlayedDate == later)
}

@Test func playbackJournalApplierWritesDatabaseAndHonorsCursor() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("pj-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let pool = try makeTestDatabasePool(in: directory)
    let dbManager = try DatabaseManager(pool: pool)

    let relativePath = "Моя музыка/a.mp3"
    try pool.write { db in
        let folder = Folder(url: LibraryPathStore.libraryRoot)
        try folder.insert(db)
        guard let folderId = try Int64.fetchOne(db, sql: "SELECT id FROM folders ORDER BY id LIMIT 1") else {
            throw PlaybackJournalTestError.missingFolderID
        }

        let url = LibraryPathStore.libraryRoot.appendingPathComponent(relativePath)
        var track = FullTrack(url: url)
        track.folderId = folderId
        track.title = "A"
        track.artist = "Artist"
        track.album = "Album"
        track.playCount = 1
        track.isFavorite = false
        try track.insert(db)
    }

    let t1 = ISO8601DateFormatter().date(from: "2026-08-09T14:32:11Z")!
    let line = try PlaybackJournalCodec.encodeLine(
        .played(path: relativePath, at: t1)
    )
    let journalURL = directory.appendingPathComponent("playback-journal.jsonl")
    try (line + "\n").write(to: journalURL, atomically: true, encoding: .utf8)

    let first = try PlaybackJournalApplier.apply(
        fileURL: journalURL,
        databaseManager: dbManager
    )
    #expect(first.applied == 1)
    #expect(first.skipped == 0)

    let afterFirst = try pool.read { db in try Track.fetchOne(db) }
    #expect(afterFirst?.playCount == 2)
    #expect(afterFirst?.lastPlayedDate == t1)

    let second = try PlaybackJournalApplier.apply(
        fileURL: journalURL,
        databaseManager: dbManager
    )
    #expect(second.applied == 0)
    #expect(second.skipped == 0)
    let afterSecond = try pool.read { db in try Track.fetchOne(db) }
    #expect(afterSecond?.playCount == 2)
}

private enum PlaybackJournalTestError: Error {
    case missingFolderID
}


@Test @MainActor func journalWriterPreservesOrderAcrossConcurrentFlushesAndFailureRetry() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let journal = JSONLPlaybackJournal(documentsURL: root)
    let sync = root.appendingPathComponent("Sync")
    let file = sync.appendingPathComponent("playback-journal.jsonl")
    let date = Date(timeIntervalSince1970: 1_000)

    // Block the destination with a file, then verify the failed event survives.
    try Data().write(to: sync)
    journal.trackPlayed(relativePath: "first.mp3", at: date)
    await journal.flush()
    try FileManager.default.removeItem(at: sync)
    journal.favoriteChanged(relativePath: "first.mp3", value: true, at: date)
    await journal.flush()

    var expected: [PlaybackJournalEvent] = [
        .played(path: "first.mp3", at: date),
        .favorite(path: "first.mp3", value: true, at: date)
    ]
    var flushes: [Task<Void, Never>] = []
    for index in 0..<40 {
        let path = "\(index).mp3"
        journal.trackPlayed(relativePath: path, at: date)
        expected.append(.played(path: path, at: date))
        flushes.append(Task { await journal.flush() })
        await Task.yield()
    }
    for flush in flushes { await flush.value }
    #expect(try PlaybackJournalCodec.decodeLines(String(contentsOf: file, encoding: .utf8)) == expected)
    await journal.flush()
    #expect(try PlaybackJournalCodec.decodeLines(String(contentsOf: file, encoding: .utf8)) == expected)
}
