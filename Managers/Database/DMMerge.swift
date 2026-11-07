//
// DatabaseManager extension: manual merging of duplicate entities.
//
// Artists, album artists and composers share the `artists` table (distinguished by
// `track_artists.role`), so one engine covers all three; albums have their own. Merges
// are group-only: they rewrite normalized relationships and record an alias (old name to
// canonical) so a merge survives re-ingestion, but never touch the raw tag strings. The
// album engine is the exception, rewriting `tracks.album` because the Library sidebar
// matches albums by that string column.
//

import Foundation
import GRDB

enum EntityMergeError: LocalizedError {
    case entityNotFound(String)

    var errorDescription: String? {
        switch self {
        case .entityNotFound(let name):
            return "Could not find the entity to merge: \(name)"
        }
    }
}

extension DatabaseManager {
    struct EntityMergeResult {
        let mergedCount: Int
        let canonicalName: String
    }

    // MARK: - Artist Merge (artists / album artists / composers)

    @discardableResult
    func mergeArtists(winnerName: String, loserNames: [String], newName: String?) async throws -> EntityMergeResult {
        try await dbQueue.write { db in
            try self.mergeArtists(winnerName: winnerName, loserNames: loserNames, newName: newName, in: db)
        }
    }

    @discardableResult
    func mergeArtists(winnerName: String, loserNames: [String], newName: String?, in db: Database) throws -> EntityMergeResult {
        guard let winner = try artistRow(named: winnerName, in: db), let winnerId = winner.id else {
            throw EntityMergeError.entityNotFound(winnerName)
        }

        let unknownPlaceholders: Set<String> = [
            LibraryFilterType.artists.unknownPlaceholder,
            LibraryFilterType.albumArtists.unknownPlaceholder,
            LibraryFilterType.composers.unknownPlaceholder
        ]
        var loserIds: [Int64] = []
        var loserAliases: [(normalized: String, display: String)] = []
        for name in loserNames where !unknownPlaceholders.contains(name) {
            guard let row = try artistRow(named: name, in: db), let id = row.id,
                  id != winnerId, !loserIds.contains(id) else { continue }
            loserIds.append(id)
            loserAliases.append((row.normalizedName, row.name))
        }

        // Renaming into an existing artist would violate the unique normalized_name index, so fold it in.
        let trimmedNew = newName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let renameTarget: String? = (trimmedNew?.isEmpty == false && trimmedNew != winner.name) ? trimmedNew : nil
        let newNormalized = renameTarget.map { ArtistParser.normalizeArtistName($0) }
        if let newNormalized, newNormalized != winner.normalizedName,
           let collide = try Artist.filter(Artist.Columns.normalizedName == newNormalized).fetchOne(db),
           let collideId = collide.id, collideId != winnerId, !loserIds.contains(collideId) {
            loserIds.append(collideId)
            loserAliases.append((collide.normalizedName, collide.name))
        }

        guard !loserIds.isEmpty || renameTarget != nil else {
            return EntityMergeResult(mergedCount: 0, canonicalName: winner.name)
        }

        if !loserIds.isEmpty {
            let marks = databaseQuestionMarks(count: loserIds.count)
            let winnerThenLosers = StatementArguments([winnerId] + loserIds)

            // OR IGNORE sidesteps composite-PK collisions; the DELETE clears the ignored loser rows.
            try db.execute(sql: "UPDATE OR IGNORE track_artists SET artist_id = ? WHERE artist_id IN (\(marks))", arguments: winnerThenLosers)
            try TrackArtist.filter(loserIds.contains(TrackArtist.Columns.artistId)).deleteAll(db)
            try db.execute(sql: "UPDATE OR IGNORE album_artists SET artist_id = ? WHERE artist_id IN (\(marks))", arguments: winnerThenLosers)
            try AlbumArtist.filter(loserIds.contains(AlbumArtist.Columns.artistId)).deleteAll(db)

            try Self.carryOverArtistMetadata(winnerId: winnerId, loserIds: loserIds, in: db)

            // Redirect aliases that pointed at a loser to keep chains flat.
            try ArtistAlias
                .filter(loserIds.contains(ArtistAlias.Columns.canonicalArtistId))
                .updateAll(db, ArtistAlias.Columns.canonicalArtistId.set(to: winnerId))

            for alias in loserAliases {
                try writeArtistAlias(normalized: alias.normalized, display: alias.display, canonicalId: winnerId, in: db)
            }

            try Artist.filter(loserIds.contains(Artist.Columns.id)).deleteAll(db)
        }

        if let renameTarget, let newNormalized {
            if newNormalized != winner.normalizedName {
                // Keep the winner's old name resolvable on future ingests.
                try writeArtistAlias(normalized: winner.normalizedName, display: winner.name, canonicalId: winnerId, in: db)
                try ArtistAlias.filter(ArtistAlias.Columns.normalizedAlias == newNormalized).deleteAll(db)
            }
            try Artist.filter(Artist.Columns.id == winnerId).updateAll(
                db,
                Artist.Columns.name.set(to: renameTarget),
                Artist.Columns.normalizedName.set(to: newNormalized),
                Artist.Columns.sortName.set(to: renameTarget),
                Artist.Columns.updatedAt.set(to: Date())
            )
        }

        try updateArtistStats(in: db)

        return EntityMergeResult(mergedCount: loserIds.count, canonicalName: renameTarget ?? winner.name)
    }

