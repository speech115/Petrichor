import SwiftUI

/// Which columns a track table opens with.
enum TrackTableLayout {
    /// The library columns the user customizes once for every table.
    case standard
    /// An album page, as on the iPhone: track number, title, artist and
    /// duration, without artwork or column headers.
    case album
}

struct TrackTableView: View {
    let tracks: [Track]
    let playlistID: UUID?
    let entityID: UUID?
    var layout: TrackTableLayout = .standard
    /// False leaves the "#" column blank: the tags' numbers aren't real track numbers.
    var showsTrackNumbers = true
    let onPlayTrack: (Track) -> Void
    let contextMenuItems: ([Track], PlaybackManager) -> [ContextMenuItem]
    @Binding var sortOrder: [KeyPathComparator<Track>]
    @Binding var tableRowSize: TableRowSize

    @EnvironmentObject var playbackManager: PlaybackManager
    @EnvironmentObject var playlistManager: PlaylistManager
    @EnvironmentObject var libraryManager: LibraryManager

    @State private var selection: Set<Track.ID> = []
    @State private var sortedTracks: [Track] = []
    @State private var trackFavorites: [Int64: Bool] = [:]

    @State private var isCustomSort: Bool = false
    @State private var sortGeneration = 0

    /// Album rows carry no artwork: the cover is already in the page header.
    private var rowSize: TableRowSize {
        layout == .album ? .compact : tableRowSize
    }

    private func isCurrentTrack(_ track: Track) -> Bool {
        guard let currentTrack = playbackManager.currentTrack else { return false }
        if let currentId = currentTrack.trackId, let trackId = track.trackId {
            return currentId == trackId
        }
        return currentTrack.url.path == track.url.path
    }

    private func isFavorite(_ track: Track) -> Bool {
        guard let trackId = track.trackId else { return track.isFavorite }

        if let favorite = trackFavorites[trackId] {
            return favorite
        }

        return track.isFavorite
    }

    var body: some View {
        TrackTable(
            listID: playlistID ?? entityID,
            tracks: sortedTracks,
            selection: $selection,
            sortOrder: $sortOrder,
            isCustomSort: isCustomSort,
            layout: layout,
            rowSize: rowSize,
            showsTrackNumbers: showsTrackNumbers,
            database: libraryManager.databaseManager,
            currentTrack: playbackManager.currentTrack,
            isPlaying: playbackManager.isPlaying,
            isFavorite: isFavorite,
            onPlayTrack: handlePlayTrack,
            onTogglePlayPause: { playbackManager.togglePlayPause() },
            onPrimaryAction: handleDoubleTap,
            onToggleFavorite: { track, isFavorite in
                playlistManager.toggleFavorite(for: track, currentState: isFavorite)
            },
            contextMenuItems: { contextMenuItems($0, playbackManager) }
        )
        .onChange(of: sortOrder) { oldValue, newValue in
            if oldValue != newValue {
                // Table column header click overrides custom sort
                if isCustomSort {
                    isCustomSort = false
                }

                if let playlistID = playlistID {
                    PlaylistSortManager.shared.setSortField(TrackSortField.detect(from: newValue), for: playlistID)
                    PlaylistSortManager.shared.setSortAscending(TrackSortField.isAscending(from: newValue), for: playlistID)
                }

                performBackgroundSort(with: newValue)

                saveSortOrderToUserDefaults(newValue, key: "trackTableSortOrder")

                NotificationCenter.default.post(
                    name: .trackTableSortChanged,
                    object: nil,
                    userInfo: ["sortOrder": newValue, "fromTable": true]
                )
            }
        }
        .onChange(of: tracks) { _, newTracks in
            if !newTracks.isEmpty {
                // Re-sync custom sort state for the current playlist
                if let playlistID = playlistID {
                    isCustomSort = PlaylistSortManager.shared.getSortField(for: playlistID) == .custom
                }

                if isCustomSort {
                    sortGeneration &+= 1
                    sortedTracks = newTracks
                } else {
                    performBackgroundSort(with: sortOrder)
                }

                trackFavorites = Dictionary(uniqueKeysWithValues:
                    newTracks.compactMap { track in
                        guard let trackId = track.trackId else { return nil }
                        return (trackId, track.isFavorite)
                    }
                )
            }
        }
        .onAppear {
            initializeSortedTracks()
        }
        // A playlist page keeps this table when another playlist opens; the
        // new tracks arrive through `onChange(of: tracks)`.
        .onChange(of: playlistID) {
            selection = []
        }
        .onReceive(NotificationCenter.default.publisher(for: .playEntityTracks)) { notification in
            handlePlayEntityNotification(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: .playPlaylistTracks)) { notification in
            handlePlayPlaylistNotification(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: .trackTableSortChanged)) { notification in
            handleSortChangedNotification(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: .trackTableRowSizeChanged)) { notification in
            handleRowSizeChangedNotification(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: .trackFavoriteStatusChanged)) { notification in
            handleTrackFavoriteStatusChanged(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: .createPlaylistFromSelection)) { _ in
            if !selection.isEmpty {
                let selectedTracks = sortedTracks.filter { selection.contains($0.id) }
                if !selectedTracks.isEmpty {
                    playlistManager.showCreatePlaylistModal(with: selectedTracks)
                }
            }
        }
    }

