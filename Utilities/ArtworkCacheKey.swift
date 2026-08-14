//
// ArtworkCacheKey
//
// Canonical cache-key builders for the artwork-derived caches: the row image
// cache (`RowArtworkCache` / `ArtworkTile`) and the dominant-color cache
// (`ImageUtils.colorCache`). The keys live in one place because `AlbumPage`
// deliberately matches the Now Playing color-cache key by string — a typo in
// one of these silently splits the two caches and loses the warm-cache hit.
//

import Foundation

enum ArtworkCacheKey {
    /// "album-<id>" — shared by the row image cache and the dominant-color cache.
    static func album(_ albumId: Int64) -> String { "album-\(albumId)" }

    /// "album-detail-<id>" — the album page's own header tile.
    static func albumDetail(_ albumId: Int64) -> String { "album-detail-\(albumId)" }

    /// "track-<id>" — for tracks whose cover hangs off the track, not an album.
    static func track(_ trackId: Int64) -> String { "track-\(trackId)" }

    /// The identity a `Track` uses for its cached colors: the album id when it
    /// has one, its own id otherwise.
    static func trackColorIdentity(albumId: Int64?, trackID: String) -> String {
        albumId.map(album) ?? "track-\(trackID)"
    }

    static func nowPlaying(_ trackID: String) -> String { "now-playing-\(trackID)" }
    static func playlist(_ id: UUID) -> String { "playlist-\(id)" }
    static func artist(_ name: String) -> String { "artist-\(name)" }
    static func artistDetail(_ name: String) -> String { "artist-detail-\(name)" }
    static func trackInfo(_ trackId: Int64) -> String { "track-info-\(trackId)" }
}