    // MARK: - Re-keying (v19)

    /// Recomputes every stored artist key with the current
    /// `ArtistParser.normalizeArtistName`, and every alias key from its
    /// display name. Artists whose keys now coincide are one artist spelled
    /// with different whitespace or dots: the one with the most tracks keeps
    /// its row, the rest fold into it the way a manual merge does (links,
    /// metadata, aliases). Returns how many rows folded.
    static func renormalizeArtistNames(in db: Database) throws -> Int {
        let rows = try Row.fetchAll(db, sql: "SELECT id, name, normalized_name FROM artists ORDER BY total_tracks DESC, id")
        var winnerByKey: [String: Int64] = [:]
        var rekeyed: [(id: Int64, key: String)] = []
        var folded: [(loser: Int64, winner: Int64)] = []
        for row in rows {
            let id: Int64 = row["id"]
            let key = ArtistParser.normalizeArtistName(row["name"])
            if let winner = winnerByKey[key] {
                folded.append((id, winner))
                continue
            }
            winnerByKey[key] = id
            if key != (row["normalized_name"] as String) {
                rekeyed.append((id, key))
            }
        }

        for (loser, winner) in folded {
            let arguments: StatementArguments = [winner, loser]
            // OR IGNORE sidesteps composite-PK collisions; the DELETE clears the ignored rows.
            try db.execute(sql: "UPDATE OR IGNORE track_artists SET artist_id = ? WHERE artist_id = ?", arguments: arguments)
            try db.execute(sql: "DELETE FROM track_artists WHERE artist_id = ?", arguments: [loser])
            try db.execute(sql: "UPDATE OR IGNORE album_artists SET artist_id = ? WHERE artist_id = ?", arguments: arguments)
            try db.execute(sql: "DELETE FROM album_artists WHERE artist_id = ?", arguments: [loser])
            try carryOverArtistMetadata(winnerId: winner, loserIds: [loser], in: db)
            try db.execute(sql: "UPDATE artist_aliases SET canonical_artist_id = ? WHERE canonical_artist_id = ?", arguments: arguments)
            try db.execute(sql: "DELETE FROM artists WHERE id = ?", arguments: [loser])
        }

        // Two passes through a placeholder: a row's new key can still be
        // another row's old key until that row is re-keyed too.
        for (id, _) in rekeyed {
            try db.execute(sql: "UPDATE artists SET normalized_name = ? WHERE id = ?", arguments: ["\u{1}v19-\(id)", id])
        }
        for (id, key) in rekeyed {
            try db.execute(sql: "UPDATE artists SET normalized_name = ? WHERE id = ?", arguments: [key, id])
        }

        try renormalizeArtistAliases(in: db)

        if !folded.isEmpty {
            try db.execute(sql: """
                UPDATE artists
                SET total_tracks = (
                        SELECT COUNT(DISTINCT ta.track_id)
                        FROM track_artists ta
                        JOIN tracks t ON t.id = ta.track_id
                        WHERE ta.artist_id = artists.id
                          AND ta.role = 'artist'
                          AND t.is_duplicate = 0
                    ),
                    total_albums = (
                        SELECT COUNT(DISTINCT album_id)
                        FROM album_artists
                        WHERE artist_id = artists.id
                    )
                """)
        }
        return folded.count
    }

    /// Alias keys are the normalized display name; two aliases landing on one
    /// key keep the first (by key, then display name).
    private static func renormalizeArtistAliases(in db: Database) throws {
        let rows = try Row.fetchAll(db, sql: "SELECT normalized_alias, display_name FROM artist_aliases ORDER BY normalized_alias, display_name")
        var taken: Set<String> = []
        var rekeyed: [(old: String, key: String)] = []
        var dropped: [String] = []
        for row in rows {
            let old: String = row["normalized_alias"]
            let key = ArtistParser.normalizeArtistName(row["display_name"])
            if taken.contains(key) {
                dropped.append(old)
            } else {
                taken.insert(key)
                if key != old { rekeyed.append((old, key)) }
            }
        }
        for old in dropped {
            try db.execute(sql: "DELETE FROM artist_aliases WHERE normalized_alias = ?", arguments: [old])
        }
        for (index, entry) in rekeyed.enumerated() {
            try db.execute(sql: "UPDATE artist_aliases SET normalized_alias = ? WHERE normalized_alias = ?", arguments: ["\u{1}v19-\(index)", entry.old])
        }
        for (index, entry) in rekeyed.enumerated() {
            try db.execute(sql: "UPDATE artist_aliases SET normalized_alias = ? WHERE normalized_alias = ?", arguments: [entry.key, "\u{1}v19-\(index)"])
        }
    }

