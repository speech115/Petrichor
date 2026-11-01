//
// DatabaseManager class extension
//
// This extension contains the methods that read artwork for tracks, albums and artists:
// filling list rows with their album art and fetching display-size images and thumbnails.
//

import Foundation
import GRDB

extension DatabaseManager {
    /// Populate track album art from albums table, falling back to track's own artwork
    func populateAlbumArtworkForTracks(_ tracks: inout [Track], db: Database) throws {
        // Populate from albums table
        try populateAlbumArtwork(for: &tracks, db: db)
        
        // Fallback to track's own artwork when there's no album info associated with it
        try populateTrackArtwork(for: &tracks, db: db)
    }

    func populateAlbumArtworkForTracks(_ tracks: inout [Track]) {
        do {
            try dbQueue.read { db in
                try populateAlbumArtworkForTracks(&tracks, db: db)
            }
        } catch {
            Logger.error("Failed to populate album artwork: \(error)")
        }
    }

    /// Populate album artwork thumbnails for list rows.
    ///
    /// Artwork preload policy:
    /// - scroll lists (Songs / search / artist / album): do not call this;
    ///   visible `ArtworkTile` loaders fetch one row at a time;
    /// - mosaic headers (Discover / playlists): pass `limit` as the number of
    ///   covers needed — albums are scanned in track order until that many
    ///   thumbnails are assigned (not a hard `prefix(limit)` of tracks);
    func populateAlbumArtworkThumbnailsForTracks(_ tracks: inout [Track], limit: Int? = nil) {
        let albumIds: [Int64]
        if let limit {
            // Headroom past `limit` so albums missing thumbnails do not leave
            // the mosaic empty when early tracks lack art.
            var seen = Set<Int64>()
            var candidates: [Int64] = []
            let headroom = max(limit * 4, limit)
            for track in tracks {
                guard candidates.count < headroom else { break }
                guard let albumId = track.albumId, seen.insert(albumId).inserted else { continue }
                candidates.append(albumId)
            }
            albumIds = candidates
        } else {
            albumIds = tracks.compactMap(\.albumId).removingDuplicates()
        }
        guard !albumIds.isEmpty else { return }

        do {
            try dbQueue.read { db in
                let request = Album
                    .select(Album.Columns.id, Album.Columns.artworkThumbnail)
                    .filter(albumIds.contains(Album.Columns.id))

                let rows = try Row.fetchAll(db, request)

                let thumbnailMap: [Int64: Data] = rows.reduce(into: [:]) { dict, row in
                    if let id: Int64 = row["id"],
                       let thumbnail: Data = row["artwork_thumbnail"] {
                        dict[id] = thumbnail
                    }
                }

                if let limit {
                    var filled = 0
                    for i in tracks.indices {
                        guard filled < limit else { break }
                        if let albumId = tracks[i].albumId,
                           let thumbnail = thumbnailMap[albumId] {
                            tracks[i].albumArtworkThumbnail = thumbnail
                            filled += 1
                        }
                    }
                } else {
                    for i in tracks.indices {
                        if let albumId = tracks[i].albumId,
                           let thumbnail = thumbnailMap[albumId] {
                            tracks[i].albumArtworkThumbnail = thumbnail
                        }
                    }
                }
            }
        } catch {
            Logger.error("Failed to populate album artwork thumbnails: \(error)")
        }
    }
    
    /// Address-fetch of one artwork — album art by album ID, falling back to
    /// the track's own artwork. Lazy lists (thousands of rows) must not pull
    /// every cover at once, so rows fetch individually as they appear.
    func getArtworkData(albumId: Int64?, trackId: Int64?) -> Data? {
        do {
            return try dbQueue.read { db in
                if let albumId,
                   let artwork: Data = try Album
                       .select(Album.Columns.artworkData)
                       .filter(Album.Columns.id == albumId)
                       .fetchOne(db)?[Album.Columns.artworkData] {
                    return artwork
                }

                guard let trackId else { return nil }
                return try FullTrack
                    .select(FullTrack.Columns.trackArtworkData)
                    .filter(FullTrack.Columns.trackId == trackId)
                    .fetchOne(db)?[FullTrack.Columns.trackArtworkData] as Data?
            }
        } catch {
            Logger.error("Failed to fetch artwork for track: \(error)")
            return nil
        }
    }

