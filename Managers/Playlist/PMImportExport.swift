//
// PlaylistManager class extension
//
// This extension contains methods for importing and exporting M3U playlists.
//

import Foundation

// MARK: - Import/Export Result Types

enum M3UImportError: Error, LocalizedError {
    case fileReadFailed(filename: String)
    case invalidFormat(filename: String)
    case emptyFile(filename: String)
    
    var errorDescription: String? {
        switch self {
        case .fileReadFailed(let filename):
            return "Could not read file '\(filename)'"
        case .invalidFormat(let filename):
            return "File '\(filename)' has invalid M3U format"
        case .emptyFile(let filename):
            return "File '\(filename)' contains no tracks"
        }
    }
}

struct PlaylistImportResult {
    let playlistName: String
    let totalTracksInFile: Int
    let tracksAdded: Int
    let tracksMissing: [String]
    let error: Error?
    
    var isSuccess: Bool {
        error == nil && tracksAdded > 0
    }
    
    var hasWarnings: Bool {
        error == nil && !tracksMissing.isEmpty && tracksAdded > 0
    }
    
    var isCompleteFailure: Bool {
        error != nil || (tracksAdded == 0 && totalTracksInFile > 0)
    }
}

struct BulkImportResult {
    let results: [PlaylistImportResult]
    
    var totalFiles: Int { results.count }
    var successful: Int { results.filter { $0.isSuccess && !$0.hasWarnings }.count }
    var withWarnings: Int { results.filter { $0.hasWarnings }.count }
    var failed: Int { results.filter { $0.isCompleteFailure }.count }
    var totalTracksImported: Int { results.reduce(0) { $0 + $1.tracksAdded } }
    var totalTracksMissing: Int { results.reduce(0) { $0 + $1.tracksMissing.count } }
}

struct PlaylistExportResult {
    let playlistName: String
    let error: Error?
    
    var isSuccess: Bool { error == nil }
}

struct BulkExportResult {
    let results: [PlaylistExportResult]
    
    var totalPlaylists: Int { results.count }
    var successful: Int { results.filter { $0.isSuccess }.count }
    var failed: [(playlist: String, error: Error)] {
        results.filter { !$0.isSuccess }.compactMap { result in
            guard let error = result.error else { return nil }
            return (result.playlistName, error)
        }
    }
}

private enum M3UFormat {
    static let header = "#EXTM3U"
    static let infoPrefix = "#EXTINF:"
    static let commentPrefix = "#"
    static let lineEnding = "\r\n"
}

// MARK: - PlaylistManager Extension

extension PlaylistManager {
    // MARK: - Import

    /// Manual import (the "Import Playlists" button): a file whose name
    /// already matches a playlist creates "Name 2" instead of touching it.
    func importPlaylists(from urls: [URL]) async -> BulkImportResult {
        await importPlaylists(from: urls, replacingExisting: false)
    }

    /// Auto-import (iOS reconciliation): an M3U whose name matches an existing
    /// regular playlist replaces that playlist's order and composition instead
    /// of creating a duplicate. Smart playlists are never matched — they
    /// rebuild from their rules (ADR-0002).
    func importPlaylists(from urls: [URL], replacingExisting: Bool) async -> BulkImportResult {
        let existingNames = await fetchExistingPlaylistNames()
        var usedNames = Set(existingNames.map { $0.lowercased() })
        var results: [PlaylistImportResult] = []
        
        for url in urls {
            let didStartAccess = url.startAccessingSecurityScopedResource()
            let result = await importSinglePlaylist(from: url, usedNames: usedNames, replacingExisting: replacingExisting)
            results.append(result)
            
            if didStartAccess {
                url.stopAccessingSecurityScopedResource()
            }
            
            usedNames.insert(result.playlistName.lowercased())
        }
        
        return BulkImportResult(results: results)
    }
    
    private func fetchExistingPlaylistNames() async -> [String] {
        await MainActor.run { playlists.map { $0.name } }
    }
    
