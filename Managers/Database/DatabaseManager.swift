//
// DatabaseManager class
//
// This class handles all the Database operations done by the app, note that this file only
// contains core methods, the domain-specific logic is spread across extension files within this
// directory where each file is prefixed with `DM`.
//

import Foundation
import GRDB

/// Pure `DatabasePool` wrapper. All mutable state lives either inside the
/// thread-safe pool or in `scanActivity` (a main-actor observation object),
/// so the manager itself is `Sendable` and can be captured freely by
/// background scan tasks.
final class DatabaseManager: Sendable {
    // MARK: - Properties

    // A pool, not a single serial queue: readers run concurrently with the
    // writer under WAL, so a library scan or reconciliation writing tracks no
    // longer starves the UI reads that populate lists (the "No Tracks while
    // scanning" stall). The property keeps the `dbQueue` name because it is
    // referenced across dozens of `DM*` extension files.
    let dbQueue: DatabasePool

    /// Main-actor observation of library scan activity (`isScanning`,
    /// `scanStatusMessage`, progress throttle). DM* scan code publishes
    /// through it; the UI mirrors it onto `LibraryManager`'s published
    /// surface.
    let scanActivity = ScanActivityObservation()

    // MARK: - Initialization

    /// Core init: принимает готовый пул. Тесты передают in-memory
    /// `DatabasePool()`; прод-пул собирает `DatabaseFactory` (путь к файлу
    /// и PRAGMA-конфиг живут там, у вызывающей стороны).
    init(pool: DatabasePool) throws {
        // A pool (concurrent readers + one writer under WAL) rather than a
        // serial queue, so UI reads are not blocked behind scan writes.
        dbQueue = pool

        // Use migration system for both new and existing databases
        try DatabaseMigrator.migrate(dbQueue)
    }

    /// Прод-пул: файловая база под Application Support.
    convenience init() throws {
        try self.init(pool: DatabaseFactory.makeApplicationSupportPool())
    }

    // MARK: - Database Maintenance

    func checkpoint() {
        do {
            try dbQueue.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
            }
            Logger.info("WAL checkpoint completed")
        } catch {
            Logger.error("WAL checkpoint failed: \(error)")
        }
    }

    // MARK: - Migration Status
    
    /// Check if database needs migration
    func needsMigration() -> Bool {
        DatabaseMigrator.hasUnappliedMigrations(dbQueue)
    }
    
    /// Get list of applied migrations
    func getAppliedMigrations() -> [String] {
        DatabaseMigrator.appliedMigrations(dbQueue)
    }

    // MARK: - Helper Methods
    
/// Clean up database file and recreate schema
    /// Warning: This will delete all data!
    func resetDatabase() throws {
        Task { @MainActor in
            self.scanActivity.finishScan()
        }

        // Erase the database
        try dbQueue.erase()
        
        // Re-run migrations on the fresh database
        try DatabaseMigrator.migrate(dbQueue)

        // Re-running migrations re-seeds the one-time background "optimization" jobs
        // as pending, but this fresh DB is at the latest schema and anything scanned
        // later is already ingested in optimized form. Mark them complete so a
        // reset -> add-folders flow skips a pointless "Optimizing Library..." pass.
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE background_migrations SET completed_at = ?, progress = NULL WHERE completed_at IS NULL",
                arguments: [Date()]
            )
        }

        Logger.info("Database reset completed")
    }
    
    /// Vacuum the database to reclaim space
    func vacuumDatabase() async throws {
        try await dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM")
        }
        Logger.info("Database vacuum completed")
    }
    
    /// Analyze the database to update statistics
    func analyzeDatabase() async throws {
        try await dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "ANALYZE")
        }
        Logger.info("Database analyze completed")
    }
}

// MARK: - Local Enums

enum TrackProcessResult {
    case new(FullTrack, TrackMetadata)
    case update(FullTrack, TrackMetadata)
    case skipped
}

enum DatabaseError: Error {
    case invalidTrackId
    case invalidFolderId
    case updateFailed
    case migrationFailed(String)
    case scanFailed(String)
    
    var localizedDescription: String {
        switch self {
        case .invalidTrackId:
            return "Invalid track ID"
        case .invalidFolderId:
            return "Invalid folder ID"
        case .updateFailed:
            return "Failed to update database"
        case .migrationFailed(let message):
            return "Migration failed: \(message)"
        case .scanFailed(let message):
            return "Scan failed: \(message)"
        }
    }
}

// MARK: - Array Extension

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}

extension Array where Element: Hashable {
    func removingDuplicates() -> [Element] {
        var seen = Set<Element>()
        return self.filter { element in
            guard !seen.contains(element) else { return false }
            seen.insert(element)
            return true
        }
    }
}

// MARK: - String Extension

extension String {
    var nilIfEmpty: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}
