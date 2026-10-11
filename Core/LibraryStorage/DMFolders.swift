//
// DatabaseManager class extension
//
// This extension contains all the folder management methods which allow mapping folders in the app
// and create corresponding records in `folders` table in the db, and scanning folders for tracks.
//

import Foundation
import GRDB
import PetrichorCore

actor ScanState {
    var processedCount = 0
    var failedFiles: [(url: URL, error: Error)] = []
    var skippedFiles: [(url: URL, extension: String)] = []

    func incrementProcessed(by count: Int) {
        processedCount += count
    }

    func addFailedFiles(_ files: [(url: URL, error: Error)]) {
        failedFiles.append(contentsOf: files)
    }

    func addSkippedFiles(_ files: [(url: URL, extension: String)]) {
        skippedFiles.append(contentsOf: files)
    }

    func getProcessedCount() -> Int { processedCount }
    func getFailedFiles() -> [(url: URL, error: Error)] { failedFiles }
    func getSkippedFiles() -> [(url: URL, extension: String)] { skippedFiles }
}

struct GlobalScanProgress {
    let processed: Int
    let total: Int
    let added: Int
    let isInitial: Bool
}

actor GlobalScanState {
    let totalFiles: Int
    let isInitialScan: Bool
    var processedFiles = 0
    var tracksAdded = 0

    init(totalFiles: Int, isInitialScan: Bool = false) {
        self.totalFiles = totalFiles
        self.isInitialScan = isInitialScan
    }

    func incrementProcessed(by count: Int) {
        processedFiles += count
    }

    func incrementTracksAdded(by count: Int) {
        tracksAdded += count
    }

    func getProgress() -> GlobalScanProgress {
        GlobalScanProgress(
            processed: processedFiles,
            total: totalFiles,
            added: tracksAdded,
            isInitial: isInitialScan
        )
    }
}

/// Result of a single-pass folder enumeration
struct FolderEnumerationResult {
    let musicFiles: [URL]
    let unsupportedFiles: [(url: URL, extension: String)]
    let artworkMap: [URL: Data]
    let artworkPaths: [URL: URL]   // directory -> artwork file URL (for deferred loading on slow FS)
    let failedPaths: [String]
}

extension DatabaseManager {
    func folderRefreshNeedsHash(hardRefresh: Bool, timestampChanged: Bool, storedHash: String?) -> Bool {
        PetrichorCore.folderRefreshNeedsHash(hardRefresh: hardRefresh, timestampChanged: timestampChanged, storedHash: storedHash)
    }

    func folderNeedsRefresh(
        hardRefresh: Bool, timestampChanged: Bool, storedHash: String?, currentHash: String?
    ) -> Bool {
        PetrichorCore.folderNeedsRefresh(hardRefresh: hardRefresh, timestampChanged: timestampChanged, storedHash: storedHash, currentHash: currentHash)
    }

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

        let observations = urls.map { url in
            let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            return FolderObservation(
                path: LibraryPathStore.storedPath(for: url), name: url.lastPathComponent,
                bookmark: bookmarkDataMap[url], modified: modified?.timeIntervalSince1970
            )
        }
        let addedFolders = try records(core.addFolders(folders: observations, now: Date().timeIntervalSince1970), as: Folder.self)
        // Announce the initial scan before publishing folders.
        guard let countRow = try rows(core.libraryStatistic(kind: .trackCount, hideDuplicates: false)).first else {
            throw DatabaseError.scanFailed("Missing library track count")
        }
        let existingTrackCount: Int = countRow["value"]
        let isInitialScan = existingTrackCount == 0

        await MainActor.run {
            if isInitialScan {
                NotificationCenter.default.post(name: .initialScanStarted, object: nil)
            }
            NotificationCenter.default.post(name: .foldersAddedToDatabase, object: addedFolders)
        }

        if !addedFolders.isEmpty {
            try await scanFoldersForTracks(addedFolders, showActivityInTray: true, isInitialScan: isInitialScan)
        }

