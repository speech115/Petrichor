import Foundation
import GRDB
import Testing
@testable import Petrichor

/// Covers what `LibraryManager.scanLibraryRoot()` (Managers/Library/LMFolders.swift)
/// depends on, without touching the app's actual sandboxed filesystem: the extension
/// list the scan pipeline treats as audio, and the fact that registering the library
/// root itself as a `Folder` stores a relative path rather than an absolute,
/// container-specific one.
///
/// The scan pipeline `scanLibraryRoot()` drives — `addFoldersAsync` →
/// `scanFoldersForTracks` → metadata extraction → duplicate detection — is
/// exercised end-to-end below against a throwaway temp pool and temp folder
/// (possible since `DatabaseManager(pool:)` was introduced), without touching
/// the app's real Application Support database.

@Test func audioFormatSupportedExtensionsAreLowercasedAndNonEmpty() {
    let extensions = AudioFormat.supportedExtensions

    #expect(!extensions.isEmpty)
    #expect(extensions.contains("mp3"))
    #expect(extensions.allSatisfy { $0 == $0.lowercased() })

    // Formats the engine deliberately excludes must never show up here, on
    // either platform's metadata backend.
    let excluded = Set(AudioFormat.unsupportedExtensions).union(AudioFormat.withheldExtensions)
    #expect(Set(extensions).isDisjoint(with: excluded))

    // NOTE: as of this commit the iOS metadata backend (AVAssetMetadataReader)
    // only claims "mp3" — m4a/flac/etc. are not yet in
    // `AudioFormat.supportedExtensions` on iOS. Widening that list is Task 8
    // (metadata via AVAsset), not this task, so this test only asserts what is
    // true today rather than the fuller format list a future task will add.
}

@Test func libraryRootFolderRegistersWithARelativeStoredPath() throws {
    let dbQueue = try DatabaseQueue()
    try dbQueue.write { db in
        try db.create(table: "folders") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("path", .text).notNull().unique()
            t.column("name", .text).notNull()
            t.column("track_count", .integer).notNull()
            t.column("date_added", .datetime).notNull()
            t.column("date_updated", .datetime).notNull()
            t.column("bookmark_data", .blob)
            t.column("shasum_hash", .text)
        }
    }

    // This mirrors what `LibraryManager.scanLibraryRoot()` registers: the
    // library root itself, not a subfolder of it.
    let folder = Folder(url: LibraryPathStore.libraryRoot)
    try dbQueue.write { db in try folder.insert(db) }

    let storedPath = try dbQueue.read { db in
        try String.fetchOne(db, sql: "SELECT path FROM folders LIMIT 1")
    }
    #expect(storedPath == "")
    #expect(storedPath?.hasPrefix("/") == false)

    let loaded = try dbQueue.read { db in try Folder.fetchOne(db) }
    #expect(loaded?.url.standardizedFileURL == LibraryPathStore.libraryRoot.standardizedFileURL)
}

