//
// SpotlightRouter (iOS)
//
// Turns a CoreSpotlight search-result identifier into the Home stack
// destination that shows it. Called from ContentView's
// `.onContinueUserActivity(CSSearchableItemActionType)` handler.
//
// Identifiers mirror SpotlightIndexer: `track:<id>` opens the track's album
// page (never autoplay - tapping a search result must not suddenly start
// audio), `album:<albumId>` opens the album page, `artist:<name>` opens the
// artist page. A track without an album, or an album that no longer exists,
// falls back to the all-tracks list.
//

import Foundation

enum SpotlightRouter {
    static func destination(for identifier: String, libraryManager: LibraryManager) -> LibraryDestination? {
        guard let (domain, value) = split(identifier) else { return nil }

        switch domain {
        case SpotlightDomain.track:
            guard let trackId = Int64(value),
                  let track = libraryManager.databaseManager.getTracks(byIds: [trackId]).first else {
                return nil
            }
            guard let albumId = track.albumId,
                  let album = albumEntity(forAlbumId: albumId, libraryManager: libraryManager) else {
                return .allTracks
            }
            return .album(album)

        case SpotlightDomain.album:
            guard let albumId = Int64(value) else { return nil }
            guard let album = albumEntity(forAlbumId: albumId, libraryManager: libraryManager) else {
                return .allTracks
            }
            return .album(album)

        case SpotlightDomain.artist:
            return .artist(name: value)

        default:
            return nil
        }
    }

    /// "track:42" -> ("track", "42"); a colon inside the value (artist names)
    /// is preserved because only the first separator is split off.
    private static func split(_ identifier: String) -> (domain: String, value: String)? {
        guard let colon = identifier.firstIndex(of: ":") else { return nil }
        let domain = String(identifier[..<colon])
        let value = String(identifier[identifier.index(after: colon)...])
        return (domain, value)
    }

    /// Same lookup order as ContentView's `albumEntity(for:)`: the in-memory
    /// entity cache first (it may hold artwork), then the database.
    private static func albumEntity(forAlbumId albumId: Int64, libraryManager: LibraryManager) -> AlbumEntity? {
        if let cached = libraryManager.albumEntities.first(where: { $0.albumId == albumId }) {
            return cached
        }
        return libraryManager.databaseManager.getAlbumEntities(includeArtwork: false)
            .first { $0.albumId == albumId }
    }
}