    // MARK: - Helper Methods

    private func initializeSortedTracks() {
        // Check for custom sort on playlists (position-based order from DB)
        if let playlistID = playlistID,
           PlaylistSortManager.shared.getSortField(for: playlistID) == .custom {
            isCustomSort = true
            sortGeneration &+= 1
            sortedTracks = tracks
            return
        }

        // Follow overridden sort order for entities and playlists
        if entityID != nil || playlistID != nil {
            performBackgroundSort(with: sortOrder)
            return
        }

        if let savedSort = UserDefaults.standard.dictionary(forKey: "trackTableSortOrder"),
           let key = savedSort["key"] as? String,
           let ascending = savedSort["ascending"] as? Bool,
           let field = TrackSortField.from(storageKey: key) {
            let comparator = field.getComparator(ascending: ascending)
            sortOrder = [comparator]
            performBackgroundSort(with: [comparator])
            return
        }

        let defaultComparator = KeyPathComparator(\Track.title, order: .forward)
        sortOrder = [defaultComparator]
        performBackgroundSort(with: [defaultComparator])
    }


    private func handleDoubleTap(on track: Track) {
        if isCurrentTrack(track) {
            playbackManager.togglePlayPause()
        } else {
            handlePlayTrack(track)
        }
    }

    private func handlePlayTrack(_ track: Track) {
        playlistManager.playTrack(track, fromTracks: sortedTracks)

        if let playlistID = playlistID,
           let playlist = playlistManager.playlists.first(where: { $0.id == playlistID }) {
            playlistManager.currentPlaylist = playlist
            playlistManager.currentQueueSource = .playlist
        } else {
            playlistManager.currentQueueSource = .library
        }
    }

    // MARK: - Sorting Helpers

    /// Sorts off the main thread: comparing titles of a few thousand tracks
    /// takes ~50 ms. Every write to `sortedTracks` bumps `sortGeneration`, so a
    /// slower, older sort never replaces a newer list.
    private func performBackgroundSort(with newSortOrder: [KeyPathComparator<Track>]) {
        sortGeneration &+= 1
        if isCustomSort {
            sortedTracks = tracks
            return
        }

        let generation = sortGeneration
        let initialTracks = tracks

        Task.detached(priority: .userInitiated) {
            let sorted = initialTracks.sorted(using: newSortOrder)
            await MainActor.run {
                guard generation == self.sortGeneration else { return }
                self.sortedTracks = sorted
            }
        }
    }

    private func saveSortOrderToUserDefaults(_ sortOrder: [KeyPathComparator<Track>], key: String = "trackTableSortOrder") {
        let field = TrackSortField.detect(from: sortOrder)
        let ascending = TrackSortField.isAscending(from: sortOrder)
        let storage: [String: Any] = ["key": field.storageKey, "ascending": ascending]
        UserDefaults.standard.set(storage, forKey: key)
    }

    // MARK: - Notification Handlers

