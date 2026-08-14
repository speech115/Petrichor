//
// SpotlightIndexer (iOS)
//
// CoreSpotlight integration: the library is findable from iOS system search
// (tracks, albums, artists; playlists are intentionally not indexed - their
// export names like "05 Spotify - Shazam" are noise in a system search).
//
// Sync model: three fingerprints live in UserDefaults and double as the
// full-pass cursor. Every sync diffs the current database against them and
// touches only what changed:
//
//   - a track whose id is missing from the snapshot, or whose `date_modified`
//     changed (the scan rewrites it exactly when a file was added or updated),
//     is (re)indexed;
//   - a track that left the database (folder removal cascades, merges) is
//     deleted from the index - the database is the canon (ADR-0001), so a
//     file disappearing from disk alone never removes an index entry;
//   - albums and artists carry a cheap fingerprint (title + track count +
//     thumbnail size), so merges and artwork changes refresh them without a
//     per-item diff.
//
// The first sync after a fresh install finds an empty snapshot and indexes
// everything, chunked, saving the snapshot after each chunk: an interrupted
// pass resumes from where it stopped on the next launch. The sync is always
// scheduled after reconciliation ends (`.utility`, never before), so a cold
// start is not slowed down by indexing.
//
// A database reset (`LibraryManager.resetAllData()`) is not just another
// change to diff: it erases the file and re-migrates, so ids restart from 1
// and the snapshot's old entries would misdescribe whatever reuses them.
// `.libraryDataDidReset` routes that case to `resetIndex`, which wipes the
// system index and the snapshot outright before resyncing - see there.
//

import CoreSpotlight
import Foundation
import GRDB
import UniformTypeIdentifiers

/// Identifier prefixes, also the `domainIdentifier` of the indexed items.
enum SpotlightDomain {
    static let track = "track"
    static let album = "album"
    static let artist = "artist"

    static func identifier(domain: String, value: String) -> String {
        "\(domain):\(value)"
    }
}