/// Seam test «сборка библиотеки из папки» (design spec, пункт 4): the real
/// scan pipeline — `addFoldersAsync` → `scanFoldersForTracks` → metadata
/// extraction → insert → duplicate detection — against a throwaway temp pool
/// and a temp folder. Impossible before `DatabaseManager(pool:)`: the
/// parameterless init opened a real file under Application Support (see the
/// header comment above), so these tests had to re-implement the predicates
/// instead of calling the production code.
@Test func scanningTempFolderAssemblesLibraryIntoInMemoryPool() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("petrichor-scan-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    // Two tagged tracks sharing an album, plus an exact copy of the first in a
    // subfolder — the duplicate-detection pass must mark the copy, and the
    // grouping pass must land both tracks on one album row.
    let album = "Scanner Test Album"
    let first = try makeSilentMP3(artist: "Annabel", title: "Above Your Hand", album: album)
    let second = try makeSilentMP3(artist: "Jeune Ras", title: "Hidden Gem", album: album)
    defer {
        try? FileManager.default.removeItem(at: first)
        try? FileManager.default.removeItem(at: second)
    }
    let firstInLibrary = root.appendingPathComponent("Annabel - Above Your Hand.mp3")
    let secondInLibrary = root.appendingPathComponent("Jeune Ras - Hidden Gem.mp3")
    try FileManager.default.moveItem(at: first, to: firstInLibrary)
    try FileManager.default.moveItem(at: second, to: secondInLibrary)
    let copyDir = root.appendingPathComponent("copy", isDirectory: true)
    try FileManager.default.createDirectory(at: copyDir, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: firstInLibrary, to: copyDir.appendingPathComponent("Annabel - Above Your Hand.mp3"))

    // Deterministic metadata: the simulator's media service is shared and
    // flakes under parallel load, so the scan pipeline gets a fixed reader.
    MetadataEngine.readerOverride = TestMetadataReader.shared
    TestMetadataReader.shared.setOverride(for: firstInLibrary, artist: "Annabel", title: "Above Your Hand", album: album)
    TestMetadataReader.shared.setOverride(for: secondInLibrary, artist: "Jeune Ras", title: "Hidden Gem", album: album)
    TestMetadataReader.shared.setOverride(
        for: copyDir.appendingPathComponent("Annabel - Above Your Hand.mp3"),
        artist: "Annabel", title: "Above Your Hand", album: album
    )

    let databaseManager = try DatabaseManager(pool: makeTestDatabasePool(in: root))
    _ = try await databaseManager.addFoldersAsync([root], bookmarkDataMap: [:])

    // All three files made it through the scan as tracks.
    let tracks = databaseManager.getTracksRespectingDuplicates(hideDuplicates: false)
    #expect(tracks.count == 3)
    #expect(Set(tracks.map { $0.url.lastPathComponent }) == [
        "Annabel - Above Your Hand.mp3",
        "Jeune Ras - Hidden Gem.mp3"
    ])

    // The byte-identical copy is marked as a duplicate; the original is not.
    let duplicates = tracks.filter { $0.isDuplicate }
    #expect(duplicates.count == 1)

    // Grouping: both non-duplicate tracks resolve into one album row and
    // their artists are registered.
    let albumCount = try await databaseManager.dbQueue.read { db in
        try Album.filter(Album.Columns.title == album).fetchCount(db)
    }
    #expect(albumCount == 1)

    let artistNames = try await databaseManager.dbQueue.read { db in
        try Artist.select(Artist.Columns.name).asRequest(of: String.self).fetchAll(db)
    }
    // The album's two real artists are registered. The compilation pass may
    // also add a "Various Artists" row for a multi-artist album — production
    // behavior, not something the test should pin down.
    #expect(Set(artistNames).isSuperset(of: ["Annabel", "Jeune Ras"]))
}

/// Seam test «строки пропавших файлов переживают полный скан» (ADR-0001):
/// a track whose file disappears from disk keeps its database row through a
/// full rescan. This is the exact flow iOS reconciliation runs — the app's
/// Documents folder is re-registered and rescanned on every launch/foreground
/// (LibraryManager.scanLibraryRoot / reconcileLibrary), and the scan must
/// never delete rows for files that are no longer there.
@Test func missingFileKeepsItsRowThroughARescan() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("petrichor-rescan-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let first = try makeSilentMP3(artist: "Annabel", title: "Above Your Hand", album: "Rescan Test Album")
    let second = try makeSilentMP3(artist: "Jeune Ras", title: "Hidden Gem", album: "Rescan Test Album")
    let firstInLibrary = root.appendingPathComponent("Annabel - Above Your Hand.mp3")
    let secondInLibrary = root.appendingPathComponent("Jeune Ras - Hidden Gem.mp3")
    try FileManager.default.moveItem(at: first, to: firstInLibrary)
    try FileManager.default.moveItem(at: second, to: secondInLibrary)

    // Deterministic metadata: the simulator's media service is shared and
    // flakes under parallel load, so the scan pipeline gets a fixed reader.
    MetadataEngine.readerOverride = TestMetadataReader.shared

    let databaseManager = try DatabaseManager(pool: makeTestDatabasePool(in: root))
    _ = try await databaseManager.addFoldersAsync([root], bookmarkDataMap: [:])

    #expect(databaseManager.getTracksRespectingDuplicates(hideDuplicates: false).count == 2)

    // The file disappears from disk (user deleted it in Files, iCloud evicted
    // it, an external drive was unplugged). The row must survive the rescan.
    try FileManager.default.removeItem(at: firstInLibrary)

    // Re-registering the same folder row and rescanning is what
    // scanLibraryRoot() does on every reconciliation.
    _ = try await databaseManager.addFoldersAsync([root], bookmarkDataMap: [:])

    let tracks = databaseManager.getTracksRespectingDuplicates(hideDuplicates: false)
    #expect(tracks.count == 2)
    #expect(Set(tracks.map { $0.url.lastPathComponent }) == [
        "Annabel - Above Your Hand.mp3",
        "Jeune Ras - Hidden Gem.mp3"
    ])
}