    // MARK: - Album Merge

    @discardableResult
    func mergeAlbums(winnerId: Int64, loserIds: [Int64], newTitle: String?) async throws -> EntityMergeResult {
        try await dbQueue.write { db in
            try self.mergeAlbums(winnerId: winnerId, loserIds: loserIds, newTitle: newTitle, in: db)
        }
    }

    @discardableResult
    func mergeAlbums(winnerId: Int64, loserIds rawLoserIds: [Int64], newTitle: String?, in db: Database) throws -> EntityMergeResult {
        guard let winner = try Album.fetchOne(db, key: winnerId) else {
            throw EntityMergeError.entityNotFound("album #\(winnerId)")
        }

        let loserIds = Array(Set(rawLoserIds.filter { $0 != winnerId }))
        let trimmed = newTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let renameTarget: String? = (trimmed?.isEmpty == false && trimmed != winner.title) ? trimmed : nil
        let canonicalTitle = renameTarget ?? winner.title

        guard !loserIds.isEmpty || renameTarget != nil else {
            return EntityMergeResult(mergedCount: 0, canonicalName: winner.title)
        }

        if !loserIds.isEmpty {
            // Capture alias keys before deletes remove the album_artists rows they read.
            var loserAliasKeys: [(key: String, title: String)] = []
            let losers = try Album.filter(loserIds.contains(Album.Columns.id)).fetchAll(db)
            for loser in losers {
                guard let id = loser.id else { continue }
                let normalizedArtist = try albumPrimaryArtistNormalized(albumId: id, in: db)
                loserAliasKeys.append((ScanLookupCache.albumKey(loser.normalizedTitle, normalizedArtist), loser.title))
            }

            let marks = databaseQuestionMarks(count: loserIds.count)
            let winnerThenLosers = StatementArguments([winnerId] + loserIds)

            try Track.filter(loserIds.contains(Track.Columns.albumId)).updateAll(db, Track.Columns.albumId.set(to: winnerId))
            // OR IGNORE sidesteps composite-PK collisions; the DELETE clears the ignored loser rows.
            try db.execute(sql: "UPDATE OR IGNORE album_artists SET album_id = ? WHERE album_id IN (\(marks))", arguments: winnerThenLosers)
            try AlbumArtist.filter(loserIds.contains(AlbumArtist.Columns.albumId)).deleteAll(db)

            if winner.artworkData == nil, let donor = losers.first(where: { $0.artworkData != nil }),
               let donorArtwork = donor.artworkData {
                winner.artworkData = donorArtwork
                winner.artworkThumbnail = donor.artworkThumbnail
                    ?? ImageUtils.makeThumbnail(from: donorArtwork, source: "album: \(winner.title)")
                try winner.update(db)
            }

            try AlbumAlias
                .filter(loserIds.contains(AlbumAlias.Columns.canonicalAlbumId))
                .updateAll(db, AlbumAlias.Columns.canonicalAlbumId.set(to: winnerId))
            for alias in loserAliasKeys {
                try writeAlbumAlias(key: alias.key, displayTitle: alias.title, canonicalId: winnerId, in: db)
            }

            try Album.filter(loserIds.contains(Album.Columns.id)).deleteAll(db)
        }

        // Unify tracks.album so the string-based Library sidebar groups them together.
        try Track.filter(Track.Columns.albumId == winnerId).updateAll(db, Track.Columns.album.set(to: canonicalTitle))

        if let renameTarget {
            let newNormalized = Album.normalizeTitle(renameTarget)
            let oldArtist = try albumPrimaryArtistNormalized(albumId: winnerId, in: db)
            try writeAlbumAlias(
                key: ScanLookupCache.albumKey(winner.normalizedTitle, oldArtist),
                displayTitle: winner.title,
                canonicalId: winnerId,
                in: db
            )
            try AlbumAlias
                .filter(AlbumAlias.Columns.normalizedKey == ScanLookupCache.albumKey(newNormalized, oldArtist))
                .deleteAll(db)
            try Album.filter(Album.Columns.id == winnerId).updateAll(
                db,
                Album.Columns.title.set(to: renameTarget),
                Album.Columns.normalizedTitle.set(to: newNormalized),
                Album.Columns.sortTitle.set(to: renameTarget),
                Album.Columns.updatedAt.set(to: Date())
            )
        }

        try updateAlbumStats(in: db)

        return EntityMergeResult(mergedCount: loserIds.count, canonicalName: canonicalTitle)
    }

