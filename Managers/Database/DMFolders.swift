//
// DatabaseManager class extension
//
// This extension contains all the folder management methods which allow mapping folders in the app
// and create corresponding records in `folders` table in the db. Scanning folders for tracks lives
// in `DMFolderScan`.
//

import Darwin
import Foundation
import GRDB

private enum FolderRelocationError: LocalizedError {
    case missingFolderID
    case destinationAlreadyWatched(String)
    case trackOutsideFolder(String)
    case trackPathConflict(String)

    var errorDescription: String? {
        switch self {
        case .missingFolderID:
            return "Cannot relocate a folder without a database ID"
        case .destinationAlreadyWatched(let path):
            return "A watched folder already exists at \(path)"
        case .trackOutsideFolder(let path):
            return "Track path is outside its watched folder: \(path)"
        case .trackPathConflict(let path):
            return "A track already exists at the relocated path: \(path)"
        }
    }
}

extension DatabaseManager {
    func addFolders(
        _ urls: [URL],
        bookmarkDataMap: [URL: Data],
        completion: @escaping @MainActor @Sendable (Result<[Folder], Error>) -> Void
    ) {
        Task(priority: .utility) {
            do {
                let folders = try await addFoldersAsync(urls, bookmarkDataMap: bookmarkDataMap)
                await MainActor.run {
                    completion(.success(folders))
                }
            } catch {
                await MainActor.run {
                    completion(.failure(error))
                    Logger.error("Failed to add folders: \(error)")
                    NotificationManager.shared.addMessage(.error, String(localized: "Failed to add folders"))
                }
            }
        }
    }

    func addFoldersAsync(_ urls: [URL], bookmarkDataMap: [URL: Data]) async throws -> [Folder] {
        await MainActor.run {
            self.scanActivity.isScanning = true
            self.scanActivity.scanStatusMessage = String(localized: "Adding folders...")
        }

        // Every exit ends the scan; a throw used to leave the library stuck in "scanning".
        var isInitialScan = false
        do {
            let addedFolders = try await dbQueue.write { db -> [Folder] in
                var folders: [Folder] = []

                for url in urls {
                    let bookmarkData = bookmarkDataMap[url]
                    var folder = Folder(url: url, bookmarkData: bookmarkData)

                    // Get the file system modification date
                    if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                       let fsModDate = attributes[.modificationDate] as? Date {
                        folder.dateUpdated = fsModDate
                    }

                    // Check if folder already exists
                    if let existing = try Folder
                        .filter(Folder.Columns.path == LibraryPathStore.storedPath(for: url))
                        .fetchOne(db) {
                        // Update bookmark data if folder exists
                        var updatedFolder = existing
                        updatedFolder.bookmarkData = bookmarkData
                        try updatedFolder.update(db)
                        folders.append(updatedFolder)
                        Logger.info("Folder already exists: \(existing.name) with ID: \(existing.id ?? -1), updated bookmark")
                    } else {
                        // Insert new folder
                        try folder.insert(db)

                        // Fetch the inserted folder to get the generated ID
                        if let insertedFolder = try Folder
                            .filter(Folder.Columns.path == LibraryPathStore.storedPath(for: url))
                            .fetchOne(db) {
                            folders.append(insertedFolder)
                            Logger.info("Added new folder: \(insertedFolder.name) with ID: \(insertedFolder.id ?? -1)")
                        }
                    }
                }
            
                return folders
            }
        
            // Post .initialScanStarted before folders publish so the shell cannot flash
            // the main UI with an empty track list.
            let existingTrackCount = try await dbQueue.read { db in
                try Track.fetchCount(db)
            }
            isInitialScan = existingTrackCount == 0

            await MainActor.run { [isInitialScan] in
                if isInitialScan {
                    NotificationCenter.default.post(name: .initialScanStarted, object: nil)
                }
                NotificationCenter.default.post(name: .foldersAddedToDatabase, object: addedFolders)
            }

            if !addedFolders.isEmpty {
                try await scanFoldersForTracks(addedFolders, showActivityInTray: true, isInitialScan: isInitialScan)
            }

            await MainActor.run { [isInitialScan] in
                self.scanActivity.finishScan()
            
                if isInitialScan {
                    NotificationCenter.default.post(name: .initialScanCompleted, object: nil)
                }
            }
        
            // Wait for DB operations to finish before notifying scan completion
            try? await dbQueue.writeWithoutTransaction { _ in }
            if !isInitialScan {
                await MainActor.run {
                    NotificationCenter.default.post(name: .libraryDataDidChange, object: nil)
                }
            }

            return addedFolders
        } catch {
            await MainActor.run { [isInitialScan] in
                self.scanActivity.finishScan()
                if isInitialScan {
                    NotificationCenter.default.post(name: .initialScanCompleted, object: nil)
                }
            }
            throw error
        }
    }

