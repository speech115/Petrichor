//
// DiscoverView (iOS)
//
// The Discover screen: 50 unplayed tracks (playCount == 0, no duplicates),
// refreshed weekly by the shared `LibraryManager.loadDiscoverTracks()` logic.
// The list is lazy with an alphabet index like the other track lists, rows
// reuse TrackRow, and a tap starts playback exactly like TrackListView.
//

import SwiftUI

struct DiscoverView: View {
    @EnvironmentObject private var libraryManager: LibraryManager
    @EnvironmentObject private var playbackManager: PlaybackManager
    @EnvironmentObject private var playlistManager: PlaylistManager

    var body: some View {
        IndexedList(sections: sections) { track in
            TrackRow(
                track: track,
                isCurrent: isCurrent(track),
                isPlaying: isCurrent(track) && playbackManager.isPlaying,
                onPlay: { play(track) }
            )
        }
        .navigationTitle(String(localized: "Discover"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if libraryManager.discoverTracks.isEmpty {
                libraryManager.loadDiscoverTracks()
            }
        }
        .overlay {
            if libraryManager.discoverTracks.isEmpty, libraryManager.shouldShowMainUI {
                ContentUnavailableView(
                    String(localized: "No Tracks"),
                    systemImage: Icons.musicNote
                )
            }
        }
    }

    private var sections: [IndexedSection<Track>] {
        IndexedListSectionFactory.sections(
            from: sortedTracks,
            key: { IndexedListSectionFactory.sectionKey(for: $0.title) }
        )
    }

    private var sortedTracks: [Track] {
        libraryManager.discoverTracks.sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    private func isCurrent(_ track: Track) -> Bool {
        guard let currentTrack = playbackManager.currentTrack else { return false }
        if let currentId = currentTrack.trackId, let trackId = track.trackId {
            return currentId == trackId
        }
        return currentTrack.url.path == track.url.path
    }

    private func play(_ track: Track) {
        playlistManager.playTrack(track, fromTracks: libraryManager.discoverTracks)
        playlistManager.currentQueueSource = .library
    }
}
