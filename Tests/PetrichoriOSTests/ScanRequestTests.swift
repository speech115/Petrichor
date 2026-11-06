import Foundation
import GRDB
import Testing
@testable import Petrichor

// Regressions for SM-5 (docs/state-machines.md): a scan request that arrives
// while a scan of the library root is running must not be dropped (I-5.2).
// The scan walks the real `Documents` root but writes into a throwaway
// database, so the app's own library is untouched.

@MainActor
@Test func importDuringARunningScanIsInTheLibraryWhenImportReturns() async throws {
    MetadataEngine.readerOverride = TestMetadataReader.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let library = LibraryManager(
        databaseManager: try DatabaseManager(pool: makeTestDatabasePool(in: root)),
        deferLaunchWork: true
    )
    let title = "Imported \(UUID().uuidString)"
    let fileName = "Importer - \(title).mp3"
    let source = root.appendingPathComponent(fileName)
    try FileManager.default.moveItem(at: try makeSilentMP3(), to: source)
    defer {
        // `importMusicFiles` copies into `Documents/Imports/<uuid>/`.
        let imports = LibraryPathStore.libraryRoot.appendingPathComponent("Imports", isDirectory: true)
        let batches = (try? FileManager.default.contentsOfDirectory(at: imports, includingPropertiesForKeys: nil)) ?? []
        for batch in batches where FileManager.default.fileExists(atPath: batch.appendingPathComponent(fileName).path) {
            try? FileManager.default.removeItem(at: batch)
        }
    }

    let runningScan = Task { try await library.scanLibraryRoot() }
    let deadline = ContinuousClock.now + .seconds(5)
    while !library.isScanningLibraryRoot, ContinuousClock.now < deadline {
        await Task.yield()
    }
    try #require(library.isScanningLibraryRoot, "the first scan never started")

    _ = try await library.importMusicFiles([source])

    let imported = try await library.databaseManager.dbQueue.read { db in
        try Track.filter(Track.Columns.title == title).fetchOne(db)
    }
    _ = try? await runningScan.value

    #expect(imported != nil, "the import's scan was dropped while another scan ran")
}
