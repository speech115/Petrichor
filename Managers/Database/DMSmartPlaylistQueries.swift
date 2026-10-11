//
//  DatabaseManager class extension
//  Petrichor
//
//  Smart playlist query builder for fetching tracks from database
//  based on Smart Playlist criteria
//

import Foundation
import GRDB

extension DatabaseManager {
    // MARK: - Smart Playlist Query Builder

    /// The filtered (not yet sorted or limited) track query for a smart playlist's criteria.
    /// Shared by the track-fetch and count paths so the filter logic lives in one place.
    func smartPlaylistFilteredQuery(
        _ criteria: SmartPlaylistCriteria
    ) -> QueryInterfaceRequest<Track> {
        // Hiding duplicates never hides a starred copy: Favorites lists exactly
        // the files that were marked, the same set on the Mac and the iPhone.
        var query = Track.all()
        if UserDefaults.standard.bool(forKey: "hideDuplicateTracks") {
            query = query.filter(Track.Columns.isDuplicate == false || Track.Columns.isFavorite == true)
        }
        if let whereClause = buildWhereClause(for: criteria) {
            query = query.filter(whereClause)
        }
        return query
    }

    /// Count tracks matching a criteria (honoring its limit) within an already-open read.
    func countSmartPlaylistTracks(
        _ criteria: SmartPlaylistCriteria,
        db: Database
    ) throws -> Int {
        let query = smartPlaylistFilteredQuery(criteria)
        if let limit = criteria.limit {
            return try query.limit(limit).fetchCount(db)
        }
        return try query.fetchCount(db)
    }

    /// Count how many library tracks match a criteria's rules, ignoring any limit. Used by
    /// the editor's live "Matches N songs" footer to convey how selective the rules are
    /// (the limit is a separate, explicit cap). Opens its own read.
    func countMatchesForCriteria(_ criteria: SmartPlaylistCriteria) async -> Int {
        do {
            return try await dbQueue.read { db in
                return try self.smartPlaylistFilteredQuery(criteria).fetchCount(db)
            }
        } catch {
            Logger.error("Failed to count smart playlist matches: \(error)")
            return 0
        }
    }

    /// Build and run a smart playlist's full track query (filter, sort, limit, artwork) within
    /// an already-open read.
    private func fetchSmartPlaylistTracks(
        for criteria: SmartPlaylistCriteria,
        db: Database,
        populateArtwork: Bool = true
    ) throws -> [Track] {

        var query = smartPlaylistFilteredQuery(criteria)
        query = LibraryQueryPolicy.applySorting(to: query, criteria: criteria)
        if let limit = criteria.limit {
            query = query.limit(limit)
        }

        var tracks = try query.fetchAll(db)
        // List contexts pass `false` and fill thumbnails themselves
        // (populateAlbumArtworkThumbnailsForTracks).
        if populateArtwork {
            try populateAlbumArtworkForTracks(&tracks, db: db)
        }
        return tracks
    }

    /// Build and execute a database query for a smart playlist
    func getTracksForSmartPlaylist(
        _ playlist: Playlist,
        populateArtwork: Bool = true
    ) async throws -> [Track] {
        guard playlist.type == .smart,
              let criteria = playlist.smartCriteria else {
            return []
        }

        return try await dbQueue.read { db in
            try self.fetchSmartPlaylistTracks(for: criteria, db: db, populateArtwork: populateArtwork)
        }
    }

    /// Get tracks for a smart playlist synchronously
    func getTracksForSmartPlaylistSync(_ playlist: Playlist, populateArtwork: Bool = true) -> [Track] {
        guard playlist.type == .smart,
              let criteria = playlist.smartCriteria else {
            return []
        }

        do {
            return try dbQueue.read { db in
                try self.fetchSmartPlaylistTracks(for: criteria, db: db, populateArtwork: populateArtwork)
            }
        } catch {
            Logger.error("Failed to get tracks for smart playlist '\(playlist.name)': \(error)")
            return []
        }
    }

    internal func buildWhereClause(for criteria: SmartPlaylistCriteria) -> SQLExpression? {
        LibraryQueryPolicy.buildWhereClause(for: criteria)
    }
}
