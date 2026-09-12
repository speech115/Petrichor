//
// LibraryManager class extension
//
// This extension contains methods querying tracks across Library,
// the methods internally use DatabaseManager methods to work with database.
//

import Foundation

extension LibraryManager {
    // MARK: - List Read Wrappers
    //
    // The seam between views and the database: screens phrase their need
    // ("all tracks", "album tracks") in these wrappers and never name
    // DatabaseManager. List rows arrive without artwork payloads — visible
    // `ArtworkTile` loaders fetch thumbnails as they appear. The display-size
    // BLOB pass stays inside the database for detail/playback only.

    func getTracksInFolder(_ folder: Folder) -> [Track] {
        guard let folderId = folder.id else {
            Logger.error("Folder has no ID")
            return []
        }

        // macOS Folders view; carries full artwork for the track table.
        return databaseManager.getTracksForFolder(folderId)
    }

    nonisolated func getTracksBy(filterType: LibraryFilterType, value: String, albumId: Int64? = nil) -> [Track] {
        if filterType.usesMultiArtistParsing && value != filterType.unknownPlaceholder {
            return databaseManager.getTracksByFilterTypeContaining(filterType, value: value)
        }
        return databaseManager.getTracksByFilterType(
            filterType,
            value: value,
            albumId: albumId,
            populateArtwork: false
        )
    }

    nonisolated func getAllTracks() -> [Track] {
        databaseManager.getAllTracks(populateArtwork: false)
    }

    /// `nonisolated`: touches only the `Sendable` `databaseManager`, so screens that
    /// detach this off the main actor to avoid blocking on a large query don't need
    /// to hop back just to make the call.
    nonisolated func getTracksForArtist(_ name: String) -> [Track] {
        databaseManager.getTracksForArtistEntity(name, populateArtwork: false)
    }

    /// `nonisolated`: see `getTracksForArtist` above.
    nonisolated func getTracksForAlbum(_ album: AlbumEntity) -> [Track] {
        databaseManager.getTracksForAlbumEntity(album, populateArtwork: false)
    }

    /// `nonisolated`: see `getTracksForArtist` above.
    nonisolated func getArtistArtworkAndBio(for name: String) -> (artworkData: Data?, bio: String?) {
        databaseManager.getArtistArtworkAndBio(for: name)
    }

    func getArtistBio(for name: String) -> String? {
        databaseManager.getArtistBio(for: name)
    }

    func getArtistId(for name: String) -> Int64? {
        databaseManager.getArtistId(for: name)
    }

    /// `nonisolated`: see `getTracksForArtist` above.
    nonisolated func getRecentlyPlayedTracks(limit: Int = 10) -> [Track] {
        databaseManager.getRecentlyPlayedTracks(limit: limit)
    }

    /// `nonisolated`: see `getTracksForArtist` above.
    nonisolated func getPlaylistPreviewTracks(_ playlist: Playlist, limit: Int = 4) -> [Track] {
        databaseManager.getPlaylistPreviewTracks(playlist, limit: limit)
    }

    func getTotalDuration() -> Double {
        databaseManager.getTotalDuration()
    }

    func getTracksWithArtwork(byIds trackIds: [Int64]) -> [Track] {
        databaseManager.getTracksWithArtwork(byIds: trackIds)
    }

    /// Full-size artwork pass for the playlist editor's loaded rows (not a
    /// list: the editor reuses these tracks for collage artwork).
    func getPlaylistTracksFull(for playlistID: UUID) -> [Track] {
        databaseManager.loadTracksForPlaylist(playlistID)
    }

    func fullTrack(for track: Track) async throws -> FullTrack? {
        guard var loaded = try await track.fullTrack(using: databaseManager.dbQueue) else { return nil }
        databaseManager.populateAlbumArtworkForFullTrack(&loaded)
        return loaded
    }

