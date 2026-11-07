import Foundation
import GRDB
import Testing
@testable import Petrichor

// Regressions for SM-7 (docs/state-machines.md): no listen is lost, whether
// it is counted here or arrives in the other device's journal (I-7.3, I-7.4).
// Both run against a throwaway database.

@MainActor
private func makeLibrary(in root: URL) throws -> LibraryManager {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return LibraryManager(
        databaseManager: try DatabaseManager(pool: makeTestDatabasePool(in: root)),
        deferLaunchWork: true
    )
}

@MainActor
private func playCount(of title: String, in library: LibraryManager) throws -> Int? {
    try library.databaseManager.dbQueue.read { db in
        try Track.filter(Track.Columns.title == title).fetchOne(db)?.playCount
    }
}

/// I-7.4: two finishes counted back to back (or a finish racing the journal
/// applier) both land; the read-then-write increment kept only one.
@MainActor
@Test func backToBackFinishesBothCount() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try makeLibrary(in: root)
    let playlists = PlaylistManager()
    playlists.setLibraryManager(library)

    let title = "Counted \(UUID().uuidString)"
    let track = try await library.databaseManager.dbQueue.write { db -> Track in
        try Folder(url: root).insert(db)
        var full = FullTrack(url: root.appendingPathComponent("counted.mp3"))
        full.folderId = db.lastInsertedRowID
        full.title = title
        try full.insert(db)
        return try #require(try Track.filter(Track.Columns.trackId == db.lastInsertedRowID).fetchOne(db))
    }

    playlists.incrementPlayCount(for: track)
    playlists.incrementPlayCount(for: track)

    let deadline = ContinuousClock.now + .seconds(5)
    while try playCount(of: title, in: library) != 2, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(try playCount(of: title, in: library) == 2, "one of two listens was lost")
}

/// I-7.3: a listen the Mac journaled for a file that reaches the phone in the
/// same sync counts once the reconciliation that scans the file is done.
/// Applying the journal before that scan skipped the event and moved the
/// cursor past it for good.
@MainActor
@Test func reconciliationAppliesThePeerJournalToFilesItJustScanned() async throws {
    MetadataEngine.readerOverride = TestMetadataReader.shared
    let databaseRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: databaseRoot) }
    let library = try makeLibrary(in: databaseRoot)

    let folderName = "journal-\(UUID().uuidString)"
    let folder = LibraryPathStore.libraryRoot.appendingPathComponent(folderName, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let title = "Synced \(UUID().uuidString)"
    let fileName = "Mac - \(title).mp3"
    try FileManager.default.moveItem(at: try makeSilentMP3(), to: folder.appendingPathComponent(fileName))

    let inbox = PlaybackJournalFiles.inbox
    let oldInbox = try? Data(contentsOf: inbox)
    defer {
        if let oldInbox {
            try? oldInbox.write(to: inbox)
        } else {
            try? FileManager.default.removeItem(at: inbox)
        }
    }
    try FileManager.default.createDirectory(at: inbox.deletingLastPathComponent(), withIntermediateDirectories: true)
    let macPath = "/Users/me/Music/Моя музыка/\(folderName)/\(fileName)"
    let line = try PlaybackJournalCodec.encodeLine(.played(path: macPath, at: Date()))
    try (line + "\n").write(to: inbox, atomically: true, encoding: .utf8)

    try await library.reconcileLibrary()

    #expect(try playCount(of: title, in: library) == 1, "the Mac's listen of a newly synced file was lost")
}
