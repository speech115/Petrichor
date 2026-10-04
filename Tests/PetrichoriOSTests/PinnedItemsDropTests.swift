import Foundation
import GRDB
import Testing
@testable import Petrichor

/// A database from before v10 still has `pinned_items` with `icon_name`, and
/// v10/v11 have not run. Those migrations no longer touch the table; v17 drops it.
@Test
func preV10DatabaseDropsPinnedItems() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let pool = try makeTestDatabasePool(in: root)

    try DatabaseMigrator.setupMigrator().migrate(pool, upTo: "v9_rebuild_artist_associations")
    try await pool.write { db in
        try db.execute(sql: """
            CREATE TABLE pinned_items (
                id INTEGER PRIMARY KEY AUTOINCREMENT, item_type TEXT NOT NULL, filter_type TEXT,
                filter_value TEXT, entity_id TEXT, artist_id INTEGER, album_id INTEGER, playlist_id TEXT,
                display_name TEXT NOT NULL, subtitle TEXT, icon_name TEXT, sort_order INTEGER NOT NULL DEFAULT 0,
                date_added DATETIME NOT NULL);
            CREATE INDEX idx_pinned_items_sort_order ON pinned_items(sort_order);
            CREATE INDEX idx_pinned_items_item_type ON pinned_items(item_type);
            INSERT INTO pinned_items (item_type, filter_type, filter_value, display_name, icon_name, date_added)
            VALUES ('library', 'albums', 'Title Only', 'Title Only', 'square.stack', CURRENT_TIMESTAMP);
            """)
    }

    try DatabaseMigrator.migrate(pool)

    let (leftovers, complete) = try await pool.read { db in
        (
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_master WHERE name LIKE '%pinned%'"),
            try DatabaseMigrator.setupMigrator().hasCompletedMigrations(db)
        )
    }
    #expect(leftovers == 0)
    #expect(complete)
}
