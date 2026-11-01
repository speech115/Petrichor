//
// DatabaseManager class extension
//
// This extension contains the track queries: Discover, the library filters, lookups by id,
// path and filename. Artwork reads live in `DMArtworkQueries`, the Home tab's entity pages,
// counts and filter items in `DMEntityQueries`.
//

import Foundation
import GRDB

extension DatabaseManager {
    /// Get tracks for the Discover feature. Favorites and `excluding` (the
    /// previous rotation) never qualify: Discover is for tracks not yet known.
    func getDiscoverTracks(limit: Int = 50, excluding previousIds: [Int64] = [], populateArtwork: Bool = true) -> [Track] {
        do {
            return try dbQueue.read { db in
                let candidates = Track.all()
                    .filter(Track.Columns.isDuplicate == false)
                    .filter(Track.Columns.isFavorite == false)
                    .filter(!previousIds.contains(Track.Columns.trackId))
                var tracks = try candidates
                    .filter(Track.Columns.playCount == 0)
                    .order(sql: "RANDOM()")
                    .limit(limit)
                    .fetchAll(db)
                
                // If we don't have enough unplayed tracks, fill with least recently played
                if tracks.count < limit {
                    let remaining = limit - tracks.count
                    let existingIds = Set(tracks.compactMap { $0.trackId })
                    
                    let additionalTracks = try candidates
                        .filter(!existingIds.contains(Track.Columns.trackId))
                        .order(
                            Track.Columns.lastPlayedDate.asc,
                            Track.Columns.playCount.asc
                        )
                        .limit(remaining)
                        .fetchAll(db)
                    
                    tracks.append(contentsOf: additionalTracks)
                }
                
                // List contexts pass `false`; visible rows fetch thumbnails
                // via ArtworkTile loaders.
                if populateArtwork {
                    try populateAlbumArtworkForTracks(&tracks, db: db)
                }
                
                return tracks
            }
        } catch {
            Logger.error("Failed to get discover tracks: \(error)")
            return []
        }
    }

    /// Get tracks by IDs (for loading saved discover tracks)
    func getTracks(byIds trackIds: [Int64]) -> [Track] {
        do {
            return try dbQueue.read { db in
                try Track
                    .filter(trackIds.contains(Track.Columns.trackId))
                    .fetchAll(db)
            }
        } catch {
            Logger.error("Failed to get tracks by IDs: \(error)")
            return []
        }
    }

    /// Get tracks by IDs with their album artwork populated, in a single read. Tracks are
    /// returned in the same order as `trackIds` (a plain `IN` fetch returns DB order), so
    /// callers building a playlist preserve the intended track order.
    func getTracksWithArtwork(byIds trackIds: [Int64]) -> [Track] {
        do {
            return try dbQueue.read { db in
                var tracks = try Track
                    .filter(trackIds.contains(Track.Columns.trackId))
                    .fetchAll(db)
                try self.populateAlbumArtworkForTracks(&tracks, db: db)

                let positionByID = Dictionary(uniqueKeysWithValues: trackIds.enumerated().map { ($1, $0) })
                tracks.sort { (positionByID[$0.trackId ?? -1] ?? .max) < (positionByID[$1.trackId ?? -1] ?? .max) }
                return tracks
            }
        } catch {
            Logger.error("Failed to get tracks with artwork by IDs: \(error)")
            return []
        }
    }
    
    /// Get total track count without loading tracks
    func getTotalTrackCount() -> Int {
        do {
            return try dbQueue.read { db in
                try applyDuplicateFilter(Track.all()).fetchCount(db)
            }
        } catch {
            Logger.error("Failed to get total track count: \(error)")
            return 0
        }
    }

    /// Get total duration of all tracks in the library
    func getTotalDuration() -> Double {
        do {
            return try dbQueue.read { db in
                let result = try applyDuplicateFilter(Track.all())
                    .select(sum(Track.Columns.duration), as: Double.self)
                    .fetchOne(db)
                
                return result ?? 0.0
            }
        } catch {
            Logger.error("Failed to get total duration: \(error)")
            return 0.0
        }
    }

