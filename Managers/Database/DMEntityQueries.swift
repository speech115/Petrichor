//
// DatabaseManager class extension
//
// This extension contains the queries behind the Home tab's artist and album pages, the
// library counts and the Library filter items.
//

import Foundation
import GRDB

extension DatabaseManager {
    // MARK: - Entity Queries (for Home tab)

    /// Get tracks for an artist entity
    func getTracksForArtistEntity(_ artistName: String, populateArtwork: Bool = true) -> [Track] {
        do {
            var tracks = try dbQueue.read { db in
                let normalizedName = ArtistParser.normalizeArtistName(artistName)
                
                guard let artistId = try Artist
                    .filter((Artist.Columns.name == artistName) || (Artist.Columns.normalizedName == normalizedName))
                    .fetchOne(db)?.id else {
                    return [Track]()
                }
                
                let trackIds = try TrackArtist
                    .filter(TrackArtist.Columns.artistId == artistId)
                    .filter(TrackArtist.Columns.role == TrackArtist.Role.artist)
                    .select(TrackArtist.Columns.trackId, as: Int64.self)
                    .fetchAll(db)
                
                var query = Track.all()
                    .filter(trackIds.contains(Track.Columns.trackId))
                
                query = applyDuplicateFilter(query)
                
                return try query
                    .order(Track.Columns.album, Track.Columns.discNumber ?? 1, Track.Columns.trackNumber ?? 0)
                    .fetchAll(db)
            }
            
            // List contexts pass `false`; visible rows fetch thumbnails
            // via ArtworkTile loaders.
            if populateArtwork {
                populateAlbumArtworkForTracks(&tracks)
            }
            return tracks
        } catch {
            Logger.error("Failed to get tracks for artist entity: \(error)")
            return []
        }
    }

    /// Get tracks for an album entity
    func getTracksForAlbumEntity(_ albumEntity: AlbumEntity, populateArtwork: Bool = true) -> [Track] {
        do {
            var tracks = try dbQueue.read { db in
                if let albumId = albumEntity.albumId {
                    var query = Track.all()
                        .filter(Track.Columns.albumId == albumId)
                    
                    query = applyDuplicateFilter(query)
                    
                    return try query
                        .order(Track.Columns.discNumber ?? 1, Track.Columns.trackNumber ?? 0)
                        .fetchAll(db)
                } else {
                    var query = Track.all()
                        .filter(Track.Columns.album == albumEntity.name)
                    
                    if let artistName = albumEntity.artistName {
                        query = query.filter(Track.Columns.albumArtist == artistName)
                    }
                    
                    query = applyDuplicateFilter(query)
                    
                    return try query
                        .order(Track.Columns.discNumber ?? 1, Track.Columns.trackNumber ?? 0)
                        .fetchAll(db)
                }
            }
            
            // List contexts pass `false`; visible rows fetch thumbnails
            // via ArtworkTile loaders.
            if populateArtwork {
                populateAlbumArtworkForTracks(&tracks)
            }
            return tracks
        } catch {
            Logger.error("Failed to get tracks for album entity: \(error)")
            return []
        }
    }

    // MARK: - Artist Name Lookup

    /// Artist names for `ArtistParser`'s runtime lookup: role to normalized name to canonical name.
    ///
    /// Built from `track_artists` rather than every `artists` row, since only those are reachable
    /// by the "Go to" queries - an unparsed album-artist tag can leave a combined row that only
    /// `album_artists` uses. Merge aliases fold in against their canonical artist.
    ///
    /// nil means the read failed, which callers must not treat as a library with no artists:
    /// installing an empty lookup silently re-enables blind separator splitting.
    func getArtistNamesByRole() -> [String: [String: String]]? {
        // `roles` is DISTINCT because track_artists has a row per track-artist link. The two
        // halves can't collide: a merged-away name is deleted from `artists` as its alias is
        // written, and `artists.normalized_name` is unique. Names come through
        // `idx_artists_listing`, not the artwork-heavy rows (140 ms cold -> 6 ms).
        let sql = """
            WITH roles AS (SELECT DISTINCT artist_id, role FROM track_artists)
            SELECT roles.role AS role, a.normalized_name AS lookup, a.name AS canonical
            FROM artists a INDEXED BY idx_artists_listing
            JOIN roles ON roles.artist_id = a.id
            WHERE a.total_tracks >= 0
            UNION ALL
            SELECT roles.role, al.normalized_alias, a.name
            FROM artist_aliases al
            JOIN artists a INDEXED BY idx_artists_listing ON a.id = al.canonical_artist_id
            JOIN roles ON roles.artist_id = a.id
            WHERE a.total_tracks >= 0
            """

        do {
            return try dbQueue.read { db in
                var namesByRole: [String: [String: String]] = [:]

                for row in try Row.fetchAll(db, sql: sql) {
                    let role: String = row["role"]
                    let lookup: String = row["lookup"]
                    namesByRole[role, default: [:]][lookup] = row["canonical"]
                }

                return namesByRole
            }
        } catch {
            Logger.error("Failed to get artist names by role: \(error)")
            return nil
        }
    }

    // MARK: - Quick Count Methods

