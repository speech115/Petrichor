//
// PlaylistManager class
//
// This class handles all the Playlist operations done by the app, note that this file only
// contains core methods, the domain-specific logic is spread across extension files within this
// directory where each file is prefixed with `PM`.
//

import Combine
import Foundation

private struct PlaylistMembershipCacheEntry {
    let dateModified: Date
    let loadedTrackCount: Int
    let trackIDs: Set<Int64>
}

/// Narrow publisher for screens that render the playlist catalog but must not
/// redraw for queue-index, shuffle, repeat, or modal changes.
@MainActor
final class PlaylistCatalogObservation: ObservableObject {
    @Published private(set) var playlists: [Playlist]
    private var subscription: AnyCancellable?

    init(manager: PlaylistManager) {
        playlists = manager.playlists
        subscription = manager.$playlists.sink { [weak self] playlists in
            self?.playlists = playlists
        }
    }
}

/// Narrow publisher for the root create-playlist sheet. ContentView used to
/// observe all of PlaylistManager just to present this one modal, causing every
/// queue mutation to rebuild the entire tab hierarchy.
@MainActor
final class PlaylistCreatePresentationObservation: ObservableObject {
    @Published private(set) var isPresented: Bool
    @Published private(set) var playlistName: String
    @Published private(set) var tracksToAdd: [Track]
    private var subscriptions: Set<AnyCancellable> = []

    init(manager: PlaylistManager) {
        isPresented = manager.showingCreatePlaylistModal
        playlistName = manager.newPlaylistName
        tracksToAdd = manager.tracksToAddToNewPlaylist

        manager.$showingCreatePlaylistModal
            .sink { [weak self] in self?.isPresented = $0 }
            .store(in: &subscriptions)
        manager.$newPlaylistName
            .sink { [weak self] in self?.playlistName = $0 }
            .store(in: &subscriptions)
        manager.$tracksToAddToNewPlaylist
            .sink { [weak self] in self?.tracksToAdd = $0 }
            .store(in: &subscriptions)
    }
}

/// Narrow publisher for transport controls. Queue and catalog mutations do not
/// invalidate the play/pause row just to keep these two mode glyphs current.
@MainActor
final class PlaylistTransportObservation: ObservableObject {
    @Published private(set) var isShuffleEnabled: Bool
    @Published private(set) var repeatMode: RepeatMode
    private var subscriptions: Set<AnyCancellable> = []

    init(manager: PlaylistManager) {
        isShuffleEnabled = manager.isShuffleEnabled
        repeatMode = manager.repeatMode

        manager.$isShuffleEnabled
            .removeDuplicates()
            .sink { [weak self] in self?.isShuffleEnabled = $0 }
            .store(in: &subscriptions)
        manager.$repeatMode
            .removeDuplicates(by: { $0 == $1 })
            .sink { [weak self] in self?.repeatMode = $0 }
            .store(in: &subscriptions)
    }
}

/// Narrow publisher for the queue panel. Playlist catalog, modal, shuffle and
/// repeat publications stay outside this observation boundary.
@MainActor
final class PlaylistQueueObservation: ObservableObject {
    @Published private(set) var currentQueue: [Track]
    @Published private(set) var currentQueueIndex: Int
    private var subscriptions: Set<AnyCancellable> = []

    init(manager: PlaylistManager) {
        currentQueue = manager.currentQueue
        currentQueueIndex = manager.currentQueueIndex

        manager.$currentQueue
            .sink { [weak self] in self?.currentQueue = $0 }
            .store(in: &subscriptions)
        manager.$currentQueueIndex
            .removeDuplicates()
            .sink { [weak self] in self?.currentQueueIndex = $0 }
            .store(in: &subscriptions)
    }
}

@MainActor
class PlaylistManager: ObservableObject {
    @Published var playlists: [Playlist] = []
    @Published var currentPlaylist: Playlist?
    @Published var isShuffleEnabled: Bool = false
    @Published var repeatMode: RepeatMode = .off
    @Published var currentQueue: [Track] = []
    @Published var currentQueueIndex: Int = -1
    @Published var currentQueueSource: QueueSource = .library
    @Published var showingCreatePlaylistModal = false
    @Published var tracksToAddToNewPlaylist: [Track] = []
    @Published var newPlaylistName = ""
    // Smart playlist editor: presented for both creating (toEdit == nil) and editing.
    @Published var showingSmartPlaylistEditor = false
    @Published var smartPlaylistToEdit: Playlist?
    // Regular playlist editor (name + song selection): presented for both creating
    // (toEdit == nil) and editing an existing playlist.
    @Published var showingRegularPlaylistEditor = false
    @Published var regularPlaylistToEdit: Playlist?

