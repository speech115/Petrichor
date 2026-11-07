import Foundation
import GRDB
import Testing
@testable import Petrichor

// Regressions for SM-5 (docs/state-machines.md): a scan request that arrives
// while a scan of the library root is running must not be dropped (I-5.2).
// The scan walks the real `Documents` root but writes into a throwaway
// database, so the app's own library is untouched. The running scan is held
// on one of its files (`TestMetadataReader.hold`), so the overlap is certain
// rather than a matter of timing.

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

    // A file of the running scan holds it after it has listed the library
    // root and before it finishes, so the import's copy lands too late for it.
    let blocker = LibraryPathStore.libraryRoot.appendingPathComponent("ScanHold-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: blocker) }
    let blockerName = "Hold - \(UUID().uuidString).mp3"
    try FileManager.default.moveItem(at: try makeSilentMP3(), to: blocker.appendingPathComponent(blockerName))
    TestMetadataReader.shared.hold(fileNamed: blockerName)
    defer { TestMetadataReader.shared.release(fileNamed: blockerName) }

    let runningScan = Task { try await library.scanLibraryRoot() }
    let deadline = ContinuousClock.now + .seconds(10)
    while !TestMetadataReader.shared.isWaiting(onFileNamed: blockerName), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    try #require(TestMetadataReader.shared.isWaiting(onFileNamed: blockerName), "the first scan never reached its held file")

    let importing = Task { try await library.importMusicFiles([source]) }
    // Release the held scan only once the import has copied its file, so the
    // first scan cannot have listed it.
    let imports = LibraryPathStore.libraryRoot.appendingPathComponent("Imports", isDirectory: true)
    let copied = { () -> Bool in
        let batches = (try? FileManager.default.contentsOfDirectory(at: imports, includingPropertiesForKeys: nil)) ?? []
        return batches.contains { FileManager.default.fileExists(atPath: $0.appendingPathComponent(fileName).path) }
    }
    while !copied(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    try #require(copied(), "the import never copied its file")
    try await Task.sleep(for: .milliseconds(200))
    TestMetadataReader.shared.release(fileNamed: blockerName)

    _ = try await importing.value
    let imported = try await library.databaseManager.dbQueue.read { db in
        try Track.filter(Track.Columns.title == title).fetchOne(db)
    }
    _ = try? await runningScan.value

    #expect(imported != nil, "the import's scan was dropped while another scan ran")
}
