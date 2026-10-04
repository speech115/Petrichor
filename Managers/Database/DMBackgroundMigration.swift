//
// DatabaseManager class extension
//
// This extension contains background migration logic for heavy one-time data transformations
// that run asynchronously after app launch without blocking the UI.
//

import Foundation
import GRDB

extension DatabaseManager {
    /// Returns true if at least one migration actually performed data work, so the
    /// caller can refresh category/sidebar caches that the migration may have changed.
    @discardableResult
    func runPendingBackgroundMigrations() async -> Bool {
        let pending: [(identifier: String, progress: String?)]
        do {
            pending = try await dbQueue.read { db -> [(String, String?)] in
                if try db.tableExists("background_migrations") {
                    let sql = """
                        SELECT identifier, progress FROM background_migrations \
                        WHERE completed_at IS NULL ORDER BY identifier
                        """
                    return try Row.fetchAll(db, sql: sql)
                        .map { ($0["identifier"], $0["progress"]) }
                }
                return []
            }
        } catch {
            Logger.error("Failed to read pending background migrations: \(error)")
            return false
        }
        if pending.isEmpty { return false }

        // Skip migrations on a fresh/empty database — nothing to migrate
        let trackCount = (try? await dbQueue.read { db in try Track.fetchCount(db) }) ?? 0
        if trackCount == 0 {
            // Column order is schema, not data: a fresh database still gets it,
            // and the rebuild of empty tables is instant.
            if pending.contains(where: { $0.identifier == Self.artworkColumnsLastIdentifier }) {
                await moveArtworkColumnsLast()
            }
            for (identifier, _) in pending {
                completeBackgroundMigration(identifier)
            }
            Logger.info("Skipped \(pending.count) background migrations on empty database")
            return false
        }

        for (identifier, progress) in pending {
            switch identifier {
            case "v8_background_convert_artwork_to_heic":
                await convertArtworkToHEIC(progress: progress)
            case Self.knownArtistsMigrationIdentifier:
                await loadKnownArtistsAndRebuild(progress: progress)
            case Self.albumArtistBackfillIdentifier:
                await backfillAlbumArtists(progress: progress)
            case Self.thumbnailBackfillIdentifier:
                await fillArtworkThumbnails(progress: progress)
            case Self.jpegThumbnailIdentifier:
                await convertThumbnailsToJPEG(progress: progress)
            case Self.artworkColumnsLastIdentifier:
                await moveArtworkColumnsLast()
            default:
                Logger.warning("Unknown background migration: \(identifier)")
            }
        }
        return true
    }

    // MARK: - v8: Convert Artwork to HEIC

    private struct ArtworkConversionProgress: Codable {
        let table: String
        let offset: Int
    }

    private struct ArtworkTableOps: Sendable {
        let name: String
        let count: @Sendable (Database) throws -> Int
        let fetchBatch: @Sendable (Database, Int, Int) throws -> [Row]
        let compressAndUpdate: @Sendable (any DatabaseWriter, [Row]) throws -> Int
    }

    private static let artworkMigrationIdentifier = "v8_background_convert_artwork_to_heic"