    private func handlePlayEntityNotification(_ notification: Notification) {
        guard !sortedTracks.isEmpty,
              let notificationEntityId = notification.userInfo?["entityId"] as? String,
              entityID?.uuidString == notificationEntityId else { return }

        let shuffle = notification.userInfo?["shuffle"] as? Bool ?? false
        playlistManager.isShuffleEnabled = shuffle

        var tracksForPlayback = sortedTracks
        if shuffle {
            tracksForPlayback.shuffle()
        }

        if let firstTrack = tracksForPlayback.first {
            playlistManager.playTrack(firstTrack, fromTracks: tracksForPlayback)
            playlistManager.currentQueueSource = .library
        }
    }

    private func handlePlayPlaylistNotification(_ notification: Notification) {
        guard let notificationPlaylistID = notification.userInfo?["playlistID"] as? UUID,
              notificationPlaylistID == playlistID,
              !sortedTracks.isEmpty,
              let playlist = playlistManager.playlists.first(where: { $0.id == playlistID }) else { return }

        let shuffle = notification.userInfo?["shuffle"] as? Bool ?? false
        playlistManager.isShuffleEnabled = shuffle

        var tracksForPlayback = sortedTracks
        if shuffle {
            tracksForPlayback.shuffle()
        }

        if let firstTrack = tracksForPlayback.first {
            playlistManager.playTrack(firstTrack, fromTracks: tracksForPlayback)
            playlistManager.currentPlaylist = playlist
            playlistManager.currentQueueSource = .playlist
        }
    }

    private func handleSortChangedNotification(_ notification: Notification) {
        // Handle custom sort flag from dropdown
        if let customSort = notification.userInfo?["isCustomSort"] as? Bool {
            isCustomSort = customSort
            if customSort {
                sortGeneration &+= 1
                sortedTracks = tracks
                return
            }
        }

        if let newSortOrder = notification.userInfo?["sortOrder"] as? [KeyPathComparator<Track>] {
            sortOrder = newSortOrder

            if let userDefaultsKey = notification.userInfo?["userDefaultsKey"] as? String {
                saveSortOrderToUserDefaults(newSortOrder, key: userDefaultsKey)
            } else {
                saveSortOrderToUserDefaults(newSortOrder)
            }
        }
    }

    private func handleRowSizeChangedNotification(_ notification: Notification) {
        if let newRowSize = notification.userInfo?["rowSize"] as? TableRowSize {
            tableRowSize = newRowSize
        }
    }

    private func handleTrackFavoriteStatusChanged(_ notification: Notification) {
        guard let updatedTrack = notification.userInfo?["track"] as? Track,
              let trackId = updatedTrack.trackId else { return }

        trackFavorites[trackId] = updatedTrack.isFavorite

        guard let index = sortedTracks.firstIndex(where: { $0.trackId == trackId }) else { return }

        let sortField = TrackSortField.detect(from: sortOrder)
        let needsResort = sortField == .favorite || sortField == .dateFavorited

        if needsResort {
            // Create new array to ensure SwiftUI Table updates as
            // in-place mutation + sort doesn't trigger proper view refresh on macOS 14/15
            var updatedTracks = sortedTracks
            updatedTracks[index].isFavorite = updatedTrack.isFavorite
            updatedTracks[index].dateFavorited = updatedTrack.dateFavorited
            sortGeneration &+= 1
            sortedTracks = updatedTracks.sorted(using: sortOrder)
        } else {
            sortedTracks[index].isFavorite = updatedTrack.isFavorite
            sortedTracks[index].dateFavorited = updatedTrack.dateFavorited
        }
    }
}

// MARK: - Track Extension for Sorting

extension Track {
    var sortableTrackNumber: Int {
        trackNumber ?? Int.max
    }

    var sortableDiscNumber: Int {
        discNumber ?? Int.max
    }

    var sortableDateAdded: Date {
        dateAdded ?? Date.distantPast
    }

    var sortableDateFavorited: Date {
        dateFavorited ?? Date.distantPast
    }

    var sortableIsFavorite: Int {
        isFavorite ? 0 : 1
    }
}
