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
/// `scanLibraryRoot()` itself isn't exercised end-to-end here: it goes through
/// `DatabaseManager.addFoldersAsync`, and `DatabaseManager` only exposes a
/// parameterless `init()` that opens a real file under Application Support
/// (see PathQueryTests.swift), so it can't be pointed at a throwaway database
/// in a unit test.

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