    private static let artworkTableOps: [ArtworkTableOps] = [
        ArtworkTableOps(
            name: "albums",
            count: { db in try Album.filter(Album.Columns.artworkData != nil).fetchCount(db) },
            fetchBatch: { db, limit, offset in
                try Row.fetchAll(db, Album
                    .filter(Album.Columns.artworkData != nil)
                    .select(Album.Columns.id, Album.Columns.title, Album.Columns.artworkData)
                    .limit(limit, offset: offset))
            },
            compressAndUpdate: { dbQueue, rows in
                var updates: [(Int64, Data)] = []
                for row in rows {
                    guard let rowId: Int64 = row[Album.Columns.id],
                          let original: Data = row[Album.Columns.artworkData] else { continue }
                    let name: String? = row[Album.Columns.title]
                    guard let compressed = ImageUtils.compressImage(
                        from: original, source: "album: \(name ?? "id=\(rowId)")"
                    ) else { continue }
                    guard compressed.count < original.count else { continue }
                    updates.append((rowId, compressed))
                }
                try dbQueue.write { db in
                    for (rowId, data) in updates {
                        try Album.filter(Album.Columns.id == rowId)
                            .updateAll(db, Album.Columns.artworkData.set(to: data))
                    }
                }
                return updates.count
            }
        ),
        ArtworkTableOps(
            name: "artists",
            count: { db in try Artist.filter(Artist.Columns.artworkData != nil).fetchCount(db) },
            fetchBatch: { db, limit, offset in
                try Row.fetchAll(db, Artist
                    .filter(Artist.Columns.artworkData != nil)
                    .select(Artist.Columns.id, Artist.Columns.name, Artist.Columns.artworkData)
                    .limit(limit, offset: offset))
            },
            compressAndUpdate: { dbQueue, rows in
                var updates: [(Int64, Data)] = []
                for row in rows {
                    guard let rowId: Int64 = row[Artist.Columns.id],
                          let original: Data = row[Artist.Columns.artworkData] else { continue }
                    let name: String? = row[Artist.Columns.name]
                    guard let compressed = ImageUtils.compressImage(
                        from: original, source: "artist: \(name ?? "id=\(rowId)")"
                    ) else { continue }
                    guard compressed.count < original.count else { continue }
                    updates.append((rowId, compressed))
                }
                try dbQueue.write { db in
                    for (rowId, data) in updates {
                        try Artist.filter(Artist.Columns.id == rowId)
                            .updateAll(db, Artist.Columns.artworkData.set(to: data))
                    }
                }
                return updates.count
            }
        ),
        ArtworkTableOps(
            name: "tracks",
            count: { db in try FullTrack.filter(FullTrack.Columns.trackArtworkData != nil).fetchCount(db) },
            fetchBatch: { db, limit, offset in
                try Row.fetchAll(db, FullTrack
                    .filter(FullTrack.Columns.trackArtworkData != nil)
                    .select(FullTrack.Columns.trackId, FullTrack.Columns.filename, FullTrack.Columns.trackArtworkData)
                    .limit(limit, offset: offset))
            },
            compressAndUpdate: { dbQueue, rows in
                var updates: [(Int64, Data)] = []
                for row in rows {
                    guard let rowId: Int64 = row[FullTrack.Columns.trackId],
                          let original: Data = row[FullTrack.Columns.trackArtworkData] else { continue }
                    let name: String? = row[FullTrack.Columns.filename]
                    guard let compressed = ImageUtils.compressImage(
                        from: original, source: "track: \(name ?? "id=\(rowId)")"
                    ) else { continue }
                    guard compressed.count < original.count else { continue }
                    updates.append((rowId, compressed))
                }
                try dbQueue.write { db in
                    for (rowId, data) in updates {
                        try FullTrack.filter(FullTrack.Columns.trackId == rowId)
                            .updateAll(db, FullTrack.Columns.trackArtworkData.set(to: data))
                    }
                }
                return updates.count
            }
        ),
        ArtworkTableOps(
            name: "playlists",
            count: { db in try Playlist.filter(Playlist.Columns.coverArtworkData != nil).fetchCount(db) },
            fetchBatch: { db, limit, offset in
                try Row.fetchAll(db, Playlist
                    .filter(Playlist.Columns.coverArtworkData != nil)
                    .select(Playlist.Columns.id, Playlist.Columns.name, Playlist.Columns.coverArtworkData)
                    .limit(limit, offset: offset))
            },
            compressAndUpdate: { dbQueue, rows in
                var updates: [(String, Data)] = []
                for row in rows {
                    guard let rowId: String = row[Playlist.Columns.id],
                          let original: Data = row[Playlist.Columns.coverArtworkData] else { continue }
                    let name: String? = row[Playlist.Columns.name]
                    guard let compressed = ImageUtils.compressImage(
                        from: original, source: "playlist: \(name ?? "id=\(rowId)")"
                    ) else { continue }
                    guard compressed.count < original.count else { continue }
                    updates.append((rowId, compressed))
                }
                try dbQueue.write { db in
                    for (rowId, data) in updates {
                        try Playlist.filter(Playlist.Columns.id == rowId)
                            .updateAll(db, Playlist.Columns.coverArtworkData.set(to: data))
                    }
                }
                return updates.count
            }
        )
    ]

