//
// TrackListView (iOS)
//
// Alphabet-indexed track list for a category item (artist, album, genre, year)
// or the whole library ("All Tracks"). The skeleton lives in TrackListScreen;
// this screen supplies the loader, the index-letter sectioner and the rows.
//

import SwiftUI

struct TrackListView: View {
    @EnvironmentObject private var libraryManager: LibraryManager
    @EnvironmentObject private var playbackManager: PlaybackManager
    @EnvironmentObject private var playlistManager: PlaylistManager

    let filterItem: LibraryFilterItem?

    var body: some View {
        TrackListScreen(
            identity: AnyHashable(filterItem.map { "\($0.id)" } ?? "all-tracks"),
            load: load,
            sectioner: { IndexedListSectionFactory.sections(
                from: $0,
                key: { IndexedListSectionFactory.sectionKey(for: $0.title) }
            ) },
            isIndexed: true,
            header: { _ in EmptyView() },
            row: { track, context in
                TrackRow(
                    track: track,
                    isCurrent: playlistManager.isCurrent(track),
                    isPlaying: playlistManager.isCurrent(track) && playbackManager.isPlaying,
                    onPlay: { play(track, in: context) }
                )
            }
        )
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.large)
    }

    private var navigationTitle: String {
        guard let filterItem else { return String(localized: "All Tracks") }
        if filterItem.isAllItem {
            return String(localized: "All Tracks")
        }
        return filterItem.filterType.localizedDisplay(filterItem.name)
    }

    private func play(_ track: Track, in context: [Track]) {
        playlistManager.play(track, source: .library(context: context))
    }

    private func load() async -> [Track] {
        let libraryManager = libraryManager
        let filterItem = filterItem

        if let filterItem, !filterItem.isAllItem {
            return libraryManager.getTracksBy(
                filterType: filterItem.filterType,
                value: filterItem.name,
                albumId: filterItem.albumId
            )
            .sorted {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        }
        return libraryManager.getAllTracks()
    }
}
