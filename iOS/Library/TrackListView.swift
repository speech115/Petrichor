//
// TrackListView (iOS)
//
// Alphabet-indexed track list for a category item (artist, album, genre, year)
// or the whole library ("All Tracks"). Category tracks are loaded from the
// database with artwork populated; the full library reuses `LibraryManager.tracks`
// and covers are fetched per row, so 2829 tracks never pull every cover at once.
//

import SwiftUI

struct TrackListView: View {
    @EnvironmentObject private var libraryManager: LibraryManager
    @EnvironmentObject private var playbackManager: PlaybackManager
    @EnvironmentObject private var playlistManager: PlaylistManager

    let filterItem: LibraryFilterItem?

    @State private var tracks: [Track] = []
    @State private var sections: [IndexedSection<Track>] = []
    @State private var loadTask: Task<Void, Never>?

    var body: some View {
        IndexedList(sections: sections) { track in
            TrackRow(
                track: track,
                isCurrent: isCurrent(track),
                isPlaying: isCurrent(track) && playbackManager.isPlaying,
                onPlay: { play(track) }
            )
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.large)
        .task(id: filterItem) {
            await load()
        }
        .onChange(of: libraryManager.tracks) { _, _ in
            scheduleLoad()
        }
        .onDisappear {
            loadTask?.cancel()
        }
        .overlay {
            if sections.isEmpty, libraryManager.shouldShowMainUI {
                ContentUnavailableView(
                    String(localized: "No Tracks"),
                    systemImage: Icons.musicNote
                )
            }
        }
    }

    private var navigationTitle: String {
        guard let filterItem else { return String(localized: "All Tracks") }
        if filterItem.isAllItem {
            return String(localized: "All Tracks")
        }
        return filterItem.filterType.localizedDisplay(filterItem.name)
    }

    private func isCurrent(_ track: Track) -> Bool {
        guard let currentTrack = playbackManager.currentTrack else { return false }
        if let currentId = currentTrack.trackId, let trackId = track.trackId {
            return currentId == trackId
        }
        return currentTrack.url.path == track.url.path
    }

    private func play(_ track: Track) {
        playlistManager.playTrack(track, fromTracks: tracks)
        playlistManager.currentQueueSource = .library
    }

    private func scheduleLoad() {
        loadTask?.cancel()
        loadTask = Task {
            await load()
        }
    }

    private func load() async {
        if let filterItem, !filterItem.isAllItem {
            await loadCategoryTracks(filterItem)
        } else {
            await loadAllTracksFromDatabase()
        }
    }

    private func loadCategoryTracks(_ item: LibraryFilterItem) async {
        let filterType = item.filterType
        let value = item.name
        let albumId = item.albumId
        let libraryManager = libraryManager
        let databaseManager = libraryManager.databaseManager

        let loaded = await Task.detached(priority: .userInitiated) {
            var tracks = libraryManager.getTracksBy(
                filterType: filterType,
                value: value,
                albumId: albumId,
                populateArtwork: false
            )
            // List rows read the album thumbnail, not the display-size BLOB.
            databaseManager.populateAlbumArtworkThumbnailsForTracks(&tracks)
            return tracks.sorted {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        }.value

        guard !Task.isCancelled else { return }
        rebuild(from: loaded)
    }

    private func loadAllTracksFromDatabase() async {
        let databaseManager = libraryManager.databaseManager

        let loaded = await Task.detached(priority: .userInitiated) {
            databaseManager.getAllTracksWithThumbnails()
        }.value

        guard !Task.isCancelled else { return }
        rebuild(from: loaded)
    }

    private func rebuild(from tracks: [Track]) {
        self.tracks = tracks
        sections = IndexedListSectionFactory.sections(
            from: tracks,
            key: { IndexedListSectionFactory.sectionKey(for: $0.title) }
        )
    }
}
