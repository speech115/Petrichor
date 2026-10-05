//
// DatabaseMigration.swift
//
// This file contains the database migration infrastructure for Petrichor
// using GRDB's built-in migration system.
//

import Foundation
import GRDB

/// Manages database migrations using GRDB's built-in migration system
enum DatabaseMigrator {
    // swiftlint:disable function_body_length
    /// Creates and configures the database migrator with all migrations
    static func setupMigrator() -> GRDB.DatabaseMigrator {
        var migrator = GRDB.DatabaseMigrator()
        
        // MARK: - Initial Schema Migration
        migrator.registerMigration("v1_initial_schema") { db in
            // Check if this is a fresh database by looking for core tables
            let tracksExist = try db.tableExists("tracks")
            let foldersExist = try db.tableExists("folders")
            let artistsExist = try db.tableExists("artists")
            
            let tablesExist = tracksExist || foldersExist || artistsExist
            
            if !tablesExist {
                // Fresh database - create initial schema using static setup methods
                try DatabaseManager.setupDatabaseSchema(in: db)
            } else {
                // Existing database - this is our baseline
                Logger.info("Existing database detected, marking as v1 baseline")
            }
        }
        
        migrator.registerMigration("v2_add_folder_content_hash") { db in
            try db.alter(table: "folders") { t in
                t.add(column: "shasum_hash", .text)
            }
            Logger.info("Added shasum_hash column to folders table")
        }
        
        migrator.registerMigration("v3_add_category_query_indices") { db in
            // Composite index for track_artists queries (role + artist_id for faster joins)
            try db.createIndexIfNotExists(
                name: "idx_track_artists_role_artist",
                table: "track_artists",
                columns: ["role", "artist_id", "track_id"]
            )
            
            // Composite indices for duplicate-aware queries
            try db.createIndexIfNotExists(name: "idx_tracks_duplicate_artist", table: "tracks", columns: ["is_duplicate", "artist"])
            try db.createIndexIfNotExists(name: "idx_tracks_duplicate_album_artist", table: "tracks", columns: ["is_duplicate", "album_artist"])
            try db.createIndexIfNotExists(name: "idx_tracks_duplicate_composer", table: "tracks", columns: ["is_duplicate", "composer"])
            try db.createIndexIfNotExists(name: "idx_tracks_duplicate_genre", table: "tracks", columns: ["is_duplicate", "genre"])
            try db.createIndexIfNotExists(name: "idx_tracks_duplicate_year", table: "tracks", columns: ["is_duplicate", "year"])
            
            // Composite index for album_artists primary artist lookups
            try db.createIndexIfNotExists(
                name: "idx_album_artists_primary",
                table: "album_artists",
                columns: ["role", "position", "album_id", "artist_id"]
            )
            
            // Entity query optimization indices
            try db.createIndexIfNotExists(name: "idx_artists_name_normalized", table: "artists", columns: ["name", "normalized_name"])
            try db.createIndexIfNotExists(
                name: "idx_tracks_album_id_duplicate",
                table: "tracks",
                columns: ["album_id", "is_duplicate", "disc_number", "track_number"]
            )
            try db.createIndexIfNotExists(
                name: "idx_tracks_album_name_artist",
                table: "tracks",
                columns: ["album", "album_artist", "is_duplicate", "disc_number", "track_number"]
            )
            
            Logger.info("Created all indices")
            
            // Recalculate artist track counts with updated scope
            Logger.info("Recalculating artist track counts with updated scope...")
            
            let artistIds = try Artist
                .select(Artist.Columns.id, as: Int64.self)
                .fetchAll(db)
            
            var updatedCount = 0
            for artistId in artistIds {
                let trackCount = try TrackArtist
                    .joining(required: TrackArtist.track.filter(Track.Columns.isDuplicate == false))
                    .filter(TrackArtist.Columns.artistId == artistId)
                    .filter(TrackArtist.Columns.role == TrackArtist.Role.artist)
                    .select(TrackArtist.Columns.trackId, as: Int64.self)
                    .distinct()
                    .fetchCount(db)
                
                try db.execute(
                    sql: "UPDATE artists SET total_tracks = ? WHERE id = ?",
                    arguments: [trackCount, artistId]
                )
                updatedCount += 1
            }
            
            Logger.info("v3_add_category_query_indices migration completed")
        }
        
        migrator.registerMigration("v4_rebuild_fts_with_unicode61_tokenizer") { db in
            Logger.info("Rebuilding FTS table with unicode tokenization without porter stemming...")
            
            // Drop existing FTS triggers
            try db.execute(sql: "DROP TRIGGER IF EXISTS tracks_fts_insert")
            try db.execute(sql: "DROP TRIGGER IF EXISTS tracks_fts_update")
            try db.execute(sql: "DROP TRIGGER IF EXISTS tracks_fts_delete")
            
            // Drop existing FTS table
            try db.execute(sql: "DROP TABLE IF EXISTS tracks_fts")
            
            // Recreate FTS table with unicode61 tokenizer without porter stemming
            try DatabaseManager.createFTSTable(in: db)
            
            Logger.info("v4_rebuild_fts_with_unicode61_tokenizer migration completed")
        }
        
        migrator.registerMigration("v5_add_lossless_column") { db in
            try db.alter(table: "tracks") { t in
                t.add(column: "lossless", .boolean)
            }
            Logger.info("v5_add_lossless_column migration completed")
        }
        
        migrator.registerMigration("v6_update_most_played_criteria") { db in
            try db.execute(
                sql: """
                    UPDATE playlists
                    SET smart_criteria = REPLACE(smart_criteria, '"condition":"greaterThan"', '"condition":"greaterThanOrEqual"')
                    WHERE name = ? AND type = 'smart'
                    """,
                arguments: [DefaultPlaylists.mostPlayed]
            )
            Logger.info("v6_update_most_played_criteria migration completed")
        }

        migrator.registerMigration("v7_create_background_migrations_table") { db in
            try db.create(table: "background_migrations") { t in
                t.column("identifier", .text).primaryKey()
                t.column("completed_at", .datetime)
                t.column("progress", .text)
                t.column("resumable", .boolean).defaults(to: true)
            }
            Logger.info("v7_create_background_migrations_table migration completed")
        }
        
        migrator.registerMigration("v8_convert_artwork_to_heic") { db in
            try db.execute(
                sql: "INSERT INTO background_migrations (identifier, resumable) VALUES (?, ?)",
                arguments: ["v8_background_convert_artwork_to_heic", true]
            )
            Logger.info("v8_convert_artwork_to_heic: flagged for background artwork conversion")
        }
        
        migrator.registerMigration("v9_rebuild_artist_associations") { db in
            try db.execute(
                sql: "INSERT INTO background_migrations (identifier, resumable) VALUES (?, ?)",
                arguments: ["v9_background_rebuild_artist_associations", true]
            )
            Logger.info("v9_rebuild_artist_associations: flagged for background artist rebuild")
        }

        migrator.registerMigration("v10_add_filename_index_and_drop_pinned_icon_name") { db in
            try db.createIndexIfNotExists(
                name: "idx_tracks_filename",
                table: "tracks",
                columns: ["filename"]
            )
            Logger.info("v10_add_filename_index_and_drop_pinned_icon_name migration completed")
        }

        migrator.registerMigration("v11_add_merge_support") { db in
            // Alias tables: durable old-name -> canonical mapping so manual merges survive re-ingestion.
            try DatabaseManager.createArtistAliasesTable(in: db)
            try DatabaseManager.createAlbumAliasesTable(in: db)
            try db.createIndexIfNotExists(
                name: "idx_artist_aliases_canonical",
                table: "artist_aliases",
                columns: ["canonical_artist_id"]
            )
            try db.createIndexIfNotExists(
                name: "idx_album_aliases_canonical",
                table: "album_aliases",
                columns: ["canonical_album_id"]
            )

            Logger.info("v11_add_merge_support migration completed")
        }

        migrator.registerMigration("v12_backfill_album_artists") { db in
            // Tracks with no album-artist tag have no role='album_artist' junction row,
            // so they're missing from the Album Artists category. Flag a background
            // backfill that creates those rows from the track artist (resumably).
            try db.execute(
                sql: "INSERT INTO background_migrations (identifier, resumable) VALUES (?, ?)",
                arguments: ["v12_background_backfill_album_artists", true]
            )
            Logger.info("v12_backfill_album_artists: flagged for background album-artist backfill")
        }

        migrator.registerMigration("v13_add_artwork_thumbnail") { db in
            // Display-size artwork is heavy to load for lists; a small thumbnail
            // column feeds the reskinned lists. Existing rows are backfilled by a
            // background migration, new artwork gets a thumbnail at scan time.
            try db.addColumnIfNotExists(table: "albums", column: "artwork_thumbnail", type: .blob)
            try db.addColumnIfNotExists(table: "artists", column: "artwork_thumbnail", type: .blob)
            try db.execute(
                sql: "INSERT INTO background_migrations (identifier, resumable) VALUES (?, ?)",
                arguments: ["v13_background_fill_artwork_thumbnail", true]
            )
            Logger.info("v13_add_artwork_thumbnail: added artwork_thumbnail columns and flagged background backfill")
        }

        migrator.registerMigration("v14_playback_journal_cursor") { db in
            // Singleton row: applied_through advances in the same write that
            // mutates tracks, so a crash cannot leave play counts applied and
            // the cursor still old (which would double-count on re-import).
            try db.create(table: "playback_journal_cursor") { t in
                t.primaryKey("singleton", .integer)
                t.column("applied_through", .datetime)
            }
            Logger.info("v14_playback_journal_cursor: created singleton cursor table")
        }

        migrator.registerMigration("v15_date_favorited") { db in
            try db.addColumnIfNotExists(table: "tracks", column: "date_favorited", type: .datetime)
            // Existing favorites had no favorited timestamp; use library date_added
            // so they keep a stable order while new favorites stamp Date() on toggle.
            try db.execute(
                sql: """
                    UPDATE tracks
                    SET date_favorited = date_added
                    WHERE is_favorite = 1 AND date_favorited IS NULL
                    """
            )

            let favorites = try Playlist
                .filter(Playlist.Columns.name == DefaultPlaylists.favorites)
                .filter(Playlist.Columns.type == PlaylistType.smart.rawValue)
                .fetchAll(db)
            for var playlist in favorites {
                guard let criteria = playlist.smartCriteria else { continue }
                playlist.smartCriteria = SmartPlaylistCriteria(
                    matchType: criteria.matchType,
                    rules: criteria.rules,
                    limit: criteria.limit,
                    sortBy: "dateFavorited",
                    sortAscending: false,
                    autoUpdate: criteria.autoUpdate
                )
                try playlist.update(db)
            }
            Logger.info("v15_date_favorited: column, backfill, Favorites sort newest-first")
        }

        migrator.registerMigration("v16_artwork_read_performance") { db in
            // Two background jobs (identifiers sort in run order): re-encode
            // HEIC thumbnails as JPEG, then rebuild albums/artists/tracks with
            // their artwork BLOBs as the last columns of each row.
            for identifier in ["v16_background_jpeg_thumbnails", "v16_background_move_artwork_columns_last"] {
                try db.execute(
                    sql: "INSERT INTO background_migrations (identifier, resumable) VALUES (?, ?)",
                    arguments: [identifier, true]
                )
            }
            Logger.info("v16_artwork_read_performance: flagged JPEG thumbnails and artwork column move")
        }

        migrator.registerMigration("v17_drop_pinned_items") { db in
            // Pinning has no UI any more; v10 and v11 used to touch this table
            // and now leave it to this drop.
            try db.execute(sql: "DROP TABLE IF EXISTS pinned_items")
            Logger.info("v17_drop_pinned_items: dropped pinned_items table")
        }

        // MARK: - Future Migrations
        // Add new migrations here as: migrator.registerMigration("v18_description") { db in ... }
        // A column added to albums, artists or tracks lands after their artwork
        // BLOBs; reading it then walks every BLOB's overflow pages. Rebuild with
        // `moveColumnsToEnd` instead of a plain ADD COLUMN on those tables.

        return migrator
    }
    // swiftlint:enable function_body_length