    func getAllFolders() -> [Folder] {
        do {
            return try dbQueue.read { db in
                try Folder
                    .order(Folder.Columns.name)
                    .fetchAll(db)
            }
        } catch {
            Logger.error("Failed to fetch folders: \(error)")
            return []
        }
    }

    func refreshFolder(
        _ folder: Folder,
        hardRefresh: Bool = false,
        manageActivityIndicator: Bool = true,
        globalScanState: GlobalScanState? = nil,
        _ completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void
    ) {
        Task {
            do {
                await MainActor.run {
                    self.scanActivity.isScanning = true
                    self.scanActivity.scanStatusMessage = String(localized: "Refreshing \(folder.name)...")
                    if manageActivityIndicator {
                        NotificationManager.shared.startActivity(String(localized: "Refreshing \(folder.name)..."))
                    }
                }

                // Log the current state
                let trackCountBefore = getTrackCountForFolder(folder.id ?? -1)
                Logger.info("Starting refresh for folder \(folder.name) with \(trackCountBefore) tracks")

                ArtistParser.loadKnownArtists()
                // Balanced unload on every exit path (success or throw) so the retain count
                // can't leak or double-decrement a concurrent scan's data.
                defer { ArtistParser.unloadKnownArtists() }

                // Scan the folder - this will check for metadata updates
                try await scanSingleFolder(
                    folder,
                    supportedExtensions: AudioFormat.supportedExtensions,
                    hardRefresh: hardRefresh,
                    globalScanState: globalScanState
                )

                // Update folder's metadata
                if let folderId = folder.id {
                    try await updateFolderMetadata(folderId)
                }

                // Log the result
                let trackCountAfter = getTrackCountForFolder(folder.id ?? -1)
                Logger.info("Completed refresh for folder \(folder.name) with \(trackCountAfter) tracks (was \(trackCountBefore))")

                // Post-scan cleanup. Stats count non-duplicate tracks, so run after duplicate marking.
                try await normalizeCompilationAlbums()
                await detectAndMarkDuplicates()
                try await dbQueue.write { db in
                    try self.updateEntityStats(in: db)
                }
                try await cleanupOrphanedData()

                await MainActor.run {
                    self.scanActivity.finishScan()
                    if manageActivityIndicator {
                        NotificationManager.shared.stopActivity()
                    }
                    completion(.success(()))
                }
            } catch {
                await MainActor.run {
                    self.scanActivity.finishScan()
                    if manageActivityIndicator {
                        NotificationManager.shared.stopActivity()
                    }
                    completion(.failure(error))
                    Logger.error("Failed to refresh folder \(folder.name): \(error)")
                    NotificationManager.shared.addMessage(.error, String(localized: "Failed to refresh folder \(folder.name)"))
                }
            }
        }
    }

    func removeFolder(_ folder: Folder, completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void) {
        Task {
            do {
                _ = try await dbQueue.write { db in
                    // Delete the folder (cascades to tracks and junction tables)
                    try folder.delete(db)
                }
                
                // Now run comprehensive cleanup for any orphaned data
                try await cleanupOrphanedData()
                
                Logger.info("Removed folder '\(folder.name)' and cleaned up orphaned data")
                
                await MainActor.run {
                    completion(.success(()))
                }
            } catch {
                await MainActor.run {
                    completion(.failure(error))
                    Logger.error("Failed to remove folder '\(folder.name)': \(error)")
                    NotificationManager.shared.addMessage(.error, String(localized: "Failed to remove folder '\(folder.name)'"))
                }
            }
        }
    }