    private func convertArtworkToHEIC(progress: String?) async {
        await NotificationManager.shared.startActivity(String(localized: "Optimizing Library..."))

        let sizeBefore = DatabaseFactory.databaseFileSize() ?? 0
        let batchSize = 50
        let tables = Self.artworkTableOps

        var resumeTable = tables[0].name
        var resumeOffset = 0
        if let progress = progress,
           let data = progress.data(using: .utf8),
           let state = try? JSONDecoder().decode(ArtworkConversionProgress.self, from: data) {
            resumeTable = state.table
            resumeOffset = state.offset
            Logger.info("Resuming artwork optimization from \(resumeTable) at offset \(resumeOffset)")
        }

        let startIndex = tables.firstIndex { $0.name == resumeTable } ?? 0

        do {
            let totalRows = try await dbQueue.read { db -> Int in
                try tables.reduce(0) { total, table in try total + table.count(db) }
            }

            Logger.info("Starting artwork optimization: \(totalRows) total rows")

            try await Task.detached(priority: .utility) { [dbQueue, weak self, tables, startIndex, resumeOffset, totalRows] in
                guard let self = self else { return }

                var totalProcessed = 0
                if startIndex > 0 || resumeOffset > 0 {
                    totalProcessed = try await dbQueue.read { db -> Int in
                        var processed = 0
                        for tableIdx in 0..<startIndex {
                            processed += try tables[tableIdx].count(db)
                        }
                        return processed + resumeOffset
                    }
                    await NotificationManager.shared.updateActivityProgress(current: totalProcessed, total: totalRows)
                }

                for tableIndex in startIndex..<tables.count {
                    let ops = tables[tableIndex]
                    var offset = (tableIndex == startIndex) ? resumeOffset : 0
                    var converted = 0
                    var skipped = 0

                    while true {
                        let rows = try self.readMigrationRows { db in try ops.fetchBatch(db, batchSize, offset) }
                        if rows.isEmpty { break }

                        let batchConverted = try ops.compressAndUpdate(dbQueue, rows)
                        converted += batchConverted
                        skipped += rows.count - batchConverted
                        totalProcessed += rows.count
                        offset += batchSize

                        await NotificationManager.shared.updateActivityProgress(current: totalProcessed, total: totalRows)
                        if let progressData = try? JSONEncoder().encode(
                            ArtworkConversionProgress(table: ops.name, offset: offset)
                        ),
                           let progressJson = String(data: progressData, encoding: .utf8) {
                            self.updateMigrationProgress(Self.artworkMigrationIdentifier, progress: progressJson)
                        }
                    }

                    let skipInfo = skipped > 0 ? " (\(skipped) skipped)" : ""
                    Logger.info("Optimized \(converted) \(ops.name) artworks\(skipInfo)")
                }
            }.value

            try await vacuumDatabase()
            completeBackgroundMigration(Self.artworkMigrationIdentifier)

            let sizeAfter = DatabaseFactory.databaseFileSize() ?? 0
            let spaceSaved = max(0, sizeBefore - sizeAfter)

            await NotificationManager.shared.stopActivity()
            if spaceSaved > 0 {
                let savedMB = Double(spaceSaved) / (1024.0 * 1024.0)
                await NotificationManager.shared.addMessage(.info, String(localized: "Library optimized - reclaimed \(String(format: "%.1f", savedMB)) MB"))
            } else {
                await NotificationManager.shared.addMessage(.info, String(localized: "Library optimized"))
            }
            Logger.info("Artwork optimization completed")
        } catch {
            await NotificationManager.shared.stopActivity()
            await NotificationManager.shared.addMessage(.error, String(localized: "Failed to optimize library"))
            Logger.error("Artwork optimization failed: \(error)")
        }
    }

    // MARK: - v9: Load Known Artists & Rebuild Artist Associations