    // MARK: - Helpers

    /// Resolve an artist by display name or normalized name (mirrors the ingestion lookup).
    private func artistRow(named name: String, in db: Database) throws -> Artist? {
        let normalized = ArtistParser.normalizeArtistName(name)
        return try Artist
            .filter((Artist.Columns.name == name) || (Artist.Columns.normalizedName == normalized))
            .fetchOne(db)
    }

    private func albumPrimaryArtistNormalized(albumId: Int64, in db: Database) throws -> String? {
        let sql = """
            SELECT artists.normalized_name AS n
            FROM album_artists
            JOIN artists ON artists.id = album_artists.artist_id
            WHERE album_artists.album_id = ? AND album_artists.role = 'primary'
            ORDER BY album_artists.position
            LIMIT 1
            """
        return try Row.fetchOne(db, sql: sql, arguments: [albumId])?["n"]
    }

    private static func carryOverArtistMetadata(winnerId: Int64, loserIds: [Int64], in db: Database) throws {
        guard let winner = try Artist.fetchOne(db, key: winnerId) else { return }
        let losers = try Artist.filter(loserIds.contains(Artist.Columns.id)).fetchAll(db)

        var changed = false
        if winner.artworkData == nil, let donor = losers.first(where: { $0.artworkData != nil }),
           let donorArtwork = donor.artworkData {
            winner.artworkData = donorArtwork
            winner.artworkThumbnail = donor.artworkThumbnail
                ?? ImageUtils.makeThumbnail(from: donorArtwork, source: "artist: \(winner.name)")
            changed = true
        }
        if winner.imageUrl == nil, let donor = losers.first(where: { $0.imageUrl != nil }) {
            winner.imageUrl = donor.imageUrl
            winner.imageSource = donor.imageSource
            winner.imageUpdatedAt = donor.imageUpdatedAt
            changed = true
        }
        if winner.bio == nil, let donor = losers.first(where: { $0.bio != nil }) {
            winner.bio = donor.bio
            winner.bioSource = donor.bioSource
            winner.bioUpdatedAt = donor.bioUpdatedAt
            changed = true
        }
        if changed { try winner.update(db) }
    }

    private func writeArtistAlias(normalized: String, display: String, canonicalId: Int64, in db: Database) throws {
        try ArtistAlias(normalizedAlias: normalized, displayName: display, canonicalArtistId: canonicalId).insert(db)
    }

    private func writeAlbumAlias(key: String, displayTitle: String, canonicalId: Int64, in db: Database) throws {
        try AlbumAlias(normalizedKey: key, displayTitle: displayTitle, canonicalAlbumId: canonicalId).insert(db)
    }

    // MARK: - Merge Candidates

    /// A selectable album in the merge sheet. Albums must be identified by id since titles
    /// are not unique, unlike artist-type entities keyed by their unique name.
    struct AlbumMergeCandidate: Identifiable {
        let id: Int64
        let title: String
        let artistName: String?
        let trackCount: Int
    }

    func getAlbumMergeCandidates() -> [AlbumMergeCandidate] {
        do {
            return try dbQueue.read { db in
                // Raw SQL: the primary-album-artist correlated subquery doesn't map cleanly
                // to GRDB's query interface (mirrors getAlbumEntities).
                let sql = """
                    SELECT
                        albums.id AS id,
                        albums.title AS title,
                        albums.total_tracks AS track_count,
                        (SELECT artists.name
                         FROM album_artists
                         JOIN artists ON artists.id = album_artists.artist_id
                         WHERE album_artists.album_id = albums.id AND album_artists.role = 'primary'
                         ORDER BY album_artists.position
                         LIMIT 1) AS artist_name
                    FROM albums
                    WHERE albums.total_tracks > 0
                    ORDER BY albums.sort_title COLLATE NOCASE
                    """
                return try Row.fetchAll(db, sql: sql).compactMap { row in
                    guard let id = row["id"] as Int64? else { return nil }
                    return AlbumMergeCandidate(
                        id: id,
                        title: row["title"] as String? ?? "",
                        artistName: row["artist_name"] as String?,
                        trackCount: (row["track_count"] as Int?) ?? 0
                    )
                }
            }
        } catch {
            Logger.error("Failed to get album merge candidates: \(error)")
            return []
        }
    }
}
