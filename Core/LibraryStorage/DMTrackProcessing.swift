//
// DatabaseManager class extension
//
// This extension contains methods for track processing as found from folders added.
//

import Foundation
import PetrichorCore

/// Lazily loads and caches artwork from file paths for deferred artwork loading on slow filesystems
actor LazyArtworkLoader {
    private let artworkPaths: [URL: URL]
    private var cache: [URL: Data] = [:]

    init(artworkPaths: [URL: URL]) {
        self.artworkPaths = artworkPaths
    }

    func getArtwork(for directory: URL) -> Data? {
        // Return cached result
        if let cached = cache[directory] {
            return cached
        }

        // Load from file path if available
        guard let fileURL = artworkPaths[directory],
              let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else {
            return nil
        }

        if size > AlbumArtFormat.maxArtworkSize {
            Logger.warning("Skipping oversized artwork: \(fileURL.lastPathComponent) (\(size) bytes)")
            return nil
        }

        guard let data = try? Data(contentsOf: fileURL) else {
            return nil
        }

        let compressed = ImageUtils.compressImage(from: data, source: fileURL.path) ?? data
        cache[directory] = compressed
        return compressed
    }
}

extension DatabaseManager {
    func processBatch(
        _ batch: [(url: URL, folderId: Int64)],
        artworkMap: [URL: Data] = [:], artworkPaths: [URL: URL] = [:],
        hardRefresh: Bool = false, existingTracksByPath: [String: Track] = [:],
        scanState: ScanState? = nil, folderName: String? = nil,
        totalFilesInFolder: Int? = nil, globalScanState: GlobalScanState? = nil
    ) async throws {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let maxConcurrent: Int
        if #available(macOS 15, *) { maxConcurrent = max(4, cores) }
        else { maxConcurrent = max(2, cores / 2) }
        for chunk in batch.chunked(into: 100) {
            let cache = ArtworkCompressionCache()
            let lazy = artworkPaths.isEmpty ? nil : LazyArtworkLoader(artworkPaths: artworkPaths)
            let prepared = await withTaskGroup(of: (TrackImport?, URL, String?).self) { group in
                var iterator = chunk.makeIterator()
                var results: [TrackImport] = []
                var failures: [(URL, String)] = []
                func enqueue(_ item: (url: URL, folderId: Int64)) {
                    group.addTask {
                        do {
                            let file = self.observeLibraryFile(item.url)
                            guard try self.core.trackNeedsIngest(path: file.path, modified: file.modified, hard: hardRefresh) else { return (nil, item.url, nil) }
                            let directory = item.url.deletingLastPathComponent()
                            var art = artworkMap[directory]
                            if art == nil, let lazy { art = await lazy.getArtwork(for: directory) }
                            let metadata = await MetadataEngine.extractMetadata(from: item.url, externalArtwork: art, artworkCache: cache)
                            return (try self.trackImport(from: metadata, at: item.url, folderId: item.folderId), item.url, nil)
                        } catch { return (nil, item.url, String(describing: error)) }
                    }
                }
                for _ in 0..<maxConcurrent { if let item = iterator.next() { enqueue(item) } }
                while let (input, url, error) = await group.next() {
                    if let input { results.append(input) }
                    if let error { failures.append((url, error)) }
                    if let item = iterator.next() { enqueue(item) }
                }
                return (imports: results, failures: failures)
            }
            let result = try core.ingestTracks(tracks: prepared.imports, hard: hardRefresh, now: Date().timeIntervalSince1970)
            for (path, error) in zip(result.failedPaths, result.errors) {
                Logger.error("Failed to ingest \(path): \(error)")
            }
            if let scanState {
                await scanState.incrementProcessed(by: chunk.count)
                let failures = zip(result.failedPaths, result.errors).map {
                    (url: URL(fileURLWithPath: $0.0), error: DatabaseError.scanFailed($0.1) as Error)
                } + prepared.failures.map { (url: $0.0, error: DatabaseError.scanFailed($0.1) as Error) }
                await scanState.addFailedFiles(failures)
                if let globalScanState {
                    await globalScanState.incrementProcessed(by: chunk.count)
                    await globalScanState.incrementTracksAdded(by: Int(result.added))
                    let progress = await globalScanState.getProgress()
                    await scanActivity.updateStatus("Processing: \(progress.processed) files")
                    await MainActor.run {
                        NotificationManager.shared.updateActivityProgress(
                            current: progress.processed, total: progress.total > 0 ? progress.total : progress.processed,
                            detail: self.scanProgressDetail(progress)
                        )
                        if progress.isInitial { NotificationCenter.default.post(name: .checkInitialScanThreshold, object: nil) }
                    }
                } else if let folderName, let totalFilesInFolder {
                    let current = await scanState.getProcessedCount()
                    await MainActor.run { self.scanActivity.scanStatusMessage = "Processing: \(current)/\(totalFilesInFolder) files in \(folderName)" }
                }
            }
        }
    }

    func detectAndMarkDuplicates() async {
        do { _ = try core.detectAndMarkDuplicates() }
        catch { Logger.error("Failed to detect duplicates: \(error)") }
    }
}