    private static let knownArtistsMigrationIdentifier = "v9_background_rebuild_artist_associations"

    private struct KnownArtistsProgress: Codable {
        let offset: Int
    }

    private func loadKnownArtistsAndRebuild(progress: String?) async {
        await NotificationManager.shared.startActivity(String(localized: "Updating Artists..."))

        var resumeOffset = 0
        if let progress = progress,
           let data = progress.data(using: .utf8),
           let state = try? JSONDecoder().decode(KnownArtistsProgress.self, from: data) {
            resumeOffset = state.offset
            Logger.info("Resuming known artists migration at offset \(resumeOffset)")
        }

        do {
            try await rebuildArtistAssociations(resumeOffset: resumeOffset)

            completeBackgroundMigration(Self.knownArtistsMigrationIdentifier)
            await NotificationManager.shared.stopActivity()
            await NotificationManager.shared.addMessage(.info, String(localized: "Artists information updated successfully"))
            Logger.info("Known artists migration completed")
        } catch {
            await NotificationManager.shared.stopActivity()
            await NotificationManager.shared.addMessage(.error, String(localized: "Failed to update artists information"))
            Logger.error("Known artists migration failed: \(error)")
        }
    }

    /// Rebuild all TrackArtist/AlbumArtist associations using updated parser
    private func rebuildArtistAssociations(resumeOffset: Int) async throws {
        let totalTracks = try await dbQueue.read { db in
            try FullTrack.filter(FullTrack.Columns.isDuplicate == false).fetchCount(db)
        }

        guard totalTracks > 0 else {
            Logger.info("No tracks to rebuild artist associations for")
            return
        }

        Logger.info("Rebuilding artist associations for \(totalTracks) tracks")

        try await Task.detached(priority: .utility) { [dbQueue, weak self, resumeOffset, totalTracks] in
            guard let self = self else { return }

            ArtistParser.loadKnownArtists()
            // Balanced unload even if a batch write below throws, so the retain count can't leak.
            defer { ArtistParser.unloadKnownArtists() }

            // Clear existing associations and reset stats
            _ = try await dbQueue.write { db in
                try TrackArtist.deleteAll(db)
                try AlbumArtist.deleteAll(db)
                try Artist.updateAll(db, Artist.Columns.totalTracks.set(to: 0), Artist.Columns.totalAlbums.set(to: 0))
                try Album.updateAll(db, Album.Columns.totalTracks.set(to: 0))
            }

            Logger.info("Cleared existing artist/album associations")

            // Rebuild in batches
            let batchSize = 500
            var offset = resumeOffset

            while offset < totalTracks {
                let tracks = try await dbQueue.read { [offset] db in
                    try FullTrack
                        .filter(FullTrack.Columns.isDuplicate == false)
                        .order(FullTrack.Columns.trackId)
                        .limit(batchSize, offset: offset)
                        .fetchAll(db)
                }

                if tracks.isEmpty { break }

                _ = try await dbQueue.write { db in
                    for var track in tracks {
                        try self.processTrackArtists(track, in: db)
                        try self.processTrackAlbum(&track, in: db)
                    }
                }

                offset += tracks.count
                await NotificationManager.shared.updateActivityProgress(current: offset, total: totalTracks)
                self.saveProgress(offset: offset)
            }

            // Update stats
            try await dbQueue.write { db in
                try self.updateEntityStats(in: db)
            }

            Logger.info("Artist associations rebuild completed")
        }.value

        // Clean up orphaned entities (runs in its own dbQueue.write)
        try await cleanupOrphanedData()
    }

    // MARK: - v9 Helpers

    private func saveProgress(offset: Int) {
        if let data = try? JSONEncoder().encode(KnownArtistsProgress(offset: offset)),
           let json = String(data: data, encoding: .utf8) {
            updateMigrationProgress(Self.knownArtistsMigrationIdentifier, progress: json)
        }
    }

    // MARK: - Migration State

    func isActiveBackgroundMigrationResumable() -> Bool {
        do {
            return try dbQueue.read { db -> Bool in
                if try db.tableExists("background_migrations") {
                    return try Bool.fetchOne(
                        db,
                        sql: "SELECT resumable FROM background_migrations WHERE completed_at IS NULL LIMIT 1"
                    ) ?? true
                }
                return true
            }
        } catch {
            return true
        }
    }

