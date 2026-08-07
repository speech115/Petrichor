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
                isCurrent: playlistManager.isCurrent(track),
                isPlaying: playlistManager.isCurrent(track) && playbackManager.isPlaying,
                onPlay: { play(track) }
            )
        }
        .navigationTitle(String(localized: "Discover"))
        .navigationBarTitleDisplayMode(.large)
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

    private func play(_ track: Track) {
        playlistManager.play(track, source: .library(context: libraryManager.discoverTracks))
    }
}
