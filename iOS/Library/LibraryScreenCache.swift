//
// LibraryScreenCache (iOS)
//
// Prepared list presentations survive navigation. Only metadata and the first
// screen of decoded covers are warmed; the image cache retains its own budget.
// Main-actor ownership protects the snapshots, while queries, grouping and
// ImageIO decoding run away from the UI. A library revision invalidates reads.
//

import SwiftUI

@MainActor
final class LibraryScreenCache: ObservableObject {
    static let shared = LibraryScreenCache()
    static let visibleArtworkLimit = 16
    private static let snapshotLimit = 16
    private static let trackBudget = 40_000
    private static let recentTracksFetchLimit = 100
    private static let recentAlbumLimit = 10

    private(set) var recentAlbums: [AlbumEntity]?
    /// One in-flight run per preparation identity: the launch sequence and the
    /// screens' own `.task`s ask for the same preparation, and the second
    /// caller joins the first instead of decoding the same covers again.
    private var preparations: [String: Task<Void, Never>] = [:]
    @Published private(set) var playlistPreviews: [UUID: [Track]] = [:]
    private var playlistPreviewIdentity: String?

    struct Tracks: Sendable {
        let rows: [Track]
        let sections: [IndexedSection<Track>]
    }

    struct Category: Sendable {
        let items: [LibraryFilterItem]
        let sections: [IndexedSection<LibraryFilterItem>]
    }

    @Published private(set) var trackRevision = 0
    private var revision = -1
    private var tracks: [AnyHashable: Tracks] = [:]
    private var recency: [AnyHashable] = []
    private var categories: [LibraryFilterType: Category] = [:]

    func trackList(_ identity: AnyHashable, revision: Int) -> Tracks? {
        invalidate(ifNeeded: revision)
        return tracks[identity]
    }

    func category(_ type: LibraryFilterType, revision: Int) -> Category? {
        invalidate(ifNeeded: revision)
        return categories[type]
    }

    func store(_ snapshot: Tracks, identity: AnyHashable, revision: Int) {
        invalidate(ifNeeded: revision)
        recency.removeAll { $0 == identity }
        recency.append(identity)
        tracks[identity] = snapshot
        while recency.count > Self.snapshotLimit || tracks.values.reduce(0, { $0 + $1.rows.count }) > Self.trackBudget {
            tracks.removeValue(forKey: recency.removeFirst())
        }
    }

    func store(_ snapshot: Category, type: LibraryFilterType, revision: Int) {
        invalidate(ifNeeded: revision)
        categories[type] = snapshot
    }

    /// Favorite changes do not replace LibraryManager.tracks, but cached
    /// rows still need fresh heart state when revisiting a screen.
    func invalidateTrackLists() {
        tracks.removeAll()
        recency.removeAll()
        trackRevision += 1
    }

    private func invalidate(ifNeeded revision: Int) {
        guard self.revision != revision else { return }
        self.revision = revision
        tracks.removeAll()
        recency.removeAll()
        categories.removeAll()
    }

    /// Home's first frame needs both the shelf geometry and decoded covers.
    /// This bounded read runs before the tab interface is presented; later
    /// refreshes keep the previous shelf visible until its replacement is ready.
    func prepareRecentAlbums(_ library: LibraryManager) async -> [AlbumEntity]? {
        let albumEntities = library.albumEntities
        let fetchLimit = Self.recentTracksFetchLimit
        let albumLimit = Self.recentAlbumLimit
        let albums = await Task.detached(priority: .userInitiated) {
            let counts = Dictionary(
                albumEntities.compactMap { album in album.albumId.map { ($0, album.trackCount) } },
                uniquingKeysWith: { first, _ in first }
            )
            return library.recentlyPlayedAlbums(
                fetchLimit: fetchLimit,
                albumLimit: albumLimit,
                trackCountsByAlbumID: counts
            )
        }.value
        await Self.decode(albums.compactMap { album in
            guard let data = album.displayArtwork, let albumID = album.albumId else { return nil }
            return ArtworkDecode(
                data: data,
                cacheKey: ArtworkCacheKey.album(albumID),
                maxPixelSize: RecentAlbumsShelf.artworkPixelSize
            )
        })
        guard !Task.isCancelled else { return nil }
        recentAlbums = albums
        return albums
    }

    /// Prepare the first Discover frame before the tab can be selected.
    func prepareDiscover(_ library: LibraryManager) async {
        let revision = library.libraryRevision
        await joinPreparation("discover-\(revision)-\(trackRevision)") {
            await self.runDiscoverPreparation(library, revision: revision)
        }
    }

