import Foundation

enum LibrarySearch {
    // MARK: - Track Search

    /// Searches tracks based on a query string using FTS5
    /// - Parameters:
    ///   - tracks: The tracks to search through (used as fallback if FTS fails)
    ///   - query: The search query string
    ///   - populateArtwork: Whether to load full-size artwork for the matches;
    ///     list rows pass `false` and read thumbnails instead.
    ///   - databaseManager: `Sendable`, so this stays callable from an
    ///     off-main `Task.detached` (see `LMQueries.search(query:)`) without
    ///     forcing this whole enum onto the main actor just to reach
    ///     `AppCoordinator.shared` internally. Callers pass
    ///     `AppCoordinator.shared?.libraryManager.databaseManager` (or, from
    ///     inside `LibraryManager`, `self.databaseManager` directly).
    /// - Returns: Filtered tracks that match the query
    static func searchTracks(
        _ tracks: [Track],
        with query: String,
        populateArtwork: Bool = true,
        databaseManager: DatabaseManager?
    ) -> [Track] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return tracks }

        // Require at least 2 characters for search
        guard trimmedQuery.count >= 2 else { return [] }

        // Use FTS5 search from database
        if let databaseManager {
            let ftsResults = databaseManager.searchTracksUsingFTS(
                trimmedQuery,
                populateArtwork: populateArtwork
            )

            // Return FTS results if we got any
            if !ftsResults.isEmpty {
                return ftsResults
            }

            // If FTS returned empty but query exists, it means no matches found
            // Return empty array rather than falling back to in-memory search
            return []
        }

        // If no database manager available (shouldn't happen in normal app flow)
        // Return empty results
        Logger.warning("No database manager available for search")
        return []
    }
}