    /// Get tracks by filter type and value using normalized tables
    func getTracksByFilterType(_ filterType: LibraryFilterType, value: String, albumId: Int64? = nil, populateArtwork: Bool = true) -> [Track] {
        do {
            return try dbQueue.read { db in
                var tracks: [Track] = []
                
                switch filterType {
                case .artists, .albumArtists, .composers:
                    if value == filterType.unknownPlaceholder {
                        switch filterType {
                        case .artists:
                            tracks = try Track.lightweightRequest()
                                .filter(Track.Columns.artist == value)
                                .fetchAll(db)
                        case .albumArtists:
                            tracks = try Track.lightweightRequest()
                                .filter(Track.Columns.albumArtist == value)
                                .fetchAll(db)
                        case .composers:
                            tracks = try Track.lightweightRequest()
                                .filter(Track.Columns.composer == value)
                                .fetchAll(db)
                        default:
                            return []
                        }
                    } else {
                        let normalizedSearchName = ArtistParser.normalizeArtistName(value)
                        
                        guard let artist = try Artist
                            .filter((Artist.Columns.name == value) || (Artist.Columns.normalizedName == normalizedSearchName))
                            .fetchOne(db),
                            let artistId = artist.id else {
                            return []
                        }
                        
                        let trackIds = try TrackArtist
                            .filter(TrackArtist.Columns.artistId == artistId)
                            .select(TrackArtist.Columns.trackId, as: Int64.self)
                            .fetchAll(db)
                        
                        tracks = try Track.lightweightRequest()
                            .filter(trackIds.contains(Track.Columns.trackId))
                            .fetchAll(db)
                    }
                        
                case .albums:
                    // Prefer the exact album id (titles aren't unique); fall back to title.
                    if let albumId {
                        tracks = try Track.lightweightRequest()
                            .filter(Track.Columns.albumId == albumId)
                            .fetchAll(db)
                    } else {
                        tracks = try Track.lightweightRequest()
                            .filter(Track.Columns.album == value)
                            .fetchAll(db)
                    }
                        
                case .genres:
                    if value == filterType.unknownPlaceholder {
                        // Mirror getGenreFilterItems: the Unknown bucket also covers
                        // NULL/empty genres, which `== value` alone would miss.
                        tracks = try Track.lightweightRequest()
                            .filter(Track.Columns.genre == nil || Track.Columns.genre == "" || Track.Columns.genre == value)
                            .fetchAll(db)
                    } else {
                        tracks = try Track.lightweightRequest()
                            .filter(Track.Columns.genre == value)
                            .fetchAll(db)
                    }
                        
                case .years:
                    if value == filterType.unknownPlaceholder {
                        // Mirror getYearFilterItems: the Unknown bucket also covers
                        // NULL/empty years.
                        tracks = try Track.lightweightRequest()
                            .filter(Track.Columns.year == nil || Track.Columns.year == "" || Track.Columns.year == value)
                            .fetchAll(db)
                    } else {
                        tracks = try Track.lightweightRequest()
                            .filter(Track.Columns.year == value)
                            .fetchAll(db)
                    }
                        
                case .decades:
                    if value == filterType.unknownPlaceholder {
                        // Mirror getDecadeFilterItems' Unknown Decade bucket: tracks with
                        // null/empty/unknown year, which the numeric range can't match.
                        let unknownYear = LibraryFilterType.years.unknownPlaceholder
                        tracks = try Track.lightweightRequest()
                            .filter(Track.Columns.year == nil || Track.Columns.year == "" || Track.Columns.year == unknownYear)
                            .fetchAll(db)
                    } else {
                        let decade = value.replacingOccurrences(of: "s", with: "")
                        if let decadeInt = Int(decade) {
                            let startYear = String(decadeInt)
                            let endYear = String(decadeInt + 9)
                            tracks = try Track.lightweightRequest()
                                .filter(Track.Columns.year >= startYear && Track.Columns.year <= endYear)
                                .fetchAll(db)
                        }
                    }
                }
                
                // Order results
                tracks = tracks.sorted { $0.title < $1.title }
                
                // Populate album artwork. List contexts pass `false`; visible
                // rows fetch thumbnails via ArtworkTile loaders.
                if populateArtwork {
                    try populateAlbumArtworkForTracks(&tracks, db: db)
                }
                
                return tracks
            }
        } catch {
            Logger.error("Failed to get tracks by filter type: \(error)")
            return []
        }
    }

