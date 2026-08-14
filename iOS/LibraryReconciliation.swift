//
// LibraryManager class extension (iOS)
//
// iOS-side reconciliation: the library *is* the app's own `Documents`
// folder. Background reconciliation on launch/foreground, the forced
// rescan, and the M3U playlist auto-import all live here — in the iOS
// target's file, not in a platform branch of the shared LMFolders.
//

import Foundation

extension LibraryManager {
    /// Fire-and-forget launch reconciliation for the iOS entry point. The
    /// library *is* the app's own `Documents` folder — there is no picker
    /// step, so it has to be registered on every launch rather than through
    /// user action. The coordinator captured `hadFoldersAtStartup` before this
    /// runs, and `reconcileLibrary()` re-registers the same folder row plus the
    /// `.initialScanStarted`/`.foldersAddedToDatabase` notifications the
    /// manager already observes are what bring newly-copied tracks into view —
    /// so this must not block startup. Reconciliation skips the full scan when
    /// the library already exists and the file set has not changed.
    func reconcileInBackground() {
        Task(priority: .utility) {
            do {
                try await reconcileLibrary()
            } catch {
                Logger.error("Failed to reconcile the iOS documents library: \(error)")
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
        let shouldStart = await MainActor.run { () -> Bool in
            guard !isReconcilingLibrary else { return false }
            isReconcilingLibrary = true
            return true
        }
        guard shouldStart else {
            Logger.info("Library reconciliation already in progress, skipping duplicate trigger")
            return
        }

        do {
            if databaseManager.getAllFolders().isEmpty {
                try await scanLibraryRoot()
            } else if await databaseManager.libraryContentsDiffer(from: LibraryPathStore.libraryRoot) {
                try await scanLibraryRoot()
            } else {
                Logger.info("Library contents unchanged, skipping reconciliation")
            }

            await importLibraryPlaylistsIfNeeded()
            await MainActor.run { isReconcilingLibrary = false }
            // The system search index is kept in step from `scanLibraryRoot()`
            // (the single scheduling call site): a launch whose contents did
            // not change never scans, and never needs a resync.
        } catch {
            await MainActor.run { isReconcilingLibrary = false }
            throw error
        }
    }

    /// iOS entry point: the library *is* the app's own `Documents` folder, so
    /// there is nothing to pick and no security-scoped bookmark to create.
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
    /// already publishes it through `databaseManager.scanActivity`
    /// (`isScanning` / `scanStatusMessage`, both `@Published` on the
    /// main-actor observation object) and through
    /// `NotificationManager.shared`'s activity tray, so adding a parallel
    /// progress mechanism here would just be a second, redundant channel.
    func scanLibraryRoot() async throws {
        let shouldStart = await MainActor.run { () -> Bool in
            guard !isScanningLibraryRoot else { return false }
            isScanningLibraryRoot = true
            return true
        }
        guard shouldStart else {
            Logger.info("Library root scan already in progress, skipping duplicate trigger")
            return
        }
        // Every exit path — including the empty-folders guard below — must
        // clear the gate, or a single empty result wedges rescan forever.
        // `LibraryManager` is `@MainActor`, so the flag clears synchronously.
        defer { isScanningLibraryRoot = false }

        let root = LibraryPathStore.libraryRoot
        let folders = try await databaseManager.addFoldersAsync([root], bookmarkDataMap: [:])
        guard !folders.isEmpty else { return }
        await MainActor.run {
            self.scheduleLibraryReload()
        }
        // The single Spotlight scheduling call site: both `reconcileLibrary()`
        // (which calls this method) and the Settings "Rescan Library" button
        // (which calls it directly) land here, so a resync always follows a
        // real scan and never a no-change launch.
        SpotlightIndexer.scheduleSync(with: databaseManager)
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
            if lastImported == nil || abs((lastImported ?? 0) - mtime) > TimeConstants.filesystemMtimeTolerance {
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