    // MARK: - v12: Backfill album-artist associations

    private static let albumArtistBackfillIdentifier = "v12_background_backfill_album_artists"

    private struct AlbumArtistBackfillProgress: Codable {
        let offset: Int
    }

    private func backfillAlbumArtists(progress: String?) async {
        await NotificationManager.shared.startActivity(String(localized: "Updating album artists..."))

        var resumeOffset = 0
        if let progress = progress,
           let data = progress.data(using: .utf8),
           let state = try? JSONDecoder().decode(AlbumArtistBackfillProgress.self, from: data) {
            resumeOffset = state.offset
            Logger.info("Resuming album-artist backfill at offset \(resumeOffset)")
        }

        do {
            try await performAlbumArtistBackfill(resumeOffset: resumeOffset)
            completeBackgroundMigration(Self.albumArtistBackfillIdentifier)
            await NotificationManager.shared.stopActivity()
            Logger.info("Album-artist backfill completed")
        } catch {
            // Leave the migration unfinished (completed_at stays NULL) so it resumes
            // from the saved offset on next launch. Never rethrow - don't crash launch.
            await NotificationManager.shared.stopActivity()
            Logger.error("Album-artist backfill failed (will resume next launch): \(error)")
        }
    }

    /// Backfills a `role='album_artist'` junction row (falling back to the track
    /// artist) for tracks that have none. Resumable (saved offset) and idempotent
    /// (per-track existence check); append-only, never clearing existing rows.
    private func performAlbumArtistBackfill(resumeOffset: Int) async throws {
        let totalTracks = try await dbQueue.read { db in try Track.fetchCount(db) }
        guard totalTracks > 0 else { return }

        Logger.info("Backfilling album artists across \(totalTracks) tracks")

        try await Task.detached(priority: .utility) { [dbQueue, weak self, resumeOffset, totalTracks] in
            guard let self = self else { return }

            let batchSize = 500
            var offset = resumeOffset

            while offset < totalTracks {
                let tracks = try await dbQueue.read { [offset] db in
                    try FullTrack
                        .order(FullTrack.Columns.trackId)
                        .limit(batchSize, offset: offset)
                        .fetchAll(db)
                }
                if tracks.isEmpty { break }

                try await dbQueue.write { db in
                    for track in tracks {
                        guard let trackId = track.trackId else { continue }

                        // Skip tracks that already have an album-artist relationship
                        // (a real tag, or a prior backfill run). Makes resume safe.
                        let alreadyLinked = try TrackArtist
                            .filter(TrackArtist.Columns.trackId == trackId)
                            .filter(TrackArtist.Columns.role == TrackArtist.Role.albumArtist)
                            .fetchCount(db) > 0
                        if alreadyLinked { continue }

                        guard let field = self.resolvedAlbumArtistField(for: track) else { continue }
                        try self.processArtistsForField(field, trackId: trackId, role: TrackArtist.Role.albumArtist, in: db)
                    }
                }

                offset += tracks.count
                await NotificationManager.shared.updateActivityProgress(current: offset, total: totalTracks)
                if let data = try? JSONEncoder().encode(AlbumArtistBackfillProgress(offset: offset)),
                   let json = String(data: data, encoding: .utf8) {
                    self.updateMigrationProgress(Self.albumArtistBackfillIdentifier, progress: json)
                }
            }
        }.value
    }

    // MARK: - v13: Backfill artwork thumbnails

    private static let thumbnailBackfillIdentifier = "v13_background_fill_artwork_thumbnail"

    private struct ThumbnailFillProgress: Codable {
        let table: String
        let offset: Int
    }

    private struct ThumbnailTableOps: Sendable {
        let name: String
        let count: @Sendable (Database) throws -> Int
        let fetchBatch: @Sendable (Database, Int, Int) throws -> [Row]
        let generateAndUpdate: @Sendable (any DatabaseWriter, [Row]) throws -> Int
    }