    /// Apply all pending migrations to the database
    static func migrate(_ dbQueue: any DatabaseWriter) throws {
        let migrator = setupMigrator()
        try migrator.migrate(dbQueue)

        Logger.info("Database migrations completed")
    }
}

// MARK: - Migration Helpers

extension Database {
    /// Helper to safely add a column if it doesn't exist
    func addColumnIfNotExists(
        table: String,
        column: String,
        type: Database.ColumnType,
        defaultValue: DatabaseValueConvertible? = nil,
        notNull: Bool = false
    ) throws {
        let columns = try self.columns(in: table)
        let columnExists = columns.contains { $0.name == column }
        
        if !columnExists {
            try self.alter(table: table) { t in
                var columnDef = t.add(column: column, type)
                if let defaultValue = defaultValue {
                    columnDef = columnDef.defaults(to: defaultValue)
                }
                if notNull {
                    columnDef = columnDef.notNull()
                }
            }
        }
    }
    
    /// Rebuilds `table` with `columns` moved, in this order, to the end of each
    /// row. SQLite stores values in declaration order, and a value behind a large
    /// BLOB is reached only by walking that BLOB's overflow pages — so a list
    /// query reading `albums.release_year` paid for every album's full cover.
    ///
    /// Call inside a transaction with foreign keys disabled. Rows move in
    /// batches, each deleted from the old table right after it is copied, so
    /// the freed pages are reused and the file never holds two copies of the
    /// table. Triggers are dropped before the copy (an FTS delete trigger
    /// would empty the search index) and recreated with the indexes afterwards.
    func moveColumnsToEnd(_ columns: [String], of table: String) throws {
        let current = try self.columns(in: table).map(\.name)
        guard Array(current.suffix(columns.count)) != columns else { return }

        guard let createSQL = try String.fetchOne(
            self,
            sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?",
            arguments: [table]
        ),
              let open = createSQL.firstIndex(of: "("),
              let close = createSQL.lastIndex(of: ")") else {
            throw GRDB.DatabaseError(message: "No table definition for \(table)")
        }
        let definitions = Self.topLevelDefinitions(createSQL[createSQL.index(after: open)..<close])
        func isDefinition(_ definition: String, of column: String) -> Bool {
            definition.hasPrefix("\"\(column)\"")
        }
        let moved = columns.compactMap { column in definitions.first { isDefinition($0, of: column) } }
        guard moved.count == columns.count else {
            throw GRDB.DatabaseError(message: "Missing columns \(columns) in \(table)")
        }
        let kept = definitions.filter { definition in !columns.contains { isDefinition(definition, of: $0) } }

        let dependents = try Row.fetchAll(
            self,
            sql: "SELECT type, name, sql FROM sqlite_master WHERE tbl_name = ? AND type IN ('index', 'trigger') AND sql IS NOT NULL",
            arguments: [table]
        )
        for row in dependents where row["type"] as String == "trigger" {
            try execute(sql: "DROP TRIGGER \"\(row["name"] as String)\"")
        }
        let hasSequence = try tableExists("sqlite_sequence")
        let sequence = hasSequence
            ? try Int64.fetchOne(self, sql: "SELECT seq FROM sqlite_sequence WHERE name = ?", arguments: [table])
            : nil

        let staging = "\(table)_reordered"
        try execute(sql: "CREATE TABLE \"\(staging)\" (\((kept + moved).joined(separator: ", ")))")
        let columnList = (current.filter { !columns.contains($0) } + columns)
            .map { "\"\($0)\"" }
            .joined(separator: ", ")
        var lastRowID = Int64.min
        while let upper = try Int64.fetchOne(
            self,
            sql: "SELECT MAX(rowid) FROM (SELECT rowid FROM \"\(table)\" WHERE rowid > ? ORDER BY rowid LIMIT 100)",
            arguments: [lastRowID]
        ) {
            try execute(
                sql: "INSERT INTO \"\(staging)\" (\(columnList)) SELECT \(columnList) FROM \"\(table)\" WHERE rowid > ? AND rowid <= ?",
                arguments: [lastRowID, upper]
            )
            try execute(sql: "DELETE FROM \"\(table)\" WHERE rowid > ? AND rowid <= ?", arguments: [lastRowID, upper])
            lastRowID = upper
        }
        try execute(sql: "DROP TABLE \"\(table)\"")
        try execute(sql: "ALTER TABLE \"\(staging)\" RENAME TO \"\(table)\"")
        for row in dependents {
            try execute(sql: row["sql"])
        }
        // Dropping the table forgot its AUTOINCREMENT high-water mark; keep ids
        // of deleted rows from being reused.
        if let sequence {
            try execute(
                sql: "UPDATE sqlite_sequence SET seq = MAX(seq, ?) WHERE name = ?",
                arguments: [sequence, table]
            )
            if changesCount == 0 {
                try execute(sql: "INSERT INTO sqlite_sequence (name, seq) VALUES (?, ?)", arguments: [table, sequence])
            }
        }
    }

    /// Splits a CREATE TABLE body at commas outside parentheses and quotes.
    static func topLevelDefinitions(_ body: Substring) -> [String] {
        var definitions: [String] = []
        var current = ""
        var depth = 0
        var quote: Character?
        for character in body {
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "(" {
                depth += 1
            } else if character == ")" {
                depth -= 1
            } else if character == ",", depth == 0 {
                definitions.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
                continue
            }
            current.append(character)
        }
        definitions.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        return definitions
    }

    /// Helper to create an index if it doesn't exist
    func createIndexIfNotExists(
        name: String,
        table: String,
        columns: [String],
        unique: Bool = false
    ) throws {
        let indexExists = try self.indexes(on: table).contains { $0.name == name }
        
        if !indexExists {
            try self.create(
                index: name,
                on: table,
                columns: columns,
                unique: unique,
                ifNotExists: true
            )
        }
    }
    
    /// Helper to create a table only if it doesn't exist
    func createTableIfNotExists(
        _ name: String,
        body: (TableDefinition) throws -> Void
    ) throws {
        try self.create(table: name, ifNotExists: true, body: body)
    }
}
