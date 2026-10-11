// Rust selects and persists migration batches; Apple image codecs and activity presentation stay here.
import Foundation
import ImageIO
import UniformTypeIdentifiers
import PetrichorCore

private final class DatabaseMigrationProgressObserver: BackgroundMigrationProgress, Sendable {
    func update(processed: UInt64, total: UInt64) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                NotificationManager.shared.updateActivityProgress(current: Int(processed), total: Int(total))
            }
        }
    }
}

extension DatabaseManager {
    @discardableResult
    func runPendingBackgroundMigrations() async -> Bool {
        do {
            let pending = try core.pendingBackgroundMigrations()
            guard !pending.isEmpty else { return false }
            for job in pending {
                let sizeBefore = job.identifier == "v8_background_convert_artwork_to_heic"
                    ? DatabaseFactory.databaseFileSize() ?? 0 : 0
                do {
                    switch job.identifier {
                    case "v8_background_convert_artwork_to_heic",
                         "v13_background_fill_artwork_thumbnail",
                         "v16_background_jpeg_thumbnails":
                        let message = job.identifier == "v8_background_convert_artwork_to_heic"
                            ? String(localized: "Optimizing Library...")
                            : String(localized: "Generating Thumbnails...")
                        await NotificationManager.shared.startActivity(message)
                        try await Task.detached(priority: .utility) { [self] in
                            try await migrateArtwork(job.identifier)
                        }.value
                    case "v9_background_rebuild_artist_associations", "v12_background_backfill_album_artists":
                        let message = job.identifier == "v9_background_rebuild_artist_associations"
                            ? String(localized: "Updating Artists...")
                            : String(localized: "Updating album artists...")
                        await NotificationManager.shared.startActivity(message)
                        try await Task.detached(priority: .utility) { [self] in
                            loadScanArtists()
                            defer { unloadScanArtists() }
                            try core.runBackgroundAssociations(
                                identifier: job.identifier,
                                now: Date().timeIntervalSince1970,
                                progress: DatabaseMigrationProgressObserver()
                            )
                        }.value
                    case "v16_background_move_artwork_columns_last":
                        try await Task.detached(priority: .utility) { [core] in
                            try core.moveArtworkColumnsLast(now: Date().timeIntervalSince1970)
                        }.value
                    default:
                        Logger.warning("Unknown background migration: \(job.identifier)")
                    }
                    await NotificationManager.shared.stopActivity()
                    await postMigrationResult(job.identifier, succeeded: true, sizeBefore: sizeBefore)
                } catch {
                    await NotificationManager.shared.stopActivity()
                    await postMigrationResult(job.identifier, succeeded: false, sizeBefore: sizeBefore)
                    Logger.error("Background migration \(job.identifier) failed: \(error)")
                }
            }
            // Earlier batches may have committed before a later failure; retain the existing refresh contract.
            return true
        } catch {
            Logger.error("Failed to read pending background migrations: \(error)")
            return false
        }
    }

    private func postMigrationResult(_ identifier: String, succeeded: Bool, sizeBefore: Int64) async {
        switch identifier {
        case "v8_background_convert_artwork_to_heic":
            guard succeeded else {
                await NotificationManager.shared.addMessage(.error, String(localized: "Failed to optimize library"))
                return
            }
            let spaceSaved = max(0, sizeBefore - (DatabaseFactory.databaseFileSize() ?? 0))
            if spaceSaved > 0 {
                let savedMB = String(format: "%.1f", Double(spaceSaved) / (1024.0 * 1024.0))
                await NotificationManager.shared.addMessage(
                    .info, String(localized: "Library optimized - reclaimed \(savedMB) MB")
                )
            } else {
                await NotificationManager.shared.addMessage(.info, String(localized: "Library optimized"))
            }
        case "v9_background_rebuild_artist_associations":
            if succeeded {
                await NotificationManager.shared.addMessage(
                    .info, String(localized: "Artists information updated successfully")
                )
            } else {
                await NotificationManager.shared.addMessage(.error, String(localized: "Failed to update artists information"))
            }
        default:
            break
        }
    }

    static func artworkNeedsHEICConversion(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) else { return true }
        // A legacy UUID cursor restarts its table; re-encoding HEIC would degrade already converted covers.
        return type as String != UTType.heic.identifier && type as String != UTType.heif.identifier
    }

    private func migrateArtwork(_ identifier: String) async throws {
        while true {
            try Task.checkCancellation()
            let batch = try core.backgroundArtworkBatch(identifier: identifier)
            if batch.done {
                if identifier == "v8_background_convert_artwork_to_heic" { try core.vacuum() }
                try core.completeBackgroundMigration(identifier: identifier, now: Date().timeIntervalSince1970)
                return
            }
            let updates = batch.items.compactMap { item -> BackgroundArtworkUpdate? in
                let data: Data?
                let original = Data(item.original)
                switch identifier {
                case "v8_background_convert_artwork_to_heic":
                    guard Self.artworkNeedsHEICConversion(original) else { return nil }
                    data = ImageUtils.compressImage(from: original, source: "\(batch.table): \(item.label)")
                case "v13_background_fill_artwork_thumbnail":
                    guard item.thumbnail == nil else { return nil }
                    data = ImageUtils.makeThumbnail(from: original, source: "\(batch.table): \(item.label)")
                default:
                    if let thumbnail = item.thumbnail, ImageUtils.isJPEG(Data(thumbnail)) { return nil }
                    data = ImageUtils.makeThumbnail(from: original, source: "\(batch.table): \(item.label)")
                }
                guard let data else { return nil }
                return BackgroundArtworkUpdate(id: item.id, original: item.original, data: data)
            }
            try core.commitBackgroundArtwork(
                identifier: identifier, table: batch.table, updates: updates, progress: batch.progress
            )
            await NotificationManager.shared.updateActivityProgress(
                current: Int(batch.processed), total: Int(batch.total)
            )
        }
    }

    func hasPendingBackgroundMigrations() -> Bool {
        do { return try core.hasPendingBackgroundMigrations() } catch {
            Logger.error("Failed to read pending migrations: \(error)")
            return false
        }
    }

    func isActiveBackgroundMigrationResumable() -> Bool {
        (try? core.isPendingMigrationResumable()) ?? true
    }

    func updateMigrationProgress(_ identifier: String, progress: String) {
        do { try core.updateMigrationProgress(identifier: identifier, progress: progress) } catch {
            Logger.error("Failed to update migration progress: \(error)")
        }
    }

    func completeBackgroundMigration(_ identifier: String) {
        do { try core.completeBackgroundMigration(identifier: identifier, now: Date().timeIntervalSince1970) } catch {
            Logger.error("Failed to complete migration: \(error)")
        }
    }
}