    lazy var catalogObservation = PlaylistCatalogObservation(manager: self)
    lazy var createPresentationObservation = PlaylistCreatePresentationObservation(manager: self)
    lazy var transportObservation = PlaylistTransportObservation(manager: self)
    lazy var queueObservation = PlaylistQueueObservation(manager: self)

    enum QueueSource {
        case library
        case folder
        case playlist
    }

    // MARK: - Private/Internal Properties
    internal var libraryManager: LibraryManager?

    /// Smart playlists whose tracks are currently being loaded, to collapse concurrent
    /// duplicate loads (e.g. PlaylistDetailView firing onAppear + onChange together).
    /// Mutated only on the main actor.
    internal var loadingSmartPlaylistIDs: Set<UUID> = []
    /// Regular playlists use the same single-flight rule. A list reload can
    /// overlap its initial `.task`; both callers otherwise materialize the same
    /// track and artwork arrays at once.
    internal var loadingRegularPlaylistIDs: Set<UUID> = []

    /// Context menus ask the same membership question for every visible row.
    /// Keep one ID set per loaded playlist so those checks stay O(1) instead of
    /// walking a 1000+ track array for every row update.
    private var playlistMembershipCache: [UUID: PlaylistMembershipCacheEntry] = [:]

    // MARK: - Dependencies
    internal weak var audioPlayer: PlaybackManager?

    // MARK: - Queue writes
    //
    // `currentQueue` must stay artwork-free: assigning thousands of `Data`
    // blobs into the `@Published` array stalls the main actor. Every full
    // replace and single-entry update goes through these helpers.

    /// Sole full-queue writer. Strips artwork payloads before publishing.
    internal func replaceCurrentQueue(_ tracks: [Track], index: Int? = nil) {
        currentQueue = tracks.map { $0.withoutArtwork() }
        if let index {
            currentQueueIndex = index
        }
    }

    /// Single-entry update that keeps the queue payload-light.
    internal func replaceCurrentQueueEntry(at index: Int, with track: Track) {
        guard currentQueue.indices.contains(index) else { return }
        currentQueue[index] = track.withoutArtwork()
    }

    internal func insertCurrentQueueEntry(_ track: Track, at index: Int) {
        currentQueue.insert(track.withoutArtwork(), at: index)
    }

    internal func appendCurrentQueueEntry(_ track: Track) {
        currentQueue.append(track.withoutArtwork())
    }

    // MARK: - Initialization
    init() {
        // Don't load playlists yet - wait until libraryManager is set
    }

    func setAudioPlayer(_ player: PlaybackManager) {
        self.audioPlayer = player
    }

    func setLibraryManager(_ manager: LibraryManager) {
        self.libraryManager = manager
        Logger.info("Library manager set, loading playlists...")
        loadPlaylists()
    }

    func playlistContainsTrack(_ track: Track, in playlist: Playlist) -> Bool {
        guard let trackID = track.trackId else { return false }

        let loadedTrackCount = playlist.tracks.count
        let cached = playlistMembershipCache[playlist.id]
        if cached?.dateModified == playlist.dateModified,
           cached?.loadedTrackCount == loadedTrackCount {
            return cached?.trackIDs.contains(trackID) ?? false
        }

        let trackIDs = Set(playlist.tracks.compactMap(\.trackId))
        playlistMembershipCache[playlist.id] = PlaylistMembershipCacheEntry(
            dateModified: playlist.dateModified,
            loadedTrackCount: loadedTrackCount,
            trackIDs: trackIDs
        )
        return trackIDs.contains(trackID)
    }

    // MARK: - Convenience Methods

    /// Toggle favorite status for a single track
    func toggleFavorite(for track: Track, currentState: Bool? = nil) {
        let finalState: Bool?
        if let currentState = currentState {
            finalState = !currentState
        } else {
            finalState = nil
        }
        toggleFavorite(for: [track], setTo: finalState)
    }

    /// Toggle favorite status for multiple tracks
    func toggleFavorite(for tracks: [Track], setTo finalState: Bool? = nil) {
        Task {
            for track in tracks {
                let isFavorite: Bool
                if let finalState = finalState {
                    isFavorite = finalState
                } else {
                    isFavorite = !track.isFavorite
                }
                await updateTrackFavoriteStatus(track: track, isFavorite: isFavorite)
            }
        }
    }

    /// Remove track from a specific playlist by ID
    func removeTrackFromPlaylist(track: Track, playlistID: UUID) {
        if let playlist = playlists.first(where: { $0.id == playlistID }) {
            updateTrackInPlaylist(track: track, playlist: playlist, add: false)
        }
    }
    
