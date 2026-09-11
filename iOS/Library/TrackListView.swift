//
// TrackListView (iOS)
//
// Alphabet-indexed track list for a category item (artist, album, genre, year)
// or the whole library ("Songs"). The skeleton lives in TrackListScreen;
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
            load: { [libraryManager, filterItem] in
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
            },
            sectioner: { IndexedListSectionFactory.sections(
                from: $0,
                key: { IndexedListSectionFactory.sectionKey(for: $0.title) }
            ) },
            isIndexed: true,
            showsHeader: false,
            header: { _ in EmptyView() },
            row: { track, context in
                TrackRow(
                    track: track,
                    onPlay: { play(track, in: context) },
                    playlistManager: playlistManager,
                    libraryManager: libraryManager,
                    playbackManager: playbackManager
                )
                .equatable()
            }
        )
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.large)
    }

    private var navigationTitle: String {
        guard let filterItem else { return String(localized: "All Music") }
        if filterItem.isAllItem {
            return String(localized: "All Music")
        }
        return filterItem.filterType.localizedDisplay(filterItem.name)
    }

    private func play(_ track: Track, in context: [Track]) {
        playlistManager.play(track, source: .library(context: context))
    }

}