    private func runDiscoverPreparation(_ library: LibraryManager, revision: Int) async {
        await library.loadDiscoverTracks(populateArtwork: false)
        let rows = library.discoverTracks
        let selectionDate = library.discoverLastUpdated
        await Self.decode(Self.mosaicDecodes(rows) + Self.rowDecodes(rows, database: library.databaseManager))
        guard library.libraryRevision == revision,
              library.discoverLastUpdated == selectionDate else { return }
        store(
            Tracks(rows: rows, sections: [IndexedSection(key: "", items: rows)]),
            identity: AnyHashable(selectionDate),
            revision: revision
        )
    }

    static func playlistPreviewIdentity(_ playlists: [Playlist], revision: Int, trackRevision: Int) -> String {
        "\(revision)-\(trackRevision)-" + playlists.map {
            "\($0.id)-\($0.dateModified.timeIntervalSince1970)-\($0.trackCount)-\($0.name)"
        }.joined(separator: "|")
    }

    /// Publish preview data and decoded covers together. The root owns this
    /// preparation so entering Playlists does not start its first database read.
    func preparePlaylistPreviews(_ playlists: [Playlist], library: LibraryManager) async {
        let revision = library.libraryRevision
        let trackRevision = trackRevision
        let identity = Self.playlistPreviewIdentity(playlists, revision: revision, trackRevision: trackRevision)
        guard playlistPreviewIdentity != identity else { return }
        await joinPreparation("previews-\(identity)") {
            await self.runPlaylistPreviewPreparation(
                playlists, library: library, identity: identity, revision: revision, trackRevision: trackRevision
            )
        }
    }

    private func runPlaylistPreviewPreparation(
        _ playlists: [Playlist],
        library: LibraryManager,
        identity: String,
        revision: Int,
        trackRevision: Int
    ) async {
        let previews = await Task.detached(priority: .userInitiated) {
            Dictionary(uniqueKeysWithValues: playlists.compactMap { playlist -> (UUID, [Track])? in
                guard playlist.coverArtworkData == nil, PlaylistCover.of(playlist) == nil else { return nil }
                return (playlist.id, library.getPlaylistPreviewTracks(playlist, limit: 4))
            })
        }.value
        // Every playlist's covers go through one bounded queue: decoding the
        // mosaics one playlist after another was the longest part of launch.
        await Self.decode(playlists.flatMap { playlist -> [ArtworkDecode] in
            if let data = playlist.coverArtworkData {
                return [ArtworkDecode(data: data, cacheKey: ArtworkCacheKey.playlist(playlist.id), maxPixelSize: 180)]
            }
            return previews[playlist.id].map(Self.mosaicDecodes) ?? []
        })
        guard library.libraryRevision == revision,
              self.trackRevision == trackRevision else { return }
        playlistPreviews = previews
        playlistPreviewIdentity = identity
    }

    /// Called by the parent while the destination is still off-screen.
    func preparePlaylist(_ playlist: Playlist, library: LibraryManager, manager: PlaylistManager) async {
        guard !Task.isCancelled else { return }
        let revision = library.libraryRevision
        if playlist.tracks.isEmpty {
            if playlist.type == .smart {
                await manager.loadSmartPlaylistTracks(playlist)
            } else {
                await manager.loadPlaylistTracks(for: playlist.id)
            }
        }
        guard !Task.isCancelled, library.libraryRevision == revision,
              let current = manager.playlists.first(where: { $0.id == playlist.id }),
              current.dateModified == playlist.dateModified,
              !current.tracks.isEmpty || current.trackCount == 0 else { return }
        let rows = current.tracks
        let cover = current.coverArtworkData.map {
            ArtworkDecode(data: $0, cacheKey: ArtworkCacheKey.playlist(current.id), maxPixelSize: 180)
        }
        await Self.decode(
            [cover].compactMap { $0 } + Self.mosaicDecodes(rows) + Self.rowDecodes(rows, database: library.databaseManager)
        )
    }

    func prepareLibrary(_ library: LibraryManager) async {
        guard !Task.isCancelled else { return }
        let revision = library.libraryRevision
        let trackRevision = trackRevision
        if trackList("all-tracks", revision: revision) == nil {
            let snapshot = await Task.detached(priority: .utility) {
                let rows = library.getAllTracks()
                return Tracks(rows: rows, sections: Self.titleSections(rows))
            }.value
            await Self.prepareArtwork(snapshot.sections.flatMap(\.items), database: library.databaseManager)
            guard !Task.isCancelled, library.libraryRevision == revision,
                  self.trackRevision == trackRevision else { return }
            store(snapshot, identity: "all-tracks", revision: revision)
        }
        for type in LibraryFilterType.allCases {
            guard !Task.isCancelled, library.libraryRevision == revision else { return }
            _ = await prepareCategory(type, library: library)
        }
    }