    func updateSmartPlaylistCounts() {
        // Only auto-updating smart playlists need their count computed from criteria.
        // Frozen playlists already carry the correct count from their persisted snapshot.
        let autoSmart = playlists.filter { $0.type == .smart && ($0.smartCriteria?.autoUpdate ?? true) }
        guard let dbManager = libraryManager?.databaseManager, !autoSmart.isEmpty else { return }

        // One batched read for all counts instead of N separate awaited reads.
        Task {
            let counts = await dbManager.getSmartPlaylistTrackCounts(autoSmart)
            await MainActor.run {
                for (id, count) in counts {
                    if let index = self.playlists.firstIndex(where: { $0.id == id }) {
                        self.playlists[index].trackCount = count
                    }
                }
            }
        }
    }
    
    /// Load all playlists from database
    func loadPlaylists() {
        guard let dbManager = libraryManager?.databaseManager else {
            return
        }
        
        let savedPlaylists = dbManager.loadAllPlaylists()
        
        let savedSmartPlaylists = savedPlaylists.filter { $0.type == .smart }
        let savedRegularPlaylists = savedPlaylists.filter { $0.type == .regular }
        
        playlists = sortPlaylists(smart: savedSmartPlaylists, regular: savedRegularPlaylists)
        
        if let favorites = playlists.first(where: {
            $0.name == DefaultPlaylists.favorites && $0.type == .smart
        }) {
            PlaylistSortManager.shared.clearStaleFavoritesDateAddedPreference(for: favorites.id)
        }

        updateSmartPlaylistCounts()
    }
    
    /// Ensure tracks are loaded for a playlist. Rows are list rows: the
    /// display-size artwork pass is skipped. Only the first four album
    /// thumbnails are filled for a possible header mosaic; visible rows load
    /// their own thumbnails. Reads stay off the main thread; every access to
    /// `playlists` is isolated via `MainActor.run` (mirrors
    /// `loadSmartPlaylistTracks`).
    func loadPlaylistTracks(for playlistId: UUID) async {
        guard let dbManager = libraryManager?.databaseManager else { return }

        let shouldLoad = await MainActor.run { () -> Bool in
            guard let playlist = playlists.first(where: { $0.id == playlistId }),
                  playlist.type == .regular,
                  playlist.tracks.isEmpty,
                  !loadingRegularPlaylistIDs.contains(playlistId) else { return false }
            loadingRegularPlaylistIDs.insert(playlistId)
            return true
        }
        guard shouldLoad else { return }

        var tracks = dbManager.loadTracksForPlaylist(playlistId, populateArtwork: false)
        dbManager.populateAlbumArtworkThumbnailsForTracks(&tracks, limit: 4)
        let loadedTracks = tracks

        await MainActor.run {
            if let index = playlists.firstIndex(where: { $0.id == playlistId }) {
                playlists[index].tracks = loadedTracks
            }
            loadingRegularPlaylistIDs.remove(playlistId)
        }
    }
    
    /// Get tracks for a playlist, loading them if needed. Async: the load
    /// path is the same `loadPlaylistTracks` used by the list screens, which
    /// never pulls the display-size artwork BLOBs (export and automation
    /// only need the file URLs). `playlists` reads are isolated via
    /// `MainActor.run`, mirroring `loadPlaylistTracks`.
    func getPlaylistTracks(_ playlist: Playlist) async -> [Track] {
        if playlist.type == .smart {
            // Smart playlists are already handled differently
            return playlist.tracks
        }
        
        // For regular playlists, load tracks if not already loaded
        if playlist.tracks.isEmpty {
            await loadPlaylistTracks(for: playlist.id)
        }
        
        return await MainActor.run {
            playlists.first { $0.id == playlist.id }?.tracks ?? []
        }
    }
    
    /// Sort playlists: smart playlists first (by dateCreated), then regular playlists (by sortOrder, dateCreated as tiebreaker)
    func sortPlaylists(smart: [Playlist], regular: [Playlist]) -> [Playlist] {
        let sortedSmart = smart.sorted { $0.dateCreated < $1.dateCreated }
        let sortedRegular = regular.sorted {
            $0.sortOrder == $1.sortOrder ? $0.dateCreated < $1.dateCreated : $0.sortOrder < $1.sortOrder
        }
        return sortedSmart + sortedRegular
    }

    /// Reorder user playlists and persist the new order
    func reorderPlaylists(_ reorderedPlaylists: [Playlist]) {
        guard let dbManager = libraryManager?.databaseManager else { return }

        playlists = reorderedPlaylists

        Task {
            do {
                try await dbManager.updatePlaylistsOrder(reorderedPlaylists)
            } catch {
                Logger.error("Failed to reorder playlists: \(error)")
            }
        }
    }
}