    func getArtistCount() -> Int {
        do {
            return try dbQueue.read { db in
                try Artist
                    .filter(Artist.Columns.totalTracks > 0)
                    .fetchCount(db)
            }
        } catch {
            Logger.error("Failed to get artist count: \(error)")
            return 0
        }
    }

    func getAlbumCount() -> Int {
        do {
            return try dbQueue.read { db in
                try Album
                    .filter(Album.Columns.totalTracks > 0)
                    .fetchCount(db)
            }
        } catch {
            Logger.error("Failed to get album count: \(error)")
            return 0
        }
    }

    /// Count of tracks grouped by file format (extension). Honors the
    /// duplicate-hiding preference via `applyDuplicateFilter`.
    func getTrackCountsByFormat() -> [String: Int] {
        do {
            return try dbQueue.read { db in
                let rows = try applyDuplicateFilter(Track.all())
                    .select(
                        Track.Columns.format.lowercased.forKey("fmt"),
                        count(Track.Columns.format).forKey("cnt")
                    )
                    .group(Track.Columns.format.lowercased)
                    .asRequest(of: Row.self)
                    .fetchAll(db)

                var counts: [String: Int] = [:]
                for row in rows {
                    let rawFmt: String = row["fmt"] ?? ""
                    let cnt: Int = row["cnt"] ?? 0
                    let key = rawFmt.isEmpty ? "(none)" : rawFmt.lowercased()
                    counts[key, default: 0] += cnt
                }
                return counts
            }
        } catch {
            Logger.error("Failed to get track counts by format: \(error)")
            return [:]
        }
    }

    /// Sum of `file_size` across all tracks, in bytes. Honors the
    /// duplicate-hiding preference.
    func getTotalFileSize() -> Int64 {
        do {
            return try dbQueue.read { db in
                let result = try applyDuplicateFilter(Track.all())
                    .select(sum(Column("file_size")), as: Int64.self)
                    .fetchOne(db)
                return result ?? 0
            }
        } catch {
            Logger.error("Failed to get total file size: \(error)")
            return 0
        }
    }

    // MARK: - Library Filter Items

    func getAllTracks(populateArtwork: Bool = true) -> [Track] {
        do {
            var tracks = try dbQueue.read { db in
                try Track.lightweightRequest()
                    .order(Track.Columns.title)
                    .fetchAll(db)
            }

            // List contexts pass `false`; visible rows fetch thumbnails via
            // ArtworkTile loaders. Must not pull every display-size BLOB at once.
            if populateArtwork {
                populateAlbumArtworkForTracks(&tracks)
            }

            return tracks
        } catch {
            Logger.error("Failed to fetch all tracks: \(error)")
            return []
        }
    }

    /// Recently played tracks for the Home carousel, most recent first, with
    /// album thumbnails only (list rows never pull the display-size BLOB).
    func getRecentlyPlayedTracks(limit: Int = 10, populateArtwork: Bool = true) -> [Track] {
        do {
            var tracks = try dbQueue.read { db in
                try Track.lightweightRequest()
                    .filter(Track.Columns.lastPlayedDate != nil)
                    .order(Track.Columns.lastPlayedDate.desc)
                    .limit(limit)
                    .fetchAll(db)
            }

            if populateArtwork { populateAlbumArtworkThumbnailsForTracks(&tracks) }

            return tracks
        } catch {
            Logger.error("Failed to fetch recently played tracks: \(error)")
            return []
        }
    }

    /// Number of tracks in a folder, duplicates included. Counts in SQL; no rows or artwork are loaded.
    func getTrackCountForFolder(_ folderId: Int64) -> Int {
        do {
            return try dbQueue.read { db in
                try Track.filter(Track.Columns.folderId == folderId).fetchCount(db)
            }
        } catch {
            Logger.error("Failed to count tracks for folder: \(error)")
            return 0
        }
    }

    /// Get artist ID by name
    func getArtistId(for artistName: String) -> Int64? {
        do {
            return try dbQueue.read { db in
                let normalizedName = ArtistParser.normalizeArtistName(artistName)
                return try Artist
                    .filter((Artist.Columns.name == artistName) || (Artist.Columns.normalizedName == normalizedName))
                    .fetchOne(db)?
                    .id
            }
        } catch {
            Logger.error("Failed to get artist ID: \(error)")
            return nil
        }
    }
    
    /// Get artist artwork and bio data by name (for album artists/composers).
    /// When artist info fetching is enabled, only returns artwork that was fetched from online
    /// (has imageSource set), not album art carried over from track processing.
    func getArtistArtworkAndBio(for artistName: String) -> (artworkData: Data?, bio: String?) {
        let isImageFetchEnabled = ArtistBioManager.shared.isArtistInfoFetchEnabled
        do {
            return try dbQueue.read { db in
                let normalizedName = ArtistParser.normalizeArtistName(artistName)
                guard let artist = try Artist
                    .filter((Artist.Columns.name == artistName) || (Artist.Columns.normalizedName == normalizedName))
                    .fetchOne(db) else {
                    return (nil, nil)
                }
                let artworkData = isImageFetchEnabled
                    ? (artist.imageSource != nil ? artist.artworkData : nil)
                    : artist.artworkData
                return (artworkData, artist.bio)
            }
        } catch {
            Logger.error("Failed to get artist data: \(error)")
            return (nil, nil)
        }
    }
}