    /// Get tracks where the filter value is contained (for multi-artist parsing)
    func getTracksByFilterTypeContaining(_ filterType: LibraryFilterType, value: String) -> [Track] {
        do {
            return try dbQueue.read { db in
                // This is specifically for multi-artist fields
                guard filterType.usesMultiArtistParsing else {
                    return getTracksByFilterType(filterType, value: value)
                }

                // Find the artist (handles normalized name matching)
                let normalizedSearchName = ArtistParser.normalizeArtistName(value)

                guard let artist = try Artist
                    .filter((Artist.Columns.name == value) || (Artist.Columns.normalizedName == normalizedSearchName))
                    .fetchOne(db),
                    let artistId = artist.id else {
                    return []
                }

                let role: String = switch filterType {
                case .artists: "artist"
                case .albumArtists: "album_artist"
                case .composers: "composer"
                default: "artist"
                }

                let trackIds = try TrackArtist
                    .filter(TrackArtist.Columns.artistId == artistId)
                    .filter(TrackArtist.Columns.role == role)
                    .select(TrackArtist.Columns.trackId, as: Int64.self)
                    .fetchAll(db)

                return try applyDuplicateFilter(Track.all())
                    .filter(trackIds.contains(Track.Columns.trackId))
                    .fetchAll(db)
            }
        } catch {
            Logger.error("Failed to get tracks by filter type containing: \(error)")
            return []
        }
    }

    // MARK: - Helper Methods
    
    /// Get the current play count for a track from the database
    func getTrackPlayCount(trackId: Int64) async throws -> Int? {
        try await dbQueue.read { db in
            try Track
                .filter(Track.Columns.trackId == trackId)
                .select(Track.Columns.playCount, as: Int.self)
                .fetchOne(db)
        }
    }
    
    func trackExists(withId trackId: Int64) -> Bool {
        do {
            return try dbQueue.read { db in
                try Track.filter(Track.Columns.trackId == trackId).fetchCount(db) > 0
            }
        } catch {
            Logger.error("Failed to check track existence: \(error)")
            return false
        }
    }

    /// Find a track by its file path
    func findTrackByPath(_ path: String) async -> Track? {
        let storedPath = LibraryPathStore.storedPath(for: URL(fileURLWithPath: path))
        do {
            return try await dbQueue.read { db in
                if let track = try Track
                    .filter(Track.Columns.path == storedPath)
                    .fetchOne(db) {
                    return track
                }
                return try Track
                    .filter(Track.Columns.path.collating(.nocase) == storedPath)
                    .fetchOne(db)
            }
        } catch {
            Logger.error("Failed to query track by path: \(error)")
            return nil
        }
    }

    /// Narrow M3U seam primitive: all tracks whose filename is in the list
    /// (case-insensitive), one batch read. No ambiguity policy — that lives in
    /// `M3UTrackResolver`, which owns it for both of its filename stages.
    func tracksByFilenames(_ filenames: [String]) async -> [Track] {
        do {
            return try await dbQueue.read { db in
                let lowercasedFilenames = filenames.map { $0.lowercased() }
                return try Track
                    .filter(lowercasedFilenames.contains(Track.Columns.filename.lowercased))
                    .fetchAll(db)
            }
        } catch {
            Logger.error("Failed to query tracks by filenames: \(error)")
            return []
        }
    }

    /// Narrow M3U seam primitive: every stored filename — the candidate pool
    /// for the renamed-file fallback (`M3UTrackResolver` resolves names against
    /// this list, then looks the winners up via `tracksByFilenames`).
    func storedFilenames() async -> [String] {
        do {
            return try await dbQueue.read { db in
                try Track
                    .select(Track.Columns.filename)
                    .asRequest(of: String.self)
                    .fetchAll(db)
            }
        } catch {
            Logger.error("Failed to query stored filenames: \(error)")
            return []
        }
    }

    /// The `M3UTrackResolver.Query` implementation backed by this database.
    func m3uQuery() -> M3UTrackResolver.Query {
        M3UTrackResolver.Query(
            findTrackByPath: { path in await self.findTrackByPath(path) },
            tracksByFilenames: { filenames in await self.tracksByFilenames(filenames) },
            storedFilenames: { await self.storedFilenames() }
        )
    }

    /// Apply duplicate filtering to a Track query if the user preference is enabled
    func applyDuplicateFilter(_ query: QueryInterfaceRequest<Track>) -> QueryInterfaceRequest<Track> {
        let hideDuplicates = UserDefaults.standard.bool(forKey: "hideDuplicateTracks")
        
        if hideDuplicates {
            return query.filter(Track.Columns.isDuplicate == false)
        }
        
        return query
    }
}
