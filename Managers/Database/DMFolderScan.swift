//
// DatabaseManager class extension
//
// This extension contains the folder scan: counting and enumerating a folder's files, reading
// their metadata in batches and writing the tracks, with the progress state the scan reports.
//

import Darwin
import Foundation
import GRDB

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
    func countFilesInFolder(_ folder: Folder, supportedExtensions: [String]) async -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: folder.url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return 0 }
        
        var count = 0
        while let fileURL = enumerator.nextObject() as? URL {
            let ext = fileURL.pathExtension.lowercased()
            guard !ext.isEmpty, supportedExtensions.contains(ext),
                  let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true,
                  FileManager.default.isReadableFile(atPath: fileURL.path) else {
                continue
            }
            count += 1
        }
        return count
    }
    
    /// Cheap change detection for reconciliation: enumerates audio file names and
    /// modification dates under `root` and compares them against the database
    /// without reading file contents, decoding metadata, or touching artwork.
    /// - Returns: true when a file is new or its mtime changed since the scan,
    ///   i.e. a full scan is required. Files absent from disk are not a change:
    ///   the database keeps their rows on purpose (see ADR-0001).
    func libraryContentsDiffer(from root: URL) async -> Bool {
        // This runs on every launch and every return to the foreground; the
        // full-tree walk below is the suspect cost. Log how long the check
        // takes so a real device number (not a first-scan conflation) drives
        // any later throttling or cheaper pre-check.
        let checkStart = Date()
        defer {
            let elapsedMs = Date().timeIntervalSince(checkStart) * 1000
            Logger.info(String(format: "libraryContentsDiffer took %.0f ms", elapsedMs))
        }

        let supportedExtensions = Set(AudioFormat.supportedExtensions.map { $0.lowercased() })
        let tolerance = TimeConstants.filesystemMtimeTolerance

        // What the database knows: stored relative path -> mtime at scan time.
        // GRDB stores dates as SQL text; SQLite converts them to Unix seconds
        // in the query instead of a Swift `Date` decode per row.
        let stored: [String: TimeInterval]
        do {
            stored = try await dbQueue.read { db in
                var result: [String: TimeInterval] = [:]
                let rows = try Row.fetchCursor(
                    db,
                    sql: "SELECT path, (julianday(date_modified) - 2440587.5) * 86400.0 AS mtime FROM tracks"
                )
                while let row = try rows.next() {
                    result[row["path"]] = row["mtime"] ?? 0
                }
                return result
            }
        } catch {
            Logger.error("Failed to read stored track timestamps: \(error)")
            return true
        }

        // What the filesystem has right now, walked with fts(3): each entry
        // arrives with its lstat from the directory read. The URL enumerator
        // plus a per-file lstat and URL standardization cost ~30x more
        // (158 ms -> 5 ms for the 2,900-file library on a Mac; seconds on the
        // phone). Every path starts with the root exactly as passed, so the
        // stored relative path is that prefix stripped.
        // ponytail: hidden entries are skipped like FileManager's
        // .skipsHiddenFiles, but package directories are descended; add a
        // package check if bundles ever appear in Documents.
        let rootPath = root.standardizedFileURL.path
        let prefixLength = rootPath.utf8.count + (rootPath.hasSuffix("/") ? 0 : 1)
        let stream = rootPath.withCString { path -> UnsafeMutablePointer<FTS>? in
            var roots: [UnsafeMutablePointer<CChar>?] = [strdup(path), nil]
            defer { free(roots[0]) }
            return fts_open(&roots, FTS_PHYSICAL | FTS_NOCHDIR, nil)
        }
        guard let stream else {
            Logger.error("Failed to enumerate library root: \(root.path)")
            return true
        }
        defer { fts_close(stream) }

        while let entry = fts_read(stream) {
            let info = Int32(entry.pointee.fts_info)
            let fullPath = String(cString: entry.pointee.fts_path)
            let nameStart = fullPath.lastIndex(of: "/").map(fullPath.index(after:)) ?? fullPath.startIndex
            if entry.pointee.fts_level > 0, fullPath[nameStart...].hasPrefix(".") {
                if info == FTS_D { fts_set(stream, entry, Int32(FTS_SKIP)) }
                continue
            }
            guard info == FTS_F || info == FTS_SL || info == FTS_NS else { continue }
            guard let dot = fullPath.lastIndex(of: "."),
                  supportedExtensions.contains(fullPath[fullPath.index(after: dot)...].lowercased()) else { continue }
            guard info != FTS_NS, let fileInfo = entry.pointee.fts_statp?.pointee else {
                Logger.error("Failed to read modification date: \(fullPath)")
                return true
            }
            // The prefix ends at "/", always a character boundary.
            let path = String(fullPath.utf8.dropFirst(prefixLength)) ?? fullPath
            let diskDate = TimeInterval(fileInfo.st_mtimespec.tv_sec)
                + TimeInterval(fileInfo.st_mtimespec.tv_nsec) / 1_000_000_000

            // Any file on disk that the database does not know, or whose
            // mtime changed since the scan, needs a scan. Tracks absent from
            // disk remain a steady state by design (ADR-0001).
            guard let storedDate = stored[path] else {
                Logger.info("Library differs: new file \(path)")
                return true
            }
            let difference = abs(diskDate - storedDate)
            guard difference <= tolerance else {
                Logger.info(
                    String(
                        format: "Library differs: mtime %@ disk=%.3f stored=%.3f delta=%.3f",
                        path,
                        diskDate,
                        storedDate,
                        difference
                    )
                )
                return true
            }
        }

        return false
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
        
        ArtistParser.loadKnownArtists()
        // Balanced unload on every exit path, including a throw from the post-scan steps below.
        defer { ArtistParser.unloadKnownArtists() }

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
        do {
            try await normalizeCompilationAlbums()
            await detectAndMarkDuplicates()
            try await dbQueue.write { db in
                try self.updateEntityStats(in: db)
            }
            try await cleanupOrphanedData()
        } catch {
            if showActivityInTray {
                await MainActor.run { NotificationManager.shared.stopActivity() }
            }
            throw error
        }

        await MainActor.run {
            self.scanActivity.scanStatusMessage = String(localized: "Scan complete")
            if showActivityInTray {
                NotificationManager.shared.stopActivity()
            }
            
            // A rescan of the existing library folder (iOS reconciliation)
            // comes through here too, so "added N folders" was wrong there;
            // the track total holds for every path.
            let completionMessage = String(localized: "Library scan complete: \(self.getTotalTrackCount()) tracks found")
            NotificationManager.shared.addMessage(.info, completionMessage)
        }
    }
    
    func updateFolderTrackCount(_ folder: Folder) async throws {
        try await dbQueue.write { db in
            let count = try Track
                .filter(Track.Columns.folderId == folder.id)
                .fetchCount(db)

            var updatedFolder = folder
            updatedFolder.trackCount = count
            updatedFolder.dateUpdated = Date()
            try updatedFolder.update(db)
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

        // Pre-fetch existing tracks for this folder to avoid per-file DB lookups
        let existingTracksByPath: [String: Track] = try await dbQueue.read { db in
            let tracks = try Track
                .filter(Track.Columns.folderId == folderId)
                .fetchAll(db)

            var tracksByPath: [String: Track] = [:]
            for track in tracks.sorted(by: { ($0.trackId ?? .max) < ($1.trackId ?? .max) }) {
                let path = LibraryPathStore.storedPath(for: track.url)
                if let existing = tracksByPath[path] {
                    Logger.warning(
                        "Duplicate normalized track path in folder \(folder.name): \(path) "
                            + "(keeping ID \(existing.trackId ?? -1), ignoring ID \(track.trackId ?? -1))"
                    )
                    continue
                }
                tracksByPath[path] = track
            }
            return tracksByPath
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
            existingTracksByPath: existingTracksByPath,
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
        guard rootValues.isDirectory == true, rootValues.isReadable == true else {
            throw DatabaseError.scanFailed("Folder is unavailable or unreadable")
        }

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

        var musicFiles: [URL] = []
        var unsupportedFiles: [(url: URL, extension: String)] = []
        var artworkMap: [URL: Data] = [:]
        var artworkPaths: [URL: URL] = [:]
        var directoriesWithArtwork: Set<URL> = []
        var musicPaths: Set<String> = []

        while let fileURL = enumerator.nextObject() as? URL {
            let fileExtension = fileURL.pathExtension.lowercased()
            let filename = fileURL.deletingPathExtension().lastPathComponent
            let isSupportedAudio = supportedExtensions.contains(fileExtension)
            let isArtwork = AlbumArtFormat.knownFilenames.contains(filename)
                && AlbumArtFormat.isSupported(fileExtension)
            let isUnsupportedAudio = AudioFormat.isNotSupported(fileExtension)
            guard isSupportedAudio || isArtwork || isUnsupportedAudio else { continue }

            let resourceValues: URLResourceValues
            do {
                resourceValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            } catch {
                failedPaths.append(fileURL.path)
                Logger.warning("Failed to inspect \(fileURL.path): \(error)")
                continue
            }

            guard resourceValues.isRegularFile == true else { continue }

            guard !fileExtension.isEmpty else { continue }

            if isSupportedAudio {
                guard fileManager.isReadableFile(atPath: fileURL.path) else {
                    failedPaths.append(fileURL.path)
                    Logger.warning("Audio file is unreadable: \(fileURL.path)")
                    continue
                }

                let path = fileURL.path
                if musicPaths.insert(path).inserted {
                    musicFiles.append(fileURL)
                } else {
                    Logger.warning("Skipping duplicate normalized file path while scanning: \(path)")
                }
            } else if isUnsupportedAudio {
                unsupportedFiles.append((url: fileURL, extension: fileExtension))
                Logger.info("Skipped unsupported audio file: \(fileURL.lastPathComponent) (.\(fileExtension))")
            }

            // Check for artwork files (cover.jpg, folder.png, etc.)
            let directory = fileURL.deletingLastPathComponent()
            if !directoriesWithArtwork.contains(directory) {
                if isArtwork {
                    directoriesWithArtwork.insert(directory)
                    if deferArtworkLoading {
                        // On slow FS, just record the path for lazy loading later
                        artworkPaths[directory] = fileURL
                    } else if let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                        if size > AlbumArtFormat.maxArtworkSize {
                            Logger.warning("Skipping oversized artwork: \(fileURL.lastPathComponent) (\(size) bytes)")
                        } else if let data = try? Data(contentsOf: fileURL) {
                            artworkMap[directory] = ImageUtils.compressImage(from: data, source: fileURL.path) ?? data
                        } else {
                            // Retry lazily during metadata extraction and preserve existing art if that also fails.
                            artworkPaths[directory] = fileURL
                        }
                    }
                }
            }
        }

        let finalRootValues: URLResourceValues
        do {
            finalRootValues = try folderURL.resourceValues(forKeys: [.isDirectoryKey, .isReadableKey])
        } catch {
            throw DatabaseError.scanFailed("Folder became unavailable during scanning")
        }
        guard finalRootValues.isDirectory == true, finalRootValues.isReadable == true else {
            throw DatabaseError.scanFailed("Folder became unavailable during scanning")
        }

        return FolderEnumerationResult(
            musicFiles: musicFiles,
            unsupportedFiles: unsupportedFiles,
            artworkMap: artworkMap,
            artworkPaths: artworkPaths,
            failedPaths: failedPaths
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
        existingTracksByPath: [String: Track],
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
                    existingTracksByPath: existingTracksByPath,
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