    private func importSinglePlaylist(
        from url: URL,
        usedNames: Set<String>,
        replacingExisting: Bool
    ) async -> PlaylistImportResult {
        let basePlaylistName = url.deletingPathExtension().lastPathComponent
        let sourceDirectory = url.deletingLastPathComponent()
        
        let fileContent = (try? String(contentsOf: url, encoding: .utf8)) ??
                          (try? String(contentsOf: url, encoding: .isoLatin1))
        
        guard let content = fileContent else {
            Logger.error("Failed to read '\(url.lastPathComponent)' (tried UTF-8 and Latin-1)")
            return PlaylistImportResult(
                playlistName: basePlaylistName,
                totalTracksInFile: 0,
                tracksAdded: 0,
                tracksMissing: [],
                error: M3UImportError.fileReadFailed(filename: url.lastPathComponent)
            )
        }
        
        return await processM3UContent(
            content,
            playlistName: basePlaylistName,
            usedNames: usedNames,
            sourceDirectory: sourceDirectory,
            replacingExisting: replacingExisting
        )
    }
    
    private func processM3UContent(
        _ content: String,
        playlistName: String,
        usedNames: Set<String>,
        sourceDirectory: URL? = nil,
        replacingExisting: Bool = false
    ) async -> PlaylistImportResult {
        let trackPaths = parseM3UContent(content)
        
        guard !trackPaths.isEmpty else {
            Logger.error("Empty M3U file: \(playlistName)")
            return PlaylistImportResult(
                playlistName: playlistName,
                totalTracksInFile: 0,
                tracksAdded: 0,
                tracksMissing: [],
                error: M3UImportError.emptyFile(filename: "\(playlistName).m3u")
            )
        }
        
        guard let dbManager = libraryManager?.databaseManager else {
            Logger.error("Import failed - '\(playlistName)': no database manager")
            return PlaylistImportResult(
                playlistName: playlistName,
                totalTracksInFile: trackPaths.count,
                tracksAdded: 0,
                tracksMissing: trackPaths,
                error: nil
            )
        }

        let resolved = await M3UTrackResolver.resolveTracks(
            for: trackPaths,
            sourceDirectory: sourceDirectory,
            using: dbManager.m3uQuery()
        )
        // One result per entry, in M3U order: matched tracks and the entries
        // that stayed unmatched (missing file, refused ambiguity).
        let matchedTracks = resolved.compactMap { $0 }
        let unmatchedPaths = zip(trackPaths, resolved).compactMap { path, track in
            track == nil ? path : nil
        }

        guard !matchedTracks.isEmpty else {
            Logger.error("Import failed - '\(playlistName)': 0/\(trackPaths.count) tracks found in library")
            return PlaylistImportResult(
                playlistName: playlistName,
                totalTracksInFile: trackPaths.count,
                tracksAdded: 0,
                tracksMissing: unmatchedPaths,
                error: nil
            )
        }

        if !unmatchedPaths.isEmpty {
            let sample = unmatchedPaths.prefix(3).joined(separator: ", ")
            let more = unmatchedPaths.count > 3 ? " (+\(unmatchedPaths.count - 3) more)" : ""
            let message = """
                Partial import - '\(playlistName)': \(matchedTracks.count)/\(trackPaths.count) \
                tracks. Missing: \(sample)\(more)
                """
            Logger.warning(message)
        }

        let existingPlaylist = replacingExisting
            ? await findExistingRegularPlaylist(named: playlistName)
            : nil
        let finalPlaylistName = existingPlaylist?.name
            ?? generateUniquePlaylistName(baseName: playlistName, existingNames: usedNames)

        await MainActor.run {
            if let existing = existingPlaylist {
                replaceImportedPlaylist(existing, with: matchedTracks)
            } else {
                _ = createPlaylist(name: finalPlaylistName, tracks: matchedTracks)
            }
        }
        
        return PlaylistImportResult(
            playlistName: finalPlaylistName,
            totalTracksInFile: trackPaths.count,
            tracksAdded: matchedTracks.count,
            tracksMissing: unmatchedPaths,
            error: nil
        )
    }
    