    // Batches page over the stable `artwork_data != nil` set (this migration only
    // writes artwork_thumbnail, so the set never shrinks and offset paging stays
    // correct). Rows that already have a thumbnail are skipped in generateAndUpdate;
    // the strict `artwork_thumbnail == nil` filter would drop processed rows from the
    // paged set mid-run and skip the ones behind them.
    private static let thumbnailTableOps: [ThumbnailTableOps] = [
        ThumbnailTableOps(
            name: "albums",
            count: { db in try Album.filter(Album.Columns.artworkData != nil).fetchCount(db) },
            fetchBatch: { db, limit, offset in
                try Row.fetchAll(db, Album
                    .filter(Album.Columns.artworkData != nil)
                    .select(Album.Columns.id, Album.Columns.title, Album.Columns.artworkData, Album.Columns.artworkThumbnail)
                    .limit(limit, offset: offset))
            },
            generateAndUpdate: { dbQueue, rows in
                var updates: [(Int64, Data)] = []
                for row in rows {
                    guard let rowId: Int64 = row[Album.Columns.id],
                          let original: Data = row[Album.Columns.artworkData] else { continue }
                    let hasThumbnail: Bool = row[Album.Columns.artworkThumbnail] != nil
                    guard !hasThumbnail else { continue }
                    let name: String? = row[Album.Columns.title]
                    guard let thumbnail = ImageUtils.makeThumbnail(
                        from: original, source: "album: \(name ?? "id=\(rowId)")"
                    ) else { continue }
                    updates.append((rowId, thumbnail))
                }
                try dbQueue.write { db in
                    for (rowId, data) in updates {
                        try Album.filter(Album.Columns.id == rowId)
                            .updateAll(db, Album.Columns.artworkThumbnail.set(to: data))
                    }
                }
                return updates.count
            }
        ),
        ThumbnailTableOps(
            name: "artists",
            count: { db in try Artist.filter(Artist.Columns.artworkData != nil).fetchCount(db) },
            fetchBatch: { db, limit, offset in
                try Row.fetchAll(db, Artist
                    .filter(Artist.Columns.artworkData != nil)
                    .select(Artist.Columns.id, Artist.Columns.name, Artist.Columns.artworkData, Artist.Columns.artworkThumbnail)
                    .limit(limit, offset: offset))
            },
            generateAndUpdate: { dbQueue, rows in
                var updates: [(Int64, Data)] = []
                for row in rows {
                    guard let rowId: Int64 = row[Artist.Columns.id],
                          let original: Data = row[Artist.Columns.artworkData] else { continue }
                    let hasThumbnail: Bool = row[Artist.Columns.artworkThumbnail] != nil
                    guard !hasThumbnail else { continue }
                    let name: String? = row[Artist.Columns.name]
                    guard let thumbnail = ImageUtils.makeThumbnail(
                        from: original, source: "artist: \(name ?? "id=\(rowId)")"
                    ) else { continue }
                    updates.append((rowId, thumbnail))
                }
                try dbQueue.write { db in
                    for (rowId, data) in updates {
                        try Artist.filter(Artist.Columns.id == rowId)
                            .updateAll(db, Artist.Columns.artworkThumbnail.set(to: data))
                    }
                }
                return updates.count
            }
        )
    ]

