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

    // MARK: - Repeated Songs

    /// One row per song: copies of the same title by the same artists, within
    /// a few seconds of length, collapse into the first match. Duplicate
    /// marking in the database misses copies whose tags differ in punctuation,
    /// artist separators ("A, B" against "A;B") or year, as when one song
    /// arrives from two sources. Versions of different length (an edit, a
    /// remaster) stay separate. A copy with a known album replaces one from
    /// "Unknown Album".
    static func collapsingRepeatedSongs(_ tracks: [Track]) -> [Track] {
        var result: [Track] = []
        var indicesByKey: [String: [Int]] = [:]
        for track in tracks {
            let key = songKey(track)
            let match = indicesByKey[key, default: []].first {
                abs(result[$0].duration - track.duration) <= 3
            }
            if let match {
                let album = result[match].album
                if album.isEmpty || album == LibraryFilterType.albums.unknownPlaceholder {
                    result[match] = track
                }
            } else {
                indicesByKey[key, default: []].append(result.count)
                result.append(track)
            }
        }
        return result
    }

    private static func songKey(_ track: Track) -> String {
        let artists = track.artist
            .split { $0 == "," || $0 == ";" || $0 == "&" }
            .map(alphanumerics)
            .sorted()
            .joined(separator: "+")
        return alphanumerics(track.title) + "|" + artists
    }

    private static func alphanumerics(_ text: some StringProtocol) -> String {
        String(text.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(Character.init))
    }
}