        await MainActor.run {
            self.scanActivity.finishScan()

            if isInitialScan {
                NotificationCenter.default.post(name: .initialScanCompleted, object: nil)
            }
        }

        // Wait for DB operations to finish before notifying scan completion
        if !isInitialScan {
            await MainActor.run {
                NotificationCenter.default.post(name: .libraryDataDidChange, object: nil)
            }
        }

        return addedFolders
    }

    func getAllFolders() -> [Folder] {
        do {
            return try records(core.allFolders(), as: Folder.self)
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

                loadScanArtists()
                // Balanced unload on every exit path (success or throw) so the retain count
                // can't leak or double-decrement a concurrent scan's data.
                defer { unloadScanArtists() }

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
                try core.finalizeLibraryScan(now: Date().timeIntervalSince1970)

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
                if let id = folder.id { try core.removeFolder(id: id) }

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
            throw DatabaseError.invalidFolderId
        }

        let oldPath = LibraryPathStore.storedPath(for: folder.url)
        let newURL = resolvedURL.standardizedFileURL
        let newPath = LibraryPathStore.storedPath(for: newURL)
        guard oldPath != newPath else { return folder }

        return try records(core.relocateFolder(
            id: folderId, oldPath: oldPath, newPath: newPath,
            newName: newURL.lastPathComponent, bookmark: bookmarkData
        ), as: Folder.self).first ?? folder
    }

    func updateFolderBookmark(_ folderId: Int64, expectedPath: String, bookmarkData: Data) async throws {
        try core.updateFolderBookmark(id: folderId, expectedPath: expectedPath, bookmark: bookmarkData)
    }

    func updateFolderMetadata(_ folderId: Int64) async throws {
        guard let folder = try records(core.folder(id: folderId), as: Folder.self).first else { return }
        let hash = await FilesystemUtils.computeFolderHash(for: folder.url)
        let modified = (try? FileManager.default.attributesOfItem(atPath: folder.url.path))?[.modificationDate] as? Date
        try core.updateFolderMetadata(id: folderId, modified: (modified ?? Date()).timeIntervalSince1970,
                                      hash: hash, countDuplicates: false)
    }

    func countFilesInFolder(_ folder: Folder, supportedExtensions: [String]) async -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: folder.url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return 0 }

        var files: [LibraryFileObservation] = []
        while let url = enumerator.nextObject() as? URL { files.append(observeLibraryFile(url)) }
        return (try? core.classifyLibraryFiles(files: files, supported: supportedExtensions,
                    unsupported: [], artExtensions: [], artNames: [], rootAvailable: true).audioPaths.count) ?? 0
    }

    /// Cheap change detection for reconciliation: enumerates audio file names and
    /// modification dates under `root` and compares them against the database
    /// without reading file contents, decoding metadata, or touching artwork.
    /// - Returns: true when a file is new or its mtime changed since the scan,
    ///   i.e. a full scan is required. Files absent from disk are not a change:
    ///   the database keeps their rows on purpose (see ADR-0001).
    func libraryContentsDiffer(from root: URL) async -> Bool {
        do {
            let enumeration = try enumerateFolderContents(from: root, supportedExtensions: AudioFormat.supportedExtensions)
            let files = enumeration.musicFiles.map { observeLibraryFile($0) }
            return try core.libraryContentsDiffer(files: files, tolerance: TimeConstants.filesystemMtimeTolerance)
        } catch {
            Logger.error("Failed to compare library contents: \(error)")
            return true
        }
    }

    func scanFoldersForTracks(
        _ folders: [Folder],
        showActivityInTray: Bool = true,
        isInitialScan: Bool = false
    ) async throws {
        let supportedExtensions = AudioFormat.supportedExtensions
        let totalFolders = folders.count

        if showActivityInTray && totalFolders > 0 {
            await MainActor.run {
                let message = isInitialScan
                    ? String(localized: "Scanning your music library...")
                    : String(localized: "Scanning \(totalFolders) folders...")
                NotificationManager.shared.startActivity(message)
            }
        }

        // Count total files for progress tracking (skip on slow/network filesystems)
        let isSlowFS = folders.first.map { FilesystemUtils.isSlowFilesystem(url: $0.url) } ?? false
        var totalFiles = 0
        if !isSlowFS {
            for folder in folders {
                totalFiles += await countFilesInFolder(folder, supportedExtensions: supportedExtensions)
            }
        }
        let globalScanState = GlobalScanState(totalFiles: totalFiles, isInitialScan: isInitialScan)

        loadScanArtists()
        // Balanced unload on every exit path, including a throw from the post-scan steps below.
        defer { unloadScanArtists() }

        var processedFolders = 0

        for folder in folders {
            do {
                try await scanSingleFolder(
                    folder,
                    supportedExtensions: supportedExtensions,
                    globalScanState: globalScanState
                )
                processedFolders += 1
            } catch {
                Logger.error("Failed to scan folder \(folder.name): \(error)")
                await NotificationManager.shared.addMessage(.error, String(localized: "Failed to scan folder '\(folder.name)'"))
            }

            if processedFolders.isMultiple(of: 2) {
                await Task.yield()
            }
        }

        // Post-scan cleanup. Stats count non-duplicate tracks, so run after duplicate marking.
        try core.finalizeLibraryScan(now: Date().timeIntervalSince1970)

        await MainActor.run {
            self.scanActivity.scanStatusMessage = String(localized: "Scan complete")
            if showActivityInTray {
                NotificationManager.shared.stopActivity()
            }

            let completionMessage = isInitialScan
                ? String(localized: "Library scan complete: \(self.getTotalTrackCount()) tracks found")
                : String(localized: "Added \(totalFolders) folders to library")
            NotificationManager.shared.addMessage(.info, completionMessage)
        }
    }

    func updateFolderTrackCount(_ folder: Folder) async throws {
        if let id = folder.id {
            try core.updateFolderMetadata(id: id, modified: Date().timeIntervalSince1970,
                                          hash: nil, countDuplicates: true)
        }
    }

    func scanSingleFolder(
        _ folder: Folder,
        supportedExtensions: [String],
        hardRefresh: Bool = false,
        globalScanState: GlobalScanState? = nil
    ) async throws {
        guard let folderId = folder.id else {
            Logger.error("Folder has no ID")
            throw DatabaseError.invalidFolderId
        }

        let scanState = ScanState()

        // Single-pass enumeration: collect music files, unsupported files, and artwork
        let isSlowFS = FilesystemUtils.isSlowFilesystem(url: folder.url)
        let enumeration = try enumerateFolderContents(
            from: folder.url,
            supportedExtensions: supportedExtensions,
            deferArtworkLoading: isSlowFS
        )
        let musicFiles = enumeration.musicFiles
        let artworkMap = enumeration.artworkMap
        let artworkPaths = enumeration.artworkPaths

        // Upstream aborts here because its scan deletes rows for files it did
        // not see. This scan never deletes (ADR-0001), so unreadable entries
        // only cost those files; the readable rest is still added.
        if !enumeration.failedPaths.isEmpty {
            let sample = enumeration.failedPaths.prefix(3).joined(separator: ", ")
            Logger.warning("Incomplete scan of \(folder.name); skipped unreadable paths: \(sample)")
        }

        await scanState.addSkippedFiles(enumeration.unsupportedFiles)

        let artworkCount = artworkMap.count + artworkPaths.count
        if artworkCount > 0 {
            Logger.info("Found artwork in \(artworkCount) directories within \(folder.name)")
        }

        // Tracks whose file is gone from disk are not removed: the row
        // survives on purpose (ADR-0001). The scan only adds and updates.

        // If no music files found, we're done
        if musicFiles.isEmpty {
            try await updateFolderTrackCount(folder)
            return
        }

        // Process music files in batches
        try await processMusicFilesInBatches(
            musicFiles: musicFiles,
            folderId: folderId,
            artworkMap: artworkMap,
            artworkPaths: artworkPaths,
            folderName: folder.name,
            hardRefresh: hardRefresh,
            scanState: scanState,
            globalScanState: globalScanState
        )

        // Update metadata and report results
        try await finalizeScan(
            folderId: folderId,
            folder: folder,
            scanState: scanState
        )
    }
    // MARK: - Private Helpers

    /// Single-pass enumeration: collect music files, unsupported files, and folder artwork
    /// - Parameter deferArtworkLoading: When true (slow FS), collect artwork paths without reading files
    private func enumerateFolderContents(
        from folderURL: URL,
        supportedExtensions: [String],
        deferArtworkLoading: Bool = false
    ) throws -> FolderEnumerationResult {
        let fileManager = FileManager.default

        let rootValues: URLResourceValues
        do {
            rootValues = try folderURL.resourceValues(forKeys: [.isDirectoryKey, .isReadableKey])
        } catch {
            throw DatabaseError.scanFailed("Folder is unavailable or unreadable")
        }
        _ = try core.classifyLibraryFiles(files: [], supported: [], unsupported: [], artExtensions: [], artNames: [],
                                         rootAvailable: rootValues.isDirectory == true && rootValues.isReadable == true)

        var failedPaths: [String] = []
        guard let enumerator = fileManager.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { url, error in
                failedPaths.append(url.path)
                Logger.warning("Failed to enumerate \(url.path): \(error)")
                return true
            }
        ) else {
            throw DatabaseError.scanFailed("Unable to enumerate folder contents")
        }

        var observed: [LibraryFileObservation] = []
        while let fileURL = enumerator.nextObject() as? URL {
            observed.append(observeLibraryFile(fileURL))
        }

        let finalRootValues: URLResourceValues
        do {
            finalRootValues = try folderURL.resourceValues(forKeys: [.isDirectoryKey, .isReadableKey])
        } catch {
            throw DatabaseError.scanFailed("Folder became unavailable during scanning")
        }
        _ = try core.classifyLibraryFiles(files: [], supported: [], unsupported: [], artExtensions: [], artNames: [],
                                         rootAvailable: finalRootValues.isDirectory == true && finalRootValues.isReadable == true)

        let manifest = try core.classifyLibraryFiles(
            files: observed, supported: supportedExtensions,
            unsupported: observed.map(\.extension).filter { AudioFormat.isNotSupported($0) },
            artExtensions: observed.map(\.extension).filter { AlbumArtFormat.isSupported($0) },
            artNames: Array(AlbumArtFormat.knownFilenames), rootAvailable: true
        )
        let musicFiles = manifest.audioPaths.map { URL(fileURLWithPath: $0) }
        var artworkMap: [URL: Data] = [:]
        var artworkPaths: [URL: URL] = [:]
        for path in manifest.artworkPaths {
            let url = URL(fileURLWithPath: path)
            let directory = url.deletingLastPathComponent()
            if deferArtworkLoading { artworkPaths[directory] = url; continue }
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
                  size <= AlbumArtFormat.maxArtworkSize else { continue }
            if let data = try? Data(contentsOf: url) {
                artworkMap[directory] = ImageUtils.compressImage(from: data, source: path) ?? data
            } else { artworkPaths[directory] = url }
        }
        return FolderEnumerationResult(
            musicFiles: musicFiles,
            unsupportedFiles: manifest.unsupportedPaths.map {
                let url = URL(fileURLWithPath: $0)
                return (url: url, extension: url.pathExtension.lowercased())
            }, artworkMap: artworkMap, artworkPaths: artworkPaths,
            failedPaths: failedPaths + manifest.failedPaths
        )
    }

    func observeLibraryFile(_ url: URL) -> LibraryFileObservation {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
        return LibraryFileObservation(
            path: LibraryPathStore.storedPath(for: url), extension: url.pathExtension.lowercased(),
            basename: url.deletingPathExtension().lastPathComponent,
            regular: values?.isRegularFile == true,
            readable: FileManager.default.isReadableFile(atPath: url.path),
            size: values?.fileSize.map { Int64($0) }, modified: values?.contentModificationDate?.timeIntervalSince1970
        )
    }

    func scanProgressDetail(_ progress: GlobalScanProgress) -> String {
        let base = progress.total > 0
            ? String(localized: "\(progress.processed) of \(progress.total) files processed")
            : String(localized: "\(progress.processed) files processed")

        var changes: [String] = []
        if progress.added > 0 {
            changes.append(progress.isInitial
                ? String(localized: "\(progress.added) tracks found")
                : String(localized: "\(progress.added) new tracks found"))
        }

        guard !changes.isEmpty else { return base }
        return base + " • " + changes.joined(separator: " • ")
    }

    private func processMusicFilesInBatches(
        musicFiles: [URL],
        folderId: Int64,
        artworkMap: [URL: Data],
        artworkPaths: [URL: URL] = [:],
        folderName: String,
        hardRefresh: Bool = false,
        scanState: ScanState,
        globalScanState: GlobalScanState? = nil
    ) async throws {
        let totalFiles = musicFiles.count
        let batchSize = 500
        let fileBatches = musicFiles.chunked(into: batchSize)

        for batch in fileBatches {
            let batchWithFolderId = batch.map { url in (url: url, folderId: folderId) }

            do {
                try await processBatch(
                    batchWithFolderId,
                    artworkMap: artworkMap,
                    artworkPaths: artworkPaths,
                    hardRefresh: hardRefresh,
                            scanState: scanState,
                    folderName: folderName,
                    totalFilesInFolder: totalFiles,
                    globalScanState: globalScanState
                )
            } catch {
                let failures = batch.map { (url: $0, error: error) }
                await scanState.addFailedFiles(failures)
                Logger.error("Failed to process batch in folder \(folderName): \(error)")
            }
        }
    }

    /// Finalize the scan - update metadata, detect duplicates, and report results
    private func finalizeScan(
        folderId: Int64,
        folder: Folder,
        scanState: ScanState
    ) async throws {
        // Update folder metadata
        try await updateFolderMetadata(folderId)

        // Get final counts
        let processedCount = await scanState.getProcessedCount()
        let failedFiles = await scanState.getFailedFiles()
        let skippedFiles = await scanState.getSkippedFiles()

        // Report failed files
        if !failedFiles.isEmpty {
            await MainActor.run {
                let message = failedFiles.count == 1
                    ? String(localized: "Failed to process 1 file in '\(folder.name)'")
                    : String(localized: "Failed to process \(failedFiles.count) files in '\(folder.name)'")
                NotificationManager.shared.addMessage(.warning, message)
            }
        }

        // Report skipped files
        if !skippedFiles.isEmpty {
            let extensionCounts = Dictionary(grouping: skippedFiles) { $0.extension }
                .mapValues { $0.count }
                .sorted { $0.value > $1.value }

            let topExtensions = extensionCounts.prefix(3)
                .map { ".\($0.key.uppercased()) (\($0.value))" }
                .joined(separator: ", ")

            await MainActor.run {
                let message = skippedFiles.count == 1
                    ? String(localized: "1 file skipped in '\(folder.name)' - unsupported format")
                    : String(localized: "\(skippedFiles.count) files skipped in '\(folder.name)' - unsupported formats: \(topExtensions)")
                NotificationManager.shared.addMessage(.warning, message)
            }
        }

        Logger.info(
            """
            Completed scanning folder \(folder.name): \(processedCount) processed, \
            \(failedFiles.count) failed, \(skippedFiles.count) skipped
            """
        )
    }
}
