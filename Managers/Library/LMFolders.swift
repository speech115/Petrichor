//
// LibraryManager class extension
//
// This extension contains methods for folder management in the library,
// the methods internally also use DatabaseManager methods to work with database.
//

import Foundation
#if os(macOS)
import AppKit
#endif

extension LibraryManager {
    #if os(macOS)
    func addFolder() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = true
        openPanel.prompt = String(localized: "Add Music Folder")
        openPanel.message = String(localized: "Select folders containing your music files")

        guard let keyWindow = NSApp.keyWindow else {
            Logger.error("Cannot add folder: no key window available")
            return
        }

        openPanel.beginSheetModal(for: keyWindow) { [weak self] response in
            guard let self = self, response == .OK else { return }

            var urlsToAdd: [URL] = []
            var bookmarkDataMap: [URL: Data] = [:]

            for url in openPanel.urls {
                // Create security bookmark
                do {
                    let bookmarkData = try url.bookmarkData(
                        options: [.withSecurityScope],
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )
                    urlsToAdd.append(url)
                    bookmarkDataMap[url] = bookmarkData
                    Logger.info("Created bookmark for folder - \(url.lastPathComponent) at \(url.path)")
                } catch {
                    Logger.error("Failed to create security bookmark for \(url.path): \(error)")
                }
            }

            // Add folders to database with their bookmarks
            if !urlsToAdd.isEmpty {
                self.databaseManager.addFolders(urlsToAdd, bookmarkDataMap: bookmarkDataMap) { result in
                    switch result {
                    case .success(let dbFolders):
                        Logger.info("Successfully added \(dbFolders.count) folders to database")
                        self.scheduleLibraryReload()
                    case .failure(let error):
                        Logger.error("Failed to add folders to database: \(error)")
                    }
                }
            }
        }
    }
    #endif

    func removeFolder(_ folder: Folder) {
        Logger.info("Removing folder: \(folder.name)")
        
        databaseManager.removeFolder(folder) { [weak self] result in
            guard let self = self else { return }
            
            switch result {
            case .success:
                Logger.info("Successfully removed folder: \(folder.name)")
                // Remove from local array
                self.folders.removeAll { $0.id == folder.id }
                // Reload library immediately
                self.refreshLibraryCategories()
                self.loadMusicLibrary()
                // Stop the activity indicator
                NotificationManager.shared.stopActivity()
                
            case .failure(let error):
                Logger.error("Failed to remove folder: \(error)")
                // Stop the activity indicator on failure too
                NotificationManager.shared.stopActivity()
                // Show error message
                NotificationManager.shared.addMessage(.error, String(localized: "Failed to remove folder '\(folder.name)'"))
            }
        }
    }

    func refreshFolder(_ folder: Folder, hardRefresh: Bool = false) {
        // First, ensure we have a valid bookmark
        Task { [weak self] in
            guard let self = self else { return }

            // Every successful start must be paired with a stop; track whether we took a ref.
            let startedAccess = folder.bookmarkData != nil
                && folder.url.startAccessingSecurityScopedResource()
            if !startedAccess {
                await self.refreshBookmarkForFolder(folder)
            }

            // Show the indicator before counting: enumerating a large folder can take
            // a moment, and refreshLibrary() starts activity before counting too.
            await MainActor.run {
                NotificationManager.shared.startActivity(String(localized: "Refreshing \(folder.name)..."))
            }

            // Pre-count files so the progress bar can advance (needs a
            // GlobalScanState); skip on slow filesystems, like refreshLibrary().
            let isSlowFS = FilesystemUtils.isSlowFilesystem(url: folder.url)
            let totalFiles = isSlowFS
                ? 0
                : await self.databaseManager.countFilesInFolder(
                    folder,
                    supportedExtensions: AudioFormat.supportedExtensions
                )
            let globalScanState = GlobalScanState(totalFiles: totalFiles)

            // startActivity() above cleared progress; set the initial total now that
            // we know it (the first update always passes the throttle after a start).
            await MainActor.run {
                NotificationManager.shared.updateActivityProgress(
                    current: 0,
                    total: totalFiles,
                    detail: totalFiles > 0 ? String(localized: "0 of \(totalFiles) files") : String(localized: "Preparing files...")
                )
            }

            // completion runs on the main actor (see DMFolders.refreshFolder)
            self.databaseManager.refreshFolder(
                folder,
                hardRefresh: hardRefresh,
                manageActivityIndicator: false,
                globalScanState: globalScanState
            ) { result in
                if startedAccess { folder.url.stopAccessingSecurityScopedResource() }
                NotificationManager.shared.stopActivity()
                switch result {
                case .success:
                    Logger.info("Successfully refreshed folder \(folder.name)")
                    // Reload the library to reflect changes
                    self.refreshLibraryCategories()
                    self.loadMusicLibrary()
                case .failure(let error):
                    Logger.error("Failed to refresh folder \(folder.name): \(error)")
                }
            }
        }
    }

    /// Import a phone-side `playback-journal.jsonl`, then refresh smart playlists
    /// so Top 25 / Favorites reflect the new counts without a full library reload.
    @discardableResult
    func applyPlaybackJournal(from fileURL: URL) throws -> PlaybackJournalApplyResult {
        let summary = try PlaybackJournalApplier.apply(
            fileURL: fileURL,
            databaseManager: databaseManager
        )
        AppCoordinator.shared?.playlistManager.updateSmartPlaylists()
        return summary
    }

    func optimizeDatabase(notifyUser: Bool = false) {
        let sizeBefore = DatabaseFactory.databaseFileSize() ?? 0
        var foldersToRemove: [Folder] = []
            
        for folder in folders where !fileManager.fileExists(atPath: folder.url.path) {
            foldersToRemove.append(folder)
        }
        
        if foldersToRemove.isEmpty {
            Logger.info("No missing folders found during optimization")
            
            if notifyUser {
                performDatabaseOptimization(sizeBefore: sizeBefore, context: "optimization")
            }
            return
        }
        
        Logger.info("Found \(foldersToRemove.count) missing folders to optimize")
        NotificationManager.shared.startActivity(String(localized: "Optimizing database..."))
        
        let group = DispatchGroup()
        var removedFolders: [String] = []
        var failedRemovals: [String] = []
        
        for folder in foldersToRemove {
            group.enter()
            databaseManager.removeFolder(folder) { result in
                switch result {
                case .success:
                    Logger.info("Successfully removed missing folder: \(folder.name)")
                    removedFolders.append(folder.name)
                case .failure(let error):
                    Logger.error("Failed to remove missing folder \(folder.name): \(error)")
                    failedRemovals.append(folder.name)
                }
                group.leave()
            }
        }
        
        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            
            NotificationManager.shared.stopActivity()
            
            if !removedFolders.isEmpty {
                let message = removedFolders.count == 1
                    ? String(localized: "Folder '\(removedFolders[0])' was removed as it no longer exists")
                    : String(localized: "\(removedFolders.count) folders were removed as they no longer exist")
                NotificationManager.shared.addMessage(.info, message)
            }
            
            if !failedRemovals.isEmpty {
                let message = String(localized: "Failed to remove \(failedRemovals.count) missing folders")
                NotificationManager.shared.addMessage(.error, message)
            }
            
            self.performDatabaseOptimization(sizeBefore: sizeBefore, context: "optimization after folder cleanup")
            self.refreshLibraryCategories()
            self.loadMusicLibrary()
        }
    }

    func refreshBookmarkForFolder(_ folder: Folder) async {
        // Only refresh if we can access the folder. iCloud Drive items may be
        // cloud-only and report as missing until downloaded, so request the
        // download first and fall back to a path check.
        if FileManager.default.isUbiquitousItem(at: folder.url) {
            do {
                try FileManager.default.startDownloadingUbiquitousItem(at: folder.url)
                Logger.info("Requested iCloud download for \(folder.name)")
            } catch {
                Logger.error("Failed to request iCloud download for \(folder.name): \(error)")
            }
            // Give iCloud a moment to materialize the item before bookmarking.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }

        guard FileManager.default.fileExists(atPath: folder.url.path) else {
            Logger.warning("Folder no longer exists at \(folder.url.path)")
            return
        }

        do {
            // Create a fresh bookmark
            let newBookmarkData = try folder.url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )

            // Update the folder with new bookmark
            var updatedFolder = folder
            updatedFolder.bookmarkData = newBookmarkData

            guard let folderId = folder.id else {
                Logger.error("Failed to refresh bookmark for \(folder.name): folder has no database ID")
                return
            }

            // Save to database
            try await databaseManager.updateFolderBookmark(folderId, bookmarkData: newBookmarkData)

            Logger.info("Successfully refreshed bookmark for \(folder.name)")
        } catch {
            Logger.error("Failed to refresh bookmark for \(folder.name): \(error)")
        }
    }
    
    // MARK: - Private Helpers
    
    private func performDatabaseOptimization(sizeBefore: Int64, context: String) {
        Task {
            do {
                try await databaseManager.cleanupOrphanedData()
                try await databaseManager.vacuumDatabase()
                try await databaseManager.analyzeDatabase()
                
                // Get database size after optimization and calculate savings
                let sizeAfter = DatabaseFactory.databaseFileSize() ?? 0
                let spaceSaved = max(0, sizeBefore - sizeAfter)
                
                Logger.info("Database \(context) completed")
                
                await MainActor.run {
                    refreshEntities()
                    updateTotalCounts()
                    
                    if spaceSaved > 0 {
                        let savedMB = Double(spaceSaved) / (1024.0 * 1024.0)
                        NotificationManager.shared.addMessage(
                            .info,
                            String(localized: "Database optimization completed - reclaimed \(String(format: "%.1f", savedMB)) MB")
                        )
                    } else {
                        NotificationManager.shared.addMessage(.info, String(localized: "Database optimization completed"))
                    }
                }
            } catch {
                Logger.error("Database \(context) failed: \(error)")
                await MainActor.run {
                    NotificationManager.shared.addMessage(.error, String(localized: "Database optimization failed"))
                }
            }
        }
    }
}
