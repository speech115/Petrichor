import Foundation
import GRDB
import PetrichorCore

enum EntityMergeError: LocalizedError {
    case entityNotFound(String)
    var errorDescription: String? {
        switch self {
        case .entityNotFound(let name): return "Could not find the entity to merge: \(name)"
        }
    }
}
extension DatabaseManager {
    struct EntityMergeResult {
        let mergedCount: Int
        let canonicalName: String
    }
    struct AlbumMergeCandidate: Identifiable {
        let id: Int64
        let title: String
        let artistName: String?
        let trackCount: Int
    }
    private func mergeThumbnails(albums: Bool, names: [String] = [], ids: [Int64] = []) throws
        -> [MergeThumbnail]
    {
        try rows(core.mergeArtworkCandidates(albums: albums, names: names, ids: ids)).compactMap {
            row in
            guard let id: Int64 = row["id"], let data: Data = row["artwork_data"] else {
                return nil
            }
            return MergeThumbnail(
                entityId: id, artwork: data,
                thumbnail: ImageUtils.makeThumbnail(from: data, source: "merge: id=\(id)"))
        }
    }
    @discardableResult
    func mergeArtists(winnerName: String, loserNames: [String], newName: String?) async throws
        -> EntityMergeResult
    {
        do {
            let result = try await Task.detached {
                try self.core.mergeArtists(
                    winnerName: winnerName, loserNames: loserNames, newName: newName,
                    now: Date().timeIntervalSince1970,
                    thumbnails: self.mergeThumbnails(
                        albums: false, names: loserNames + [newName].compactMap { $0 }))
            }.value
            return EntityMergeResult(
                mergedCount: Int(result.mergedCount), canonicalName: result.canonicalName)
        } catch let error as LibraryDatabaseError {
            if case .EntityNotFound(let name) = error {
                throw EntityMergeError.entityNotFound(name)
            }
            throw error
        }
    }
    @discardableResult
    func mergeAlbums(winnerId: Int64, loserIds: [Int64], newTitle: String?) async throws
        -> EntityMergeResult
    {
        do {
            let result = try await Task.detached {
                try self.core.mergeAlbums(
                    winnerId: winnerId, loserIds: loserIds, newTitle: newTitle,
                    now: Date().timeIntervalSince1970,
                    thumbnails: self.mergeThumbnails(albums: true, ids: loserIds))
            }.value
            return EntityMergeResult(
                mergedCount: Int(result.mergedCount), canonicalName: result.canonicalName)
        } catch let error as LibraryDatabaseError {
            if case .EntityNotFound(let name) = error {
                throw EntityMergeError.entityNotFound(name)
            }
            throw error
        }
    }
    func getAlbumMergeCandidates() -> [AlbumMergeCandidate] {
        do {
            return try rows(core.albumMergeCandidates()).compactMap { row in
                guard let id: Int64 = row["id"] else { return nil }
                return AlbumMergeCandidate(
                    id: id, title: row["title"] ?? "", artistName: row["artist_name"],
                    trackCount: row["track_count"] ?? 0)
            }
        } catch {
            Logger.error("Failed to get album merge candidates: \(error)")
            return []
        }
    }
}