    func prepareCategory(_ type: LibraryFilterType, library: LibraryManager) async -> Category? {
        guard !Task.isCancelled else { return nil }
        let revision = library.libraryRevision
        if let cached = category(type, revision: revision) { return cached }
        let fetched = await library.libraryFilterItems(for: type)
        let snapshot = await Task.detached(priority: .utility) {
            let items = fetched.sorted {
                if type == .years { return (Int($0.name.prefix(4)) ?? Int.min) > (Int($1.name.prefix(4)) ?? Int.min) }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            var sections = IndexedListSectionFactory.sections(
                from: items, key: { IndexedListSectionFactory.sectionKey(for: $0.name) }
            )
            if type == .years { sections.sort { $0.key > $1.key } }
            return Category(items: items, sections: sections)
        }.value
        let visible = type == .albums ? snapshot.items : snapshot.sections.flatMap(\.items)
        let database = library.databaseManager
        await Self.decode(visible.prefix(Self.visibleArtworkLimit).compactMap { item in
            if type == .albums, let albumID = item.albumId {
                return ArtworkDecode(
                    cacheKey: ArtworkCacheKey.album(albumID),
                    maxPixelSize: 600,
                    loader: ArtworkDataLoader { database.getAlbumArtworkThumbnail(albumId: albumID) }
                )
            } else if type == .artists {
                return ArtworkDecode(
                    cacheKey: ArtworkCacheKey.artist(item.name),
                    maxPixelSize: 180,
                    loader: ArtworkDataLoader { database.getArtistArtworkThumbnail(name: item.name) }
                )
            }
            return nil
        })
        guard !Task.isCancelled, library.libraryRevision == revision else { return nil }
        store(snapshot, type: type, revision: revision)
        return snapshot
    }

    nonisolated static func titleSections(_ rows: [Track]) -> [IndexedSection<Track>] {
        IndexedListSectionFactory.sections(from: rows, key: { IndexedListSectionFactory.sectionKey(for: $0.title) })
    }

    /// One cover to decode into the shared row cache.
    struct ArtworkDecode: Sendable {
        var data: Data?
        let cacheKey: String
        let maxPixelSize: CGFloat
        var loader: ArtworkDataLoader?
    }

    /// Decodes `jobs` a few at a time, stopping early on cancellation.
    static func decode(_ jobs: [ArtworkDecode], width: Int = 4) async {
        await withTaskGroup(of: Void.self) { group in
            for (index, job) in jobs.enumerated() {
                guard !Task.isCancelled else { return }
                if index >= width { await group.next() }
                group.addTask {
                    await ArtworkTile.prewarm(
                        data: job.data,
                        cacheKey: job.cacheKey,
                        maxPixelSize: job.maxPixelSize,
                        loader: job.loader
                    )
                }
            }
        }
    }

    static func mosaicDecodes(_ rows: [Track]) -> [ArtworkDecode] {
        PlaylistCover.mosaicCovers(from: rows).map {
            ArtworkDecode(data: $0, cacheKey: ArtworkTile.dataCacheKey($0), maxPixelSize: 180)
        }
    }

    static func rowDecodes(_ rows: [Track], database: DatabaseManager) -> [ArtworkDecode] {
        rows.prefix(visibleArtworkLimit).compactMap { track in
            guard let key = ArtworkDataLoader.cacheKey(albumId: track.albumId, trackId: track.trackId) else { return nil }
            let loader = track.trackId.flatMap {
                ArtworkDataLoader.trackListArtwork(
                    database: database,
                    albumId: track.albumId,
                    trackId: $0,
                    hasDisplayArtwork: track.displayArtwork != nil
                )
            }
            return ArtworkDecode(data: track.displayArtwork, cacheKey: key, maxPixelSize: 144, loader: loader)
        }
    }

    static func prepareArtwork(_ rows: [Track], database: DatabaseManager) async {
        await decode(rowDecodes(rows, database: database))
    }

    /// Runs `work` once per `key`; concurrent callers await the same run.
    /// The run is unstructured, so a caller's cancellation does not abandon
    /// it halfway for the others; its revision checks guard what it stores.
    private func joinPreparation(_ key: String, _ work: @escaping @MainActor () async -> Void) async {
        if let running = preparations[key] {
            await running.value
            return
        }
        let task = Task { await work() }
        preparations[key] = task
        await task.value
        preparations[key] = nil
    }
}
