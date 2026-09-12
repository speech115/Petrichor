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
    var recentlyAdded = false
    @State private var loadedTracks: [Track] = []

    var body: some View {
        TrackListScreen(
            identity: AnyHashable(recentlyAdded ? "recently-added" : filterItem.map { "\($0.id)" } ?? "all-tracks"),
            load: { [libraryManager, filterItem, recentlyAdded] in
                if recentlyAdded {
                    return libraryManager.getAllTracks().sorted {
                        let lhs = $0.dateAdded ?? .distantPast
                        let rhs = $1.dateAdded ?? .distantPast
                        return lhs == rhs ? $0.id < $1.id : lhs > rhs
                    }
                }
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
                return libraryManager.getSongsTracks()
            },
            sectioner: { tracks in
                if recentlyAdded { return [IndexedSection(key: "", items: tracks)] }
                return IndexedListSectionFactory.sections(
                    from: tracks,
                    key: { IndexedListSectionFactory.sectionKey(for: $0.title) }
                )
            },
            isIndexed: !recentlyAdded,
            usesPlainStyle: true,
            showsHeader: false,
            onRowsChange: { loadedTracks = $0 },
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
        .safeAreaInset(edge: .top, spacing: 0) {
            PlayShuffleRow(
                onPlay: { playlistManager.playLibrary(loadedTracks) },
                onShuffle: { playlistManager.shuffleLibrary(loadedTracks) },
                playDisabled: loadedTracks.isEmpty
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.large)
    }

    private var navigationTitle: String {
        if recentlyAdded { return String(localized: "Recently Added") }
        guard let filterItem else { return String(localized: "Songs") }
        if filterItem.isAllItem {
            return String(localized: "Songs")
        }
        return filterItem.filterType.localizedDisplay(filterItem.name)
    }

    private func play(_ track: Track, in context: [Track]) {
        playlistManager.play(track, source: .library(context: context))
    }

}
