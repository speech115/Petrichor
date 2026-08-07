//
// LibraryManager class extension (iOS)
//
// iOS-side reconciliation: the library *is* the app's own `Documents`
// folder. Importing a folder picked via `fileImporter`, background
// reconciliation on launch/foreground, the forced rescan, and the M3U
// playlist auto-import all live here — in the iOS target's file, not in a
// platform branch of the shared LMFolders.
//

import Foundation

extension LibraryManager {
    /// iOS entry point: import a folder picked via `fileImporter` and add it to the
    /// library with a security-scoped bookmark, mirroring the macOS panel flow.
    ///
    /// iCloud Drive folders may only exist in the cloud when picked. Bookmarking
    /// (and later scanning) requires the folder to be materialized locally, so we
    /// start security-scoped access, request the download, and retry the bookmark
    /// until iCloud makes the folder available.
    func addFolder(urls urlsToAdd: [URL]) {
        let started = urlsToAdd.map { url in
            (url, url.startAccessingSecurityScopedResource())
        }
        for (url, ok) in started where !ok {
            Logger.warning("Failed to start security-scoped access for \(url.lastPathComponent)")
        }

        for url in urlsToAdd where FileManager.default.isUbiquitousItem(at: url) {
            do {
                try FileManager.default.startDownloadingUbiquitousItem(at: url)
                Logger.info("Requested iCloud download for \(url.lastPathComponent)")
            } catch {
                Logger.error("Failed to request iCloud download for \(url.path): \(error)")
            }
        }

        Task { [weak self] in
            guard let self else { return }

            NotificationManager.shared.startActivity(String(localized: "Preparing folder..."))

            var bookmarkDataMap: [URL: Data] = [:]
            var accessibleURLs: [URL] = []

            for url in urlsToAdd {
                // Retry until the item materializes (iCloud download can lag a bit).
                var lastError: Error?
                for _ in 0..<60 {
                    do {
                        let bookmarkData = try url.bookmarkData(
                            options: [],
                            includingResourceValuesForKeys: nil,
                            relativeTo: nil
                        )
                        bookmarkDataMap[url] = bookmarkData
                        accessibleURLs.append(url)
                        Logger.info("Created bookmark for folder - \(url.lastPathComponent) at \(url.path)")
                        break
                    } catch {
                        lastError = error
                        try? await Task.sleep(nanoseconds: 500_000_000)
                    }
                }
                if bookmarkDataMap[url] == nil {
                    Logger.error("Failed to create security bookmark for \(url.path): \(String(describing: lastError))")
                }
            }

            await MainActor.run {
                NotificationManager.shared.stopActivity()
            }

            guard !accessibleURLs.isEmpty else {
                NotificationManager.shared.addMessage(
                    .error,
                    String(localized: "Could not add the folder. Make sure it is downloaded on this iPhone (in Files: press and hold the folder, then choose Download Now).")
                )
                return
            }

            databaseManager.addFolders(accessibleURLs, bookmarkDataMap: bookmarkDataMap) { result in
                switch result {
                case .success(let dbFolders):
                    Logger.info("Successfully added \(dbFolders.count) folders to database")
                    self.scheduleLibraryReload()
                case .failure(let error):
                    Logger.error("Failed to add folders to database: \(error)")
                    NotificationManager.shared.addMessage(.error, String(localized: "Failed to add folder: \(error.localizedDescription)"))
                }
            }
        }
    }

    /// iOS entry point: background reconciliation of the database against the
    /// `Documents` folder. Called on app launch and on return from background;
    /// the Settings "Rescan Library" button stays a forced full scan via
    /// `scanLibraryRoot()`.
    ///
    /// A full scan with progress runs only when the library does not exist yet
    /// (first launch: `Documents` is not even registered as a folder), or when
    /// the cheap change check (`libraryContentsDiffer`) finds new or modified
    /// files. Otherwise nothing happens: no filesystem walk, no artwork
    /// reads, no post-scan steps. Files gone from disk are not a change — the
    /// database keeps their rows on purpose (ADR-0001).
    ///
    /// M3U playlists in `Documents/Petrichor-Playlists` are auto-imported on
    /// every reconciliation: the scan above only looks at audio files, so a
    /// playlist edit must be checked on its own, against the mtimes remembered
    /// from the last import (ADR-0002).
    func reconcileLibrary() async throws {
        if databaseManager.getAllFolders().isEmpty {
            try await scanLibraryRoot()
        } else if await databaseManager.libraryContentsDiffer(from: LibraryPathStore.libraryRoot) {
            try await scanLibraryRoot()
        } else {
            Logger.info("Library contents unchanged, skipping reconciliation")
        }

        await importLibraryPlaylistsIfNeeded()
    }