final actor SpotlightIndexer {
    static let shared = SpotlightIndexer()

    // MARK: - Snapshot Storage (also the full-pass cursor)

    private enum Keys {
        /// [String: String] - "trackId" -> `String(date_modified)` at index
        /// time. A pre-refactor build wrote `[String: Double]` here; that value
        /// fails the `as? [String: String]` cast cleanly and reads as an empty
        /// snapshot, triggering a one-time full reindex on first upgrade.
        static let trackSnapshot = "spotlight.indexedTracks"
        /// [String: String] - "albumId" -> "title|trackCount|thumbnailBytes".
        static let albumSnapshot = "spotlight.indexedAlbums"
        /// [String: String] - "artistName" -> "trackCount|thumbnailBytes".
        static let artistSnapshot = "spotlight.indexedArtists"
    }

    private let userDefaults: UserDefaults
    private var isSyncing = false
    /// Set by `resetIndex` when a database reset lands while a sync is
    /// mid-flight. The in-flight pass is allowed to finish, then a fresh pass
    /// re-runs against the post-reset database instead of leaving the
    /// pre-reset snapshot in place.
    private var resetPending = false

    /// Batch size for the full pass. Keeps one `indexSearchableItems` call (and
    /// one thumbnail batch) bounded, and gives the progress cursor a save
    /// point every `chunkSize` items.
    private let chunkSize = 200

    private let index = CSSearchableIndex.default()

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    /// Entry point, called from `LibraryManager`'s iOS reconciliation and
    /// rescan paths after the database is up to date, and from
    /// `observeLibraryChanges()` below. Fire-and-forget: runs at `.utility`
    /// priority and never blocks the caller.
    nonisolated static func scheduleSync(with databaseManager: DatabaseManager) {
        Task(priority: .utility) {
            await SpotlightIndexer.shared.syncAfterReconciliation(databaseManager: databaseManager)
        }
    }

    // MARK: - Change Notifications

    /// Guards the one-time observer registration below. Actor state, so
    /// `observeLibraryChanges()` needs no unsafe static bookkeeping.
    private var isObservingLibraryChanges = false

    /// Real database deletions - folder removal (`DMFolders.removeFolder`
    /// cascades to its tracks) and entity merges (`DMMerge.mergeAlbums` /
    /// `mergeArtists`) - happen in `Managers/`, which cannot import
    /// CoreSpotlight without breaking the platform-neutral seam rule. Every
    /// one of those call sites already ends by posting `.libraryDataDidChange`
    /// (folder removal through `loadMusicLibrary()` -> `refreshEntities()`,
    /// merges directly), so this listens for that instead: a resync re-diffs
    /// the live database against the snapshot, and the only entries it ever
    /// removes are ones no longer present there (ADR-0001 - a file merely
    /// missing from disk never triggers this notification on its own).
    ///
    /// Called once from `PetrichorApp.init()`. Idempotent.
    nonisolated static func observeLibraryChanges() {
        Task {
            await SpotlightIndexer.shared.registerLibraryChangeObservers()
        }
    }

    /// Registers the `.libraryDataDidChange` / `.libraryDataDidReset`
    /// observers exactly once. The observer blocks are `@Sendable`, so the
    /// main-actor `AppCoordinator.shared` lookup happens inside a
    /// `Task { @MainActor }` hop; the extracted `databaseManager` is
    /// nonisolated and crosses into the fire-and-forget sync as a value.
    private func registerLibraryChangeObservers() {
        guard !isObservingLibraryChanges else { return }
        isObservingLibraryChanges = true
        NotificationCenter.default.addObserver(
            forName: .libraryDataDidChange,
            object: nil,
            queue: nil
        ) { _ in
            Task { @MainActor in
                guard let databaseManager = AppCoordinator.shared?.libraryManager.databaseManager else { return }
                Self.scheduleSync(with: databaseManager)
            }
        }
        NotificationCenter.default.addObserver(
            forName: .libraryDataDidReset,
            object: nil,
            queue: nil
        ) { _ in
            Task { @MainActor in
                guard let databaseManager = AppCoordinator.shared?.libraryManager.databaseManager else { return }
                Self.scheduleReset(with: databaseManager)
            }
        }
    }

    /// `resetDatabase()` erases the file and re-migrates: the next scan's
    /// tracks and albums start from id 1 again. A plain resync would diff
    /// those against the surviving snapshot and could read a reused id as
    /// "unchanged" if its digest happens to coincide with what the deleted
    /// row left behind - stale title/artist/album would then sit in the
    /// system index under content that no longer matches it. Wipe first
    /// (`resetIndex`), so the reused id has no prior digest to be confused
    /// with; run/`scheduleSync` after that resyncs as usual.
    nonisolated static func scheduleReset(with databaseManager: DatabaseManager) {
        Task(priority: .utility) {
            await SpotlightIndexer.shared.resetIndex(databaseManager: databaseManager)
        }
    }

    func syncAfterReconciliation(databaseManager: DatabaseManager) async {
        guard !isSyncing else {
            Logger.info("Spotlight sync already in progress, skipping duplicate trigger")
            return
        }
        isSyncing = true
        defer { isSyncing = false }

        // A reset requested mid-sync (`resetPending`) re-runs the pass once
        // the current one ends, so the snapshot never survives under stale
        // pre-reset content.
        repeat {
            resetPending = false
            do {
                try await performSync(databaseManager: databaseManager)
            } catch {
                Logger.error("Spotlight sync failed: \(error)")
            }
        } while resetPending
    }

    /// Clears the system index and the three id/digest snapshots outright,
    /// then runs a normal sync: with an empty snapshot every current row
    /// reads as new and gets freshly indexed, so nothing from before the
    /// reset can survive under a reused id. Not gated on `isSyncing` - a
    /// reset must win even if a sync happens to be mid-flight, since the
    /// database underneath it was just erased regardless.
    func resetIndex(databaseManager: DatabaseManager) async {
        do {
            try await index.deleteAllSearchableItems()
        } catch {
            Logger.error("Spotlight: failed to clear the index on reset: \(error)")
        }
        userDefaults.removeObject(forKey: Keys.trackSnapshot)
        userDefaults.removeObject(forKey: Keys.albumSnapshot)
        userDefaults.removeObject(forKey: Keys.artistSnapshot)
        Logger.info("Spotlight: cleared the index and snapshot after a database reset")

        // A sync already in flight holds pre-reset reads; its own snapshot
        // write would resurrect the stale state this wipe just removed. Ask
        // it to re-run after it ends rather than syncing here (which would
        // return early on `isSyncing` and lose the resync entirely).
        if isSyncing {
            resetPending = true
        } else {
            await syncAfterReconciliation(databaseManager: databaseManager)
        }
    }

    // MARK: - Sync

    private func performSync(databaseManager: DatabaseManager) async throws {
        let startedAt = Date()

        let trackChanges = try await syncTracks(databaseManager: databaseManager)
        let albumChanges = try await syncAlbums(databaseManager: databaseManager)
        let artistChanges = try await syncArtists(databaseManager: databaseManager)

        let totalIndexed = trackChanges.indexed + albumChanges.indexed + artistChanges.indexed
        let totalDeleted = trackChanges.deleted + albumChanges.deleted + artistChanges.deleted
        if totalIndexed == 0 && totalDeleted == 0 {
            Logger.info("Spotlight: library unchanged, nothing to index")
            return
        }

        let elapsed = Date().timeIntervalSince(startedAt)
        Logger.info(
            String(
                format: "Spotlight: indexed %d items (%d tracks, %d albums, %d artists), deleted %d, in %.1f s",
                totalIndexed,
                trackChanges.indexed,
                albumChanges.indexed,
                artistChanges.indexed,
                totalDeleted,
                elapsed
            )
        )
    }

    private struct Changes {
        var indexed = 0
        var deleted = 0
    }

    /// One sync pass over a single entity kind: diff the current fingerprints
    /// against the snapshot, delete stale entries, then chunk-index the rest
    /// and advance the snapshot per chunk. The three entity kinds (tracks,
    /// albums, artists) differ only in the key type, the snapshot key and how
    /// they build items — not in this algorithm.
    private func syncEntityKind<Key: Hashable>(
        domain: String,
        snapshotKey: String,
        entityName: String,
        keyString: @escaping (Key) -> String,
        current: [Key: String],
        databaseManager: DatabaseManager,
        makeItems: @escaping ([Key], DatabaseManager) async throws -> [CSSearchableItem]
    ) async throws -> Changes {
        var snapshot = userDefaults.dictionary(forKey: snapshotKey) as? [String: String] ?? [:]

        var toIndex: [Key] = []
        for (key, fingerprint) in current where snapshot[keyString(key)] != fingerprint {
            toIndex.append(key)
        }
        toIndex.sort { keyString($0) < keyString($1) }

        var changes = Changes()

        // Keys that left the database: their index entries are stale. Build the
        // surviving key set once (O(n)) — a per-key linear scan of `current`
        // inside `filter` would be O(n·m) with a string alloc per comparison.
        let currentKeys = Set(current.keys.map(keyString))
        let stale = snapshot.keys.filter { !currentKeys.contains($0) }
        if !stale.isEmpty {
            let identifiers = stale.map { SpotlightDomain.identifier(domain: domain, value: $0) }
            try await index.deleteSearchableItems(withIdentifiers: identifiers)
            for key in stale {
                snapshot.removeValue(forKey: key)
            }
            userDefaults.set(snapshot, forKey: snapshotKey)
            Logger.info("Spotlight: deleted \(stale.count) stale \(entityName) entries from the index")
        }
        changes.deleted = stale.count
        changes.indexed = toIndex.count

        for chunk in stride(from: 0, to: toIndex.count, by: chunkSize) {
            let keys = Array(toIndex[chunk..<min(chunk + chunkSize, toIndex.count)])
            let items = try await makeItems(keys, databaseManager)
            guard !items.isEmpty else { continue }
            try await index.indexSearchableItems(items)
            for key in keys {
                snapshot[keyString(key)] = current[key] ?? ""
            }
            userDefaults.set(snapshot, forKey: snapshotKey)
        }

        return changes
    }

    // MARK: - Tracks

    private func syncTracks(databaseManager: DatabaseManager) async throws -> Changes {
        // id -> date_modified as stored in the database. The scan rewrites
        // `date_modified` exactly for files that were added or changed, so it
        // is the change detector for the incremental pass.
        let current = try await databaseManager.dbQueue.read { db -> [Int64: String] in
            var result: [Int64: String] = [:]
            let rows = try Row.fetchAll(db, sql: "SELECT id, date_modified FROM tracks")
            result.reserveCapacity(rows.count)
            for row in rows {
                let id: Int64 = row["id"]
                let modified: Date? = row["date_modified"]
                result[id] = String(modified?.timeIntervalSince1970 ?? 0)
            }
            return result
        }

        return try await syncEntityKind(
            domain: SpotlightDomain.track,
            snapshotKey: Keys.trackSnapshot,
            entityName: "track",
            keyString: { String($0) },
            current: current,
            databaseManager: databaseManager
        ) { ids, databaseManager in
            try await self.makeTrackItems(ids: ids, databaseManager: databaseManager)
        }
    }

    /// Sendable projection of the raw `SELECT` below, decoded inside the
    /// `dbQueue.read` closure so the read stays on the async `DatabaseReader`
    /// overload (see `makeTrackItems`).
    private struct TrackRow: Sendable {
        let id: Int64
        let title: String
        let artist: String
        let album: String
        let albumThumbnail: Data?
        let trackArtwork: Data?
    }

    /// Build CoreSpotlight items for a batch of track ids: title, artist and
    /// album in the description, thumbnail from the album's `artwork_thumbnail`
    /// or - for the ~404 tracks whose only cover is `track_artwork_data` -
    /// from a freshly made thumbnail, never a full-size BLOB.
    nonisolated private func makeTrackItems(ids: [Int64], databaseManager: DatabaseManager) async throws -> [CSSearchableItem] {
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let sql = """
            SELECT
                t.id,
                t.title,
                t.artist,
                t.album,
                t.album_id,
                a.artwork_thumbnail AS album_thumbnail,
                CASE WHEN a.artwork_thumbnail IS NULL THEN t.track_artwork_data END AS track_artwork
            FROM tracks t
            LEFT JOIN albums a ON a.id = t.album_id
            WHERE t.id IN (\(placeholders))
            """
        // Decoded into a Sendable struct inside the closure: `Row` itself isn't
        // Sendable, and returning it directly makes the compiler fall back to
        // `read`'s synchronous overload, which turns the `await` above into a
        // silent no-op (and a warning).
        let rows: [TrackRow] = try await databaseManager.dbQueue.read { db in
            try Row.fetchAll(db, sql: sql, arguments: StatementArguments(ids)).map { row in
                TrackRow(
                    id: row["id"],
                    title: row["title"],
                    artist: row["artist"],
                    album: row["album"],
                    albumThumbnail: row["album_thumbnail"],
                    trackArtwork: row["track_artwork"]
                )
            }
        }

        var items: [CSSearchableItem] = []
        items.reserveCapacity(rows.count)
        for row in rows {
            let id = row.id
            let title = row.title
            let artist = row.artist
            let album = row.album
            let albumThumbnail = row.albumThumbnail
            let trackArtwork = row.trackArtwork

            let attributeSet = CSSearchableItemAttributeSet(contentType: UTType.audio)
            attributeSet.title = title
            attributeSet.contentDescription = "\(artist) — \(album)"
            if let albumThumbnail {
                attributeSet.thumbnailData = albumThumbnail
            } else if let trackArtwork,
                      let thumbnail = ImageUtils.makeThumbnail(from: trackArtwork) {
                attributeSet.thumbnailData = thumbnail
            }

            items.append(CSSearchableItem(
                uniqueIdentifier: SpotlightDomain.identifier(domain: SpotlightDomain.track, value: String(id)),
                domainIdentifier: SpotlightDomain.track,
                attributeSet: attributeSet
            ))
        }
        return items
    }

    // MARK: - Albums

    private struct ArtistDigest {
        let trackCount: Int
        let thumbnail: Data?

        var fingerprint: String { "\(trackCount)|\(thumbnail?.count ?? 0)" }
    }

    private struct AlbumDigest {
        let title: String
        let trackCount: Int
        let thumbnail: Data?

        var fingerprint: String { "\(title)|\(trackCount)|\(thumbnail?.count ?? 0)" }
    }

    private func syncAlbums(databaseManager: DatabaseManager) async throws -> Changes {
        // id -> digest. The digest query carries everything needed to build
        // the item, so a changed fingerprint re-indexes in one pass.
        let current = try await databaseManager.dbQueue.read { db -> [Int64: AlbumDigest] in
            let sql = """
                SELECT a.id, a.title, a.artwork_thumbnail, COUNT(t.id) AS trackCount
                FROM albums a
                LEFT JOIN tracks t ON t.album_id = a.id
                GROUP BY a.id
                HAVING trackCount > 0
                """
            let rows = try Row.fetchAll(db, sql: sql)
            var result: [Int64: AlbumDigest] = [:]
            result.reserveCapacity(rows.count)
            for row in rows {
                let id: Int64 = row["id"]
                let title: String = row["title"]
                let count: Int = row["trackCount"] ?? 0
                let thumbnail: Data? = row["artwork_thumbnail"]
                result[id] = AlbumDigest(title: title, trackCount: count, thumbnail: thumbnail)
            }
            return result
        }

        return try await syncEntityKind(
            domain: SpotlightDomain.album,
            snapshotKey: Keys.albumSnapshot,
            entityName: "album",
            keyString: { String($0) },
            current: current.mapValues { $0.fingerprint },
            databaseManager: databaseManager
        ) { ids, _ in
            ids.compactMap { id -> CSSearchableItem? in
                guard let digest = current[id] else { return nil }
                let attributeSet = CSSearchableItemAttributeSet()
                attributeSet.title = digest.title
                if let thumbnail = digest.thumbnail {
                    attributeSet.thumbnailData = thumbnail
                }
                return CSSearchableItem(
                    uniqueIdentifier: SpotlightDomain.identifier(domain: SpotlightDomain.album, value: String(id)),
                    domainIdentifier: SpotlightDomain.album,
                    attributeSet: attributeSet
                )
            }
        }
    }

    // MARK: - Artists

    private func syncArtists(databaseManager: DatabaseManager) async throws -> Changes {
        // Artists have no stable database id at the seam the search results
        // route through (the app's artist pages key on the name), so the
        // identifier and the snapshot key are both the name.
        let current = try await databaseManager.dbQueue.read { db -> [String: ArtistDigest] in
            let sql = """
                SELECT artists.name, artists.artwork_thumbnail, COUNT(DISTINCT track_artists.track_id) AS trackCount
                FROM artists
                JOIN track_artists ON track_artists.artist_id = artists.id AND track_artists.role = 'artist'
                JOIN tracks ON tracks.id = track_artists.track_id
                GROUP BY artists.id
                HAVING trackCount > 0
                """
            let rows = try Row.fetchAll(db, sql: sql)
            var result: [String: ArtistDigest] = [:]
            result.reserveCapacity(rows.count)
            for row in rows {
                let name: String = row["name"]
                let count: Int = row["trackCount"] ?? 0
                let thumbnail: Data? = row["artwork_thumbnail"]
                result[name] = ArtistDigest(trackCount: count, thumbnail: thumbnail)
            }
            return result
        }

        return try await syncEntityKind(
            domain: SpotlightDomain.artist,
            snapshotKey: Keys.artistSnapshot,
            entityName: "artist",
            keyString: { $0 },
            current: current.mapValues { $0.fingerprint },
            databaseManager: databaseManager
        ) { names, _ in
            names.compactMap { name -> CSSearchableItem? in
                guard let digest = current[name] else { return nil }
                let attributeSet = CSSearchableItemAttributeSet()
                attributeSet.title = name
                if let thumbnail = digest.thumbnail {
                    attributeSet.thumbnailData = thumbnail
                }
                return CSSearchableItem(
                    uniqueIdentifier: SpotlightDomain.identifier(domain: SpotlightDomain.artist, value: name),
                    domainIdentifier: SpotlightDomain.artist,
                    attributeSet: attributeSet
                )
            }
        }
    }
}