    private func fillArtworkThumbnails(progress: String?) async {
        await NotificationManager.shared.startActivity(String(localized: "Generating Thumbnails..."))

        let batchSize = 50
        let tables = Self.thumbnailTableOps

        var resumeTable = tables[0].name
        var resumeOffset = 0
        if let progress = progress,
           let data = progress.data(using: .utf8),
           let state = try? JSONDecoder().decode(ThumbnailFillProgress.self, from: data) {
            resumeTable = state.table
            resumeOffset = state.offset
            Logger.info("Resuming thumbnail backfill from \(resumeTable) at offset \(resumeOffset)")
        }

        let startIndex = tables.firstIndex { $0.name == resumeTable } ?? 0

        do {
            let totalRows = try await dbQueue.read { db -> Int in
                try tables.reduce(0) { total, table in try total + table.count(db) }
            }

            guard totalRows > 0 else {
                completeBackgroundMigration(Self.thumbnailBackfillIdentifier)
                await NotificationManager.shared.stopActivity()
                Logger.info("No artwork rows to thumbnail, marking backfill complete")
                return
            }

            Logger.info("Starting thumbnail backfill: \(totalRows) rows")

            try await Task.detached(priority: .utility) { [dbQueue, weak self, tables, startIndex, resumeOffset, totalRows] in
                guard let self = self else { return }

                var totalProcessed = 0
                if startIndex > 0 || resumeOffset > 0 {
                    totalProcessed = try await dbQueue.read { db -> Int in
                        var processed = 0
                        for tableIdx in 0..<startIndex {
                            processed += try tables[tableIdx].count(db)
                        }
                        return processed + resumeOffset
                    }
                    await NotificationManager.shared.updateActivityProgress(current: totalProcessed, total: totalRows)
                }

                for tableIndex in startIndex..<tables.count {
                    let ops = tables[tableIndex]
                    var offset = (tableIndex == startIndex) ? resumeOffset : 0
                    var generated = 0
                    var skipped = 0

                    while true {
                        let rows = try self.readMigrationRows { db in try ops.fetchBatch(db, batchSize, offset) }
                        if rows.isEmpty { break }

                        let batchGenerated = try ops.generateAndUpdate(dbQueue, rows)
                        generated += batchGenerated
                        skipped += rows.count - batchGenerated
                        totalProcessed += rows.count
                        offset += batchSize

                        await NotificationManager.shared.updateActivityProgress(current: totalProcessed, total: totalRows)
                        if let progressData = try? JSONEncoder().encode(
                            ThumbnailFillProgress(table: ops.name, offset: offset)
                        ),
                           let progressJson = String(data: progressData, encoding: .utf8) {
                            self.updateMigrationProgress(Self.thumbnailBackfillIdentifier, progress: progressJson)
                        }
                    }

                    let skipInfo = skipped > 0 ? " (\(skipped) already present)" : ""
                    Logger.info("Generated \(generated) \(ops.name) thumbnails\(skipInfo)")
                }
            }.value

            completeBackgroundMigration(Self.thumbnailBackfillIdentifier)
            await NotificationManager.shared.stopActivity()
            Logger.info("Thumbnail backfill completed")
        } catch {
            // Leave the migration unfinished (completed_at stays NULL) so it resumes
            // from the saved offset on next launch. Never rethrow - don't crash launch.
            await NotificationManager.shared.stopActivity()
            Logger.error("Thumbnail backfill failed (will resume next launch): \(error)")
        }
    }

    // MARK: - v16: JPEG Thumbnails

    private static let jpegThumbnailIdentifier = "v16_background_jpeg_thumbnails"

    private struct JPEGThumbnailProgress: Codable {
        let table: String
        let lastID: Int64
    }