    /// iOS entry point: the library *is* the app's own `Documents` folder, so
    /// there is nothing to pick and no security-scoped bookmark to create —
    /// unlike `addFolder(urls:)` above, which is built around bookmarks and
    /// iCloud downloads for folders picked from outside the container.
    ///
    /// Registers `LibraryPathStore.libraryRoot` as the library's (only) folder
    /// and scans it, reusing the same `addFoldersAsync` → `scanFoldersForTracks`
    /// pipeline every other folder goes through — deduplication, metadata
    /// extraction, and the keep-rows-for-missing-files invariant (ADR-0001)
    /// all come for free. Calling this again (e.g. after the user copies more
    /// files into Documents via Finder/Files) re-registers the same folder row
    /// and rescans it.
    ///
    /// Progress is *not* reported through a callback: `scanFoldersForTracks`
    /// already publishes it through `databaseManager.isScanning` /
    /// `scanStatusMessage` (both `@Published`) and through
    /// `NotificationManager.shared`'s activity tray, so adding a parallel
    /// progress mechanism here would just be a second, redundant channel.
    func scanLibraryRoot() async throws {
        let root = LibraryPathStore.libraryRoot
        let folders = try await databaseManager.addFoldersAsync([root], bookmarkDataMap: [:])
        guard !folders.isEmpty else { return }
        await MainActor.run {
            self.scheduleLibraryReload()
        }
    }

    // MARK: - M3U Playlist Auto-Import

    private static let m3uImportMtimesKey = "m3uImportMtimes"

    /// iOS entry point: import M3U playlists from `Documents/Petrichor-Playlists`
    /// that are new or changed since the last import, running inside
    /// `reconcileLibrary()`. Each file's mtime is remembered in UserDefaults
    /// (same style as `LMDiscover`); unchanged files are skipped, changed files
    /// update the existing playlist with the same name, and a deleted M3U leaves
    /// its playlist alone (ADR-0002). Smart playlists are never touched.
    func importLibraryPlaylistsIfNeeded() async {
        let playlistsDirectory = LibraryPathStore.libraryRoot
            .appendingPathComponent("Petrichor-Playlists", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: playlistsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let m3uFiles = files.filter {
            let ext = $0.pathExtension.lowercased()
            return ext == "m3u" || ext == "m3u8"
        }
        guard !m3uFiles.isEmpty else { return }

        var importedMtimes = userDefaults.dictionary(forKey: Self.m3uImportMtimesKey)
            as? [String: TimeInterval] ?? [:]

        var changedFiles: [(url: URL, mtime: TimeInterval)] = []
        for file in m3uFiles {
            let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate?.timeIntervalSince1970 ?? 0
            let lastImported = importedMtimes[file.lastPathComponent]
            // Same tolerance as `libraryContentsDiffer` for filesystem clock jitter.
            if lastImported == nil || abs((lastImported ?? 0) - mtime) > 1.0 {
                changedFiles.append((file, mtime))
            }
        }
        guard !changedFiles.isEmpty else { return }
        Logger.info("Found \(changedFiles.count) new or changed M3U playlist file(s), importing")

        guard let playlistManager = AppCoordinator.shared?.playlistManager else { return }
        let result = await playlistManager.importPlaylists(
            from: changedFiles.map(\.url),
            replacingExisting: true
        )

        // Remember the mtime only when the file was actually processed: a file
        // that failed to match any track keeps its old mtime and is retried on
        // the next reconciliation.
        for (entry, single) in zip(changedFiles, result.results) where !single.isCompleteFailure {
            importedMtimes[entry.url.lastPathComponent] = entry.mtime
        }
        userDefaults.set(importedMtimes, forKey: Self.m3uImportMtimesKey)
    }
}
