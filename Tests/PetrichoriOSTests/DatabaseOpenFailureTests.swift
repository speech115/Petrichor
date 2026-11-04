import Foundation
import Testing
@testable import Petrichor

/// A library database that does not open used to stop the app in
/// `fatalError`. `AppLaunch` now keeps the reason, retries on request and,
/// after confirmation on the iPhone, deletes the file and opens a new one.
/// The launch builds the bare database here, not an `AppCoordinator`: a
/// coordinator outlives the test and, on an empty library, clears the saved
/// playback state other tests set up.
@MainActor
struct DatabaseOpenFailureTests {
    @Test func damagedFileShowsTheErrorAndResetOpensAnEmptyLibrary() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("db-open-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("petrichor.db")
        let damaged = Data(repeating: 0xAB, count: 8192)
        try damaged.write(to: url)
        try Data([0x01]).write(to: URL(fileURLWithPath: url.path + "-wal"))

        var built = 0
        var resetDatabases: [DatabaseManager] = []
        let launch = AppLaunch(
            openDatabase: { try DatabaseManager(pool: DatabaseFactory.makePool(at: url)) },
            removeDatabase: { try DatabaseFactory.removeDatabaseFiles(at: url) },
            build: { database in
                built += 1
                return database
            },
            didReset: { resetDatabases.append($0) }
        )
        #expect(launch.running == nil)
        #expect(launch.databaseError?.isEmpty == false)

        // Retrying leaves a damaged file damaged: still the error, nothing deleted.
        launch.openLibrary()
        #expect(launch.running == nil)
        #expect(launch.databaseError?.isEmpty == false)
        #expect(try Data(contentsOf: url) == damaged)
        #expect(built == 0)
        #expect(resetDatabases.isEmpty)

        launch.resetLibraryDatabase()
        let database = try #require(launch.running)
        #expect(launch.databaseError == nil)
        #expect(built == 1)
        // Row ids restart from 1 in the new file: whatever is keyed by the old
        // ids (the iOS Spotlight snapshot) must hear about the reset.
        #expect(resetDatabases.count == 1)
        #expect(resetDatabases.first === database)
        #expect(try database.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks")
        } == 0)
    }

    @Test func retryOpensTheDatabaseOnceTheCauseIsGone() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("db-open-retry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // The folder is missing, so the first open throws, as on a full or
        // unavailable disk; nothing is deleted to recover from it.
        let url = directory.appendingPathComponent("petrichor.db")
        var removals = 0
        var resets = 0
        let launch = AppLaunch(
            openDatabase: { try DatabaseManager(pool: DatabaseFactory.makePool(at: url)) },
            removeDatabase: { removals += 1 },
            build: { $0 },
            didReset: { _ in resets += 1 }
        )
        #expect(launch.running == nil)
        #expect(launch.databaseError?.isEmpty == false)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        launch.openLibrary()
        #expect(launch.running != nil)
        #expect(launch.databaseError == nil)
        #expect(removals == 0)
        #expect(resets == 0)
    }
}
