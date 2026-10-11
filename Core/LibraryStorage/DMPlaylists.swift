import Foundation
import GRDB
import PetrichorCore

extension DatabaseManager {
    func savePlaylistAsync(_ playlist: Playlist) async throws {
        let criteria = try playlist.smartCriteria.map {
            String(decoding: try JSONEncoder().encode($0), as: UTF8.self)
        }
        try await Task.detached {
            try self.core.savePlaylist(
                p: PlaylistWrite(
                    id: playlist.id.uuidString, name: playlist.name,
                    kind: playlist.type.rawValue, userEditable: playlist.isUserEditable,
                    contentEditable: playlist.isContentEditable,
                    created: playlist.dateCreated.timeIntervalSince1970,
                    modified: playlist.dateModified.timeIntervalSince1970,
                    artwork: playlist.coverArtworkData,
                    sortOrder: Int64(playlist.sortOrder), criteria: criteria,
                    trackIds: playlist.tracks.map(\.trackId),
                    now: Date().timeIntervalSince1970))
        }.value
    }
    func saveSmartPlaylistSnapshot(playlistId: UUID, tracks: [Track]) async throws {
        try await Task.detached {
            try self.core.saveSmartPlaylistSnapshot(
                id: playlistId.uuidString, trackIds: tracks.map(\.trackId),
                now: Date().timeIntervalSince1970)
        }.value
    }
    func updatePlaylistMetadata(_ playlist: Playlist) async throws {
        try await Task.detached {
            try self.core.updatePlaylistMetadata(
                id: playlist.id.uuidString, name: playlist.name,
                modified: playlist.dateModified.timeIntervalSince1970)
        }.value
    }
    func getSmartPlaylistTrackCounts(_ playlists: [Playlist]) async -> [UUID: Int] {
        do {
            let smart = playlists.filter { $0.type == .smart && $0.smartCriteria != nil }
            let counts = try await Task.detached {
                try self.core.playlistSmartCounts(
                    criteria: smart.compactMap { $0.smartCriteria }.map(self.databaseSmartCriteria),
                    hideDuplicates: self.hideDuplicateTracks)
            }.value
            var result: [UUID: Int] = [:]
            for (playlist, count) in zip(smart, counts) { result[playlist.id] = Int(count) }
            return result
        } catch {
            Logger.error("Failed to batch smart playlist counts: \(error)")
            return [:]
        }
    }
    func loadAllPlaylists() -> [Playlist] {
        do {
            return try rows(core.allPlaylists()).map { row in
                var playlist = try Playlist(row: row)
                playlist.trackCount = row["__track_count"] ?? 0
                playlist.tracks = []
                return playlist
            }
        } catch {
            Logger.error("Failed to load playlists: \(error)")
            return []
        }
    }
    func updatePlaylistsOrder(_ playlists: [Playlist]) async throws {
        try await Task.detached {
            try self.core.updatePlaylistsOrder(ids: playlists.map { $0.id.uuidString })
        }.value
    }
    func loadTracksForPlaylist(_ playlistId: UUID, populateArtwork: Bool = true) -> [Track] {
        do {
            let result = try core.playlistTracks(
                id: playlistId.uuidString, artwork: populateArtwork)
            var decoded = try tracks(result)
            for index in decoded.indices {
                decoded[index].dateAdded = databaseDate(result.tracks[index].playlistDateAdded)
            }
            return decoded
        } catch {
            Logger.error("Failed to load tracks for playlist \(playlistId): \(error)")
            return []
        }
    }
    func loadPlaylistTrackIDs(_ playlistID: UUID) -> Set<Int64> {
        do { return Set(try core.playlistTrackIds(id: playlistID.uuidString)) } catch {
            Logger.error("Failed to load playlist membership: \(error)")
            return []
        }
    }
    func getPlaylistPreviewTracks(_ playlist: Playlist, limit: Int = 4) -> [Track] {
        do {
            var result: [Track]
            if playlist.type == .smart {
                result = Array(
                    getTracksForSmartPlaylistSync(playlist, populateArtwork: false).prefix(limit))
            } else {
                result = try tracks(
                    core.playlistPreview(id: playlist.id.uuidString, limit: Int64(limit)))
            }
            populateAlbumArtworkThumbnailsForTracks(&result)
            for index in result.indices where result[index].displayArtwork == nil {
                result[index].albumArtworkData = getArtworkData(
                    albumId: result[index].albumId, trackId: result[index].trackId)
            }
            return result
        } catch {
            Logger.error("Failed to load preview tracks for playlist \(playlist.id): \(error)")
            return []
        }
    }
    @discardableResult
    func appendTracksToPlaylist(playlistId: UUID, tracks: [Track]) async throws -> Int {
        Int(
            try await Task.detached {
                try self.core.appendPlaylistTracks(
                    id: playlistId.uuidString, ids: tracks.map(\.trackId),
                    now: Date().timeIntervalSince1970)
            }.value)
    }
    func removeTracksFromPlaylist(playlistId: UUID, trackIds: [Int64]) async throws {
        try await Task.detached {
            try self.core.removePlaylistTracks(
                id: playlistId.uuidString, ids: trackIds, now: Date().timeIntervalSince1970)
        }.value
    }
    func setPlaylistTrackOrder(playlistId: UUID, orderedTrackIds: [Int64]) async throws {
        try await Task.detached {
            try self.core.setPlaylistTrackOrder(
                id: playlistId.uuidString, ids: orderedTrackIds, now: Date().timeIntervalSince1970)
        }.value
    }
    func deletePlaylist(_ playlistId: UUID) async throws {
        try await Task.detached { try self.core.deletePlaylist(id: playlistId.uuidString) }.value
    }
    func addTrackToPlaylist(playlistId: UUID, track: Track) async -> Bool {
        guard let id = track.trackId else { return false }
        do {
            try await Task.detached {
                try self.core.addPlaylistTrack(
                    id: playlistId.uuidString, trackId: id, now: Date().timeIntervalSince1970)
            }.value
            return true
        } catch {
            Logger.error("Failed to add track to playlist: \(error)")
            return false
        }
    }
}