    func updateArtistInfo(
        artistId: Int64,
        imageData: Data? = nil,
        imageUrl: String? = nil,
        imageSource: String? = nil,
        bio: String? = nil,
        bioSource: String? = nil
    ) {
        databaseManager.updateArtistInfo(
            artistId: artistId,
            imageData: imageData,
            imageUrl: imageUrl,
            imageSource: imageSource,
            bio: bio,
            bioSource: bioSource
        )
    }

    func deleteArtistImage(artistId: Int64) {
        databaseManager.deleteArtistImage(artistId: artistId)
    }

    @MainActor
    func cachedLyrics(for trackId: String) -> LyricsStore.Lyrics? {
        LyricsStore.shared.cachedLyrics(for: trackId)
    }

    @MainActor
    func lyrics(for track: Track, forceReload: Bool = false) async throws -> LyricsStore.Lyrics {
        try await LyricsStore.shared.lyrics(
            for: track,
            using: databaseManager.dbQueue,
            databaseManager: databaseManager,
            forceReload: forceReload
        )
    }

    func getLibraryFilterItems(for filterType: LibraryFilterType) -> [LibraryFilterItem] {
        if let cachedItems = cachedLibraryCategories[filterType] {
            Logger.info("Returning cached library filter items for \(filterType)")
            return cachedItems
        }

        let items = getLibraryFilterItemsFromDatabase(for: filterType)
        cachedLibraryCategories[filterType] = items

        return items
    }

    /// Cache read with no query behind it, for callers that must not block the main actor.
    func cachedLibraryFilterItems(for filterType: LibraryFilterType) -> [LibraryFilterItem]? {
        cachedLibraryCategories[filterType]
    }

    /// Serves the cache when warm and otherwise queries off-main. `getLibraryFilterItems`
    /// runs a full GROUP BY aggregation on a miss, which is a visible stall on a large library.
    func libraryFilterItems(for filterType: LibraryFilterType) async -> [LibraryFilterItem] {
        if let cached = await MainActor.run(body: { cachedLibraryCategories[filterType] }) {
            return cached
        }

        let items = await Task.detached(priority: .userInitiated) { [self] in
            getLibraryFilterItemsFromDatabase(for: filterType)
        }.value

        await MainActor.run { cachedLibraryCategories[filterType] = items }
        return items
    }

    func libraryFilterTrackCount(for filterType: LibraryFilterType, value: String, albumId: Int64? = nil) -> Int {
        let items = getLibraryFilterItems(for: filterType)
        if filterType == .albums, let albumId {
            return items.first { $0.albumId == albumId }?.count ?? 0
        }
        return items.first { $0.name == value }?.count ?? 0
    }

    func getTrackCountsByFolderPath() -> [String: Int] {
        databaseManager.getTrackCountsByFolderPath()
    }

    func updateSearchResults() {
        if globalSearchText.isEmpty {
            // When not searching, don't populate searchResults with all tracks
            searchResults = []
        } else {
            // Use LibrarySearch which uses FTS from database
            searchResults = LibrarySearch.searchTracks(tracks, with: globalSearchText, databaseManager: databaseManager)
        }
    }

    /// Runs a search off the main thread and publishes the results. Matches
    /// arrive without artwork — visible rows fetch thumbnails themselves.
    /// The query is not routed through `globalSearchText` so the didSet
    /// path never double-runs the search. `@MainActor` keeps the published
    /// assignment on the main thread — the method is non-isolated otherwise
    /// and would resume off-main after the `await`. A stale result is
    /// dropped: `.task(id:)` cancels the previous task when the query
    /// changes, and the check after the `await` sees that cancellation.
    @MainActor
    func search(query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            searchResults = []
            return
        }

        let databaseManager = databaseManager
        let results = await Task.detached(priority: .userInitiated) {
            LibrarySearch.searchTracks([], with: trimmed, populateArtwork: false, databaseManager: databaseManager)
        }.value

        guard !Task.isCancelled else { return }
        searchResults = results
    }
}