    /// M3U seam (design spec, "Разбор M3U"): turns file content into the
    /// ordered track entries, keeping numeric prefixes and relative paths
    /// exactly as written. Non-empty, non-comment lines in file order.
    func parseM3UContent(_ content: String) -> [String] {
        content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix(M3UFormat.commentPrefix) }
    }
    
    private func generateUniquePlaylistName(baseName: String, existingNames: Set<String>) -> String {
        guard existingNames.contains(baseName.lowercased()) else {
            return baseName
        }
        
        let baseNameLower = baseName.lowercased()
        let highestNumber = existingNames.reduce(1) { currentMax, name in
            guard name.hasPrefix(baseNameLower + " ") else { return currentMax }
            let suffix = String(name.dropFirst(baseNameLower.count + 1))
            return max(currentMax, Int(suffix) ?? 0)
        }
        
        return "\(baseName) \(highestNumber + 1)"
    }

    /// The regular playlist an auto-imported M3U updates: same name,
    /// case-insensitive. Smart playlists are never matched.
    private func findExistingRegularPlaylist(named name: String) async -> Playlist? {
        await MainActor.run {
            playlists.first {
                $0.type == .regular && $0.name.lowercased() == name.lowercased()
            }
        }
    }

    /// Replace an imported playlist's order and composition with a fresh M3U
    /// read, in memory and in the database. Runs on the main actor: mutates
    /// `playlists` like `createPlaylist` does for the create path.
    private func replaceImportedPlaylist(_ playlist: Playlist, with tracks: [Track]) {
        var updated = playlist
        updated.tracks = tracks
        updated.trackCount = tracks.count
        updated.dateModified = Date()
        if let index = playlists.firstIndex(where: { $0.id == playlist.id }) {
            playlists[index] = updated
        }
        Task {
            do {
                if let dbManager = libraryManager?.databaseManager {
                    try await dbManager.savePlaylistAsync(updated)
                }
            } catch {
                Logger.error("Failed to update imported playlist '\(updated.name)': \(error)")
            }
        }
    }
    
    // MARK: - Export
    
    func exportPlaylists(_ playlists: [Playlist], to directoryURL: URL) async -> BulkExportResult {
        var results: [PlaylistExportResult] = []
        
        for playlist in playlists {
            let filename = FilesystemUtils.sanitizeFilename(playlist.name) + ".m3u"
            let fileURL = directoryURL.appendingPathComponent(filename)
            let result = await exportSinglePlaylist(playlist, to: fileURL)
            results.append(result)
        }
        
        return BulkExportResult(results: results)
    }
    
    private func exportSinglePlaylist(_ playlist: Playlist, to fileURL: URL) async -> PlaylistExportResult {
        let tracks = playlist.tracks.isEmpty
            ? await MainActor.run { getPlaylistTracks(playlist) }
            : playlist.tracks
        
        let m3uContent = generateM3UContent(for: tracks)
        
        do {
            try FilesystemUtils.writeM3UFile(content: m3uContent, to: fileURL)
            return PlaylistExportResult(
                playlistName: playlist.name,
                error: nil
            )
        } catch {
            Logger.error("Failed to export '\(playlist.name)': \(error)")
            return PlaylistExportResult(
                playlistName: playlist.name,
                error: error
            )
        }
    }
    
    private func generateM3UContent(for tracks: [Track]) -> String {
        var lines = [M3UFormat.header]
        
        for track in tracks {
            let durationSeconds = Int(track.duration)
            let artistTitle = "\(track.artist) - \(track.title)"
            lines.append("\(M3UFormat.infoPrefix)\(durationSeconds),\(artistTitle)")
            lines.append(track.url.path)
        }
        
        return lines.joined(separator: M3UFormat.lineEnding)
    }
}