    /// One album image for a visible card. Lists read the thumbnail column
    /// only. Callers that still need a cover while thumbnails are migrating
    /// fall back through `getArtworkData(albumId:trackId:)` in
    /// `ArtworkDataLoader.trackListArtwork`, not here.
    func getAlbumArtworkThumbnail(albumId: Int64) -> Data? {
        do {
            return try dbQueue.read { db in
                try Row.fetchOne(
                    db,
                    sql: "SELECT artwork_thumbnail FROM albums WHERE id = ?",
                    arguments: [albumId]
                )?["artwork_thumbnail"] as Data?
            }
        } catch {
            Logger.error("Failed to fetch album thumbnail: \(error)")
            return nil
        }
    }

    /// One artist image for a visible row. Preserve the artist-image setting:
    /// while remote artist images are enabled, a row with no fetched source
    /// keeps its placeholder instead of silently falling back to album art.
    func getArtistArtworkThumbnail(name: String) -> Data? {
        let requiresFetchedImage = ArtistBioManager.shared.isArtistInfoFetchEnabled
        do {
            return try dbQueue.read { db in
                guard let row = try Row.fetchOne(
                    db,
                    sql: "SELECT artwork_thumbnail, artwork_data, image_source FROM artists WHERE name = ?",
                    arguments: [name]
                ) else { return nil }
                let imageSource: String? = row["image_source"]
                if requiresFetchedImage, imageSource == nil { return nil }
                return (row["artwork_thumbnail"] as Data?) ?? (row["artwork_data"] as Data?)
            }
        } catch {
            Logger.error("Failed to fetch artist thumbnail: \(error)")
            return nil
        }
    }

    /// Populate album artwork for a single FullTrack
    func populateAlbumArtworkForFullTrack(_ track: inout FullTrack) {
        guard let albumId = track.albumId else { return }
        
        do {
            if let artworkData = try dbQueue.read({ db in
                try Album
                    .select(Album.Columns.artworkData)
                    .filter(Album.Columns.id == albumId)
                    .fetchOne(db)?[Album.Columns.artworkData] as Data?
            }) {
                track.albumArtworkData = artworkData
            }
        } catch {
            Logger.error("Failed to populate album artwork for full track: \(error)")
        }
    }

    // MARK: - Private Helpers

    private func populateAlbumArtwork(for tracks: inout [Track], db: Database) throws {
        let albumIds = tracks.compactMap { $0.albumId }.removingDuplicates()
        guard !albumIds.isEmpty else { return }
        
        let request = Album
            .select(Album.Columns.id, Album.Columns.artworkData)
            .filter(albumIds.contains(Album.Columns.id))
        
        let rows = try Row.fetchAll(db, request)
        
        let artworkMap: [Int64: Data] = rows.reduce(into: [:]) { dict, row in
            if let id: Int64 = row["id"],
               let artwork: Data = row["artwork_data"] {
                dict[id] = artwork
            }
        }
        
        for i in 0..<tracks.count {
            if let albumId = tracks[i].albumId,
               let artwork = artworkMap[albumId] {
                tracks[i].albumArtworkData = artwork
            }
        }
    }

    private func populateTrackArtwork(for tracks: inout [Track], db: Database) throws {
        let trackIdsNeedingArtwork = tracks
            .filter { $0.albumArtworkData == nil }
            .compactMap { $0.trackId }
        
        guard !trackIdsNeedingArtwork.isEmpty else { return }
        
        let request = FullTrack
            .select(FullTrack.Columns.trackId, FullTrack.Columns.trackArtworkData)
            .filter(trackIdsNeedingArtwork.contains(FullTrack.Columns.trackId))
            .filter(FullTrack.Columns.trackArtworkData != nil)
        
        let rows = try Row.fetchAll(db, request)
        
        let artworkMap: [Int64: Data] = rows.reduce(into: [:]) { dict, row in
            if let id: Int64 = row["id"],
               let artwork: Data = row["track_artwork_data"] {
                dict[id] = artwork
            }
        }
        
        for i in 0..<tracks.count {
            if tracks[i].albumArtworkData == nil,
               let trackId = tracks[i].trackId,
               let artwork = artworkMap[trackId] {
                tracks[i].albumArtworkData = artwork
            }
        }
    }
}