    /// Rebase a watched folder after its bookmark follows a filesystem rename.
    /// Existing IDs and scan metadata are preserved, so relocation does not re-ingest tracks.
    func relocateFolder(_ folder: Folder, to resolvedURL: URL, bookmarkData: Data) throws -> Folder {
        guard let folderId = folder.id else {
            throw FolderRelocationError.missingFolderID
        }

        let oldPath = LibraryPathStore.storedPath(for: folder.url)
        let newURL = resolvedURL.standardizedFileURL
        let newPath = LibraryPathStore.storedPath(for: newURL)
        guard oldPath != newPath else { return folder }

        return try dbQueue.write { db in
            let destinationIsWatched = try Folder
                .filter(Folder.Columns.path == newPath)
                .filter(Folder.Columns.id != folderId)
                .fetchCount(db) > 0
            guard !destinationIsWatched else {
                throw FolderRelocationError.destinationAlreadyWatched(newPath)
            }

            let tracks = try Track
                .select(Track.Columns.trackId, Track.Columns.path)
                .filter(Track.Columns.folderId == folderId)
                .asRequest(of: Row.self)
                .fetchAll(db)
            var relocatedTracks: [(id: Int64, path: String)] = []
            relocatedTracks.reserveCapacity(tracks.count)

            for track in tracks {
                let trackId: Int64 = track["id"]
                let trackPath: String = track["path"]
                guard let relocatedPath = rebasedPath(trackPath, from: oldPath, to: newPath) else {
                    throw FolderRelocationError.trackOutsideFolder(trackPath)
                }
                relocatedTracks.append((trackId, relocatedPath))
            }

            for chunk in relocatedTracks.chunked(into: 500) {
                let paths = chunk.map(\.path)
                let conflictingPath = try Track
                    .select(Track.Columns.path)
                    .filter(paths.contains(Track.Columns.path))
                    .filter(Track.Columns.folderId != folderId)
                    .asRequest(of: String.self)
                    .fetchOne(db)
                guard let conflictingPath else { continue }
                throw FolderRelocationError.trackPathConflict(conflictingPath)
            }

            let relocatedPathExpression = SQL(
                "\(newPath) || substr(\(Track.Columns.path), length(\(oldPath)) + 1)"
            ).sqlExpression
            try Track
                .filter(Track.Columns.folderId == folderId)
                .updateAll(db, Track.Columns.path.set(to: relocatedPathExpression))

            var relocatedFolder = Folder(url: newURL, id: folderId, bookmarkData: bookmarkData)
            relocatedFolder.trackCount = folder.trackCount
            relocatedFolder.dateAdded = folder.dateAdded
            relocatedFolder.dateUpdated = folder.dateUpdated
            relocatedFolder.shasumHash = folder.shasumHash
            try relocatedFolder.update(db)
            return relocatedFolder
        }
    }

    private func rebasedPath(_ path: String, from oldRoot: String, to newRoot: String) -> String? {
        if path == oldRoot {
            return newRoot
        }

        let descendantPrefix = oldRoot.hasSuffix("/") ? oldRoot : "\(oldRoot)/"
        guard path.hasPrefix(descendantPrefix) else { return nil }

        return URL(fileURLWithPath: newRoot, isDirectory: true)
            .appendingPathComponent(String(path.dropFirst(descendantPrefix.count)))
            .standardizedFileURL
            .path
    }

    func updateFolderBookmark(_ folderId: Int64, expectedPath: String, bookmarkData: Data) async throws {
        _ = try await dbQueue.write { db in
            try Folder
                .filter(Folder.Columns.id == folderId)
                .filter(Folder.Columns.path == expectedPath)
                .updateAll(db, Folder.Columns.bookmarkData.set(to: bookmarkData))
        }
    }
    
    func updateFolderMetadata(_ folderId: Int64) async throws {
        // First, get the folder and calculate hash outside the database transaction
        let folderData = try await dbQueue.read { db in
            try Folder.fetchOne(db, key: folderId)
        }
        
        guard let folder = folderData else { return }
        
        let hash = await FilesystemUtils.computeFolderHash(for: folder.url)
        
        try await dbQueue.write { db in
            guard var folder = try Folder.fetchOne(db, key: folderId) else { return }
            
            // Get and store the file system's modification date
            if let attributes = try? FileManager.default.attributesOfItem(atPath: folder.url.path),
               let fsModDate = attributes[.modificationDate] as? Date {
                folder.dateUpdated = fsModDate
            } else {
                // Fallback to current date if we can't get FS date
                folder.dateUpdated = Date()
            }
            
            // Store the calculated hash
            if let hash = hash {
                folder.shasumHash = hash
                Logger.info("Updated hash for folder \(folder.name)")
            } else {
                Logger.warning("Failed to calculate hash for folder \(folder.name)")
            }
            
            // Update track count
            let trackCount = try Track
                .filter(Track.Columns.folderId == folderId)
                .filter(Track.Columns.isDuplicate == false)
                .fetchCount(db)
            folder.trackCount = trackCount
            
            try folder.update(db)
        }
    }
}
