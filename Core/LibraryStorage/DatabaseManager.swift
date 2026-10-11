// Rust owns SQLite connections and transactions. Swift retains model decoding and scan presentation.
import Foundation
import GRDB
import PetrichorCore

/// Mutable storage lives behind Rust's serialized writer and independent WAL readers.
final class DatabaseManager: Sendable {
    let core: LibraryDatabase
    let scanActivity = ScanActivityObservation()

    init(path: String) throws {
        core = try LibraryDatabase.open(path: path)
    }

    convenience init() throws {
        try self.init(path: DatabaseFactory.databaseURL(createDirectory: true).path)
    }

    func checkpoint() {
        do { try core.checkpoint() } catch { Logger.error("WAL checkpoint failed: \(error)") }
    }

    func resetDatabase() throws {
        try core.reset(now: Date().timeIntervalSince1970)
        Task { @MainActor in self.scanActivity.finishScan() }
        Logger.info("Database reset completed")
    }

    func vacuumDatabase() async throws {
        try core.vacuum()
        Logger.info("Database vacuum completed")
    }

    func analyzeDatabase() async throws {
        try core.analyze()
        Logger.info("Database analyze completed")
    }

    func rows(_ result: DatabaseRows) throws -> [Row] {
        guard Set(result.columns).count == result.columns.count else {
            throw DatabaseError.scanFailed("Duplicate database columns")
        }
        return try result.rows.map { cells in
            guard cells.count == result.columns.count else {
                throw DatabaseError.scanFailed("Invalid database row width")
            }
            let values: [DatabaseValue] = cells.map { cell in
                switch cell {
                case .null: return .null
                case let .integer(value): return value.databaseValue
                case let .real(value): return value.databaseValue
                case let .text(value): return value.databaseValue
                case let .blob(value): return value.databaseValue
                }
            }
            return Row(Dictionary(uniqueKeysWithValues: zip(result.columns, values)))
        }
    }

    func records<T: FetchableRecord>(_ result: DatabaseRows, as type: T.Type) throws -> [T] {
        try rows(result).map { try T(row: $0) }
    }
}

// MARK: - Local Enums

enum DatabaseError: Error {
    case invalidTrackId
    case invalidFolderId
    case scanFailed(String)
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