    /// Re-encodes HEIC thumbnails as JPEG (see `ImageUtils.makeThumbnail`),
    /// from the full artwork when it is stored, else from the old thumbnail.
    private func convertThumbnailsToJPEG(progress: String?) async {
        let identifier = Self.jpegThumbnailIdentifier
        let tables: [(name: String, label: String)] = [("albums", "title"), ("artists", "name")]
        var resume = JPEGThumbnailProgress(table: tables[0].name, lastID: 0)
        if let data = progress?.data(using: .utf8),
           let state = try? JSONDecoder().decode(JPEGThumbnailProgress.self, from: data) {
            resume = state
        }
        let startIndex = tables.firstIndex { $0.name == resume.table } ?? 0

        await NotificationManager.shared.startActivity(String(localized: "Generating Thumbnails..."))
        do {
            try await Task.detached(priority: .utility) { [weak self] in
                guard let self else { return }
                for table in tables[startIndex...] {
                    var lastID = table.name == resume.table ? resume.lastID : 0
                    var converted = 0
                    while true {
                        let rows = try self.readMigrationRows { db in
                            try Row.fetchAll(
                                db,
                                sql: """
                                    SELECT id, \(table.label) AS label, artwork_thumbnail, artwork_data
                                    FROM \(table.name)
                                    WHERE id > ? AND artwork_thumbnail IS NOT NULL
                                    ORDER BY id LIMIT 50
                                    """,
                                arguments: [lastID]
                            )
                        }
                        guard let last = rows.last else { break }
                        var updates: [(Int64, Data)] = []
                        for row in rows {
                            let thumbnail: Data = row["artwork_thumbnail"]
                            guard !ImageUtils.isJPEG(thumbnail) else { continue }
                            let original: Data = row["artwork_data"] ?? thumbnail
                            let label: String? = row["label"]
                            guard let jpeg = ImageUtils.makeThumbnail(
                                from: original,
                                source: "\(table.name): \(label ?? "?")"
                            ) else { continue }
                            updates.append((row["id"], jpeg))
                        }
                        try self.dbQueue.write { db in
                            for (id, data) in updates {
                                try db.execute(
                                    sql: "UPDATE \(table.name) SET artwork_thumbnail = ? WHERE id = ?",
                                    arguments: [data, id]
                                )
                            }
                        }
                        converted += updates.count
                        lastID = last["id"]
                        if let data = try? JSONEncoder().encode(JPEGThumbnailProgress(table: table.name, lastID: lastID)),
                           let json = String(data: data, encoding: .utf8) {
                            self.updateMigrationProgress(identifier, progress: json)
                        }
                    }
                    Logger.info("Re-encoded \(converted) \(table.name) thumbnails as JPEG")
                }
            }.value
            completeBackgroundMigration(identifier)
        } catch {
            Logger.error("JPEG thumbnail conversion failed (will resume next launch): \(error)")
        }
        await NotificationManager.shared.stopActivity()
    }

    // MARK: - v16: Artwork Columns Last

    private static let artworkColumnsLastIdentifier = "v16_background_move_artwork_columns_last"

    /// Rebuilds the three artwork-carrying tables with their BLOBs last (see
    /// `Database.moveColumnsToEnd`). One transaction per table, with foreign
    /// keys off so the batched deletes do not cascade into junction rows.
    private func moveArtworkColumnsLast() async {
        let moves: [(table: String, columns: [String])] = [
            ("albums", ["artwork_thumbnail", "artwork_data"]),
            ("artists", ["artwork_thumbnail", "artwork_data"]),
            ("tracks", ["track_artwork_data"])
        ]
        do {
            for move in moves {
                try await dbQueue.writeWithoutTransaction { db in
                    try db.execute(sql: "PRAGMA foreign_keys = OFF")
                    defer { try? db.execute(sql: "PRAGMA foreign_keys = ON") }
                    try db.inTransaction {
                        try db.moveColumnsToEnd(move.columns, of: move.table)
                        return .commit
                    }
                }
            }
            // The rebuild passed every artwork page through the WAL.
            checkpoint()
            completeBackgroundMigration(Self.artworkColumnsLastIdentifier)
            Logger.info("Moved artwork columns to the end of their rows")
        } catch {
            Logger.error("Artwork column move failed (will retry next launch): \(error)")
        }
    }

    // MARK: - Helpers

    // Migrations already run off-main; keep non-Sendable GRDB rows in that
    // synchronous context instead of selecting the async read overload.
    private func readMigrationRows(_ fetch: (Database) throws -> [Row]) throws -> [Row] {
        try dbQueue.read(fetch)
    }

    func updateMigrationProgress(_ identifier: String, progress: String) {
        do {
            try dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE background_migrations SET progress = ? WHERE identifier = ?",
                    arguments: [progress, identifier]
                )
            }
        } catch {
            Logger.error("Failed to update migration progress for \(identifier): \(error)")
        }
    }

    func completeBackgroundMigration(_ identifier: String) {
        do {
            try dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE background_migrations SET completed_at = ?, progress = NULL WHERE identifier = ?",
                    arguments: [Date(), identifier]
                )
            }
        } catch {
            Logger.error("Failed to mark migration \(identifier) as completed: \(error)")
        }
    }
}
