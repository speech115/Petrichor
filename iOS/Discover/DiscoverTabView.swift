//
// DiscoverTabView (iOS)
//
// The Discover tab: the same 50 unplayed tracks the Mac's Discover sidebar
// item shows, from the same `LibraryManager` rotation — no second selection
// rule lives here. It is presented as a playlist rather than a plain list:
// a mosaic of the rotation's own covers, Play and Shuffle, then the tracks in
// the order the rotation picked them.
//
// The refresh button carries the Mac's icon and calls the Mac's
// `refreshDiscoverTracks()`, which drops the saved rotation and draws a new
// one instead of waiting out the weekly interval.
//

import SwiftUI

struct DiscoverTabView: View {
    @EnvironmentObject private var libraryManager: LibraryManager
    @EnvironmentObject private var playbackManager: PlaybackManager
    @EnvironmentObject private var playlistManager: PlaylistManager

    @Binding var showingSettings: Bool

    var body: some View {
        NavigationStack {
            TrackListScreen(
                identity: AnyHashable(libraryManager.discoverLastUpdated),
                load: { await loadTracks() },
                sectioner: { [IndexedSection(key: "", items: $0)] },
                usesPlainStyle: true,
                emptyTitle: String(localized: "No Tracks"),
                emptyIcon: Icons.sparkles,
                header: { tracks in
                    header(tracks)
                        .frame(maxWidth: .infinity)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                },
                row: { track, tracks in
                    TrackRow(
                        track: track,
                        onPlay: { play(track, in: tracks) },
                        playlistManager: playlistManager,
                        libraryManager: libraryManager,
                        playbackManager: playbackManager
                    )
                    .equatable()
                }
            )
            .rootTitle(String(localized: "Discover"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        libraryManager.refreshDiscoverTracks(populateArtwork: false)
                    } label: {
                        Image(systemName: Icons.arrowClockwise)
                    }
                    .accessibilityLabel(String(localized: "Refresh"))
                }
                SettingsToolbarItem(showingSettings: $showingSettings)
            }
        }
    }

    // MARK: - Header

    private func header(_ tracks: [Track]) -> some View {
        DetailHeader(
            onPlay: { playAll(tracks) },
            onShuffle: { shuffleAll(tracks) },
            playDisabled: tracks.isEmpty,
            subtitle: TrackCountText.songs(tracks.count),
            artwork: {
                ArtworkMosaic(covers: Array(tracks.lazy.compactMap { $0.displayArtwork }.prefix(4)))
                    .frame(width: 240, height: 240)
            }
        )
    }

    // MARK: - Loading

    /// Thumbnails, not display-size artwork: this is a list of 44 pt rows plus
    /// a four-tile mosaic, and the full-size column is empty for albums whose
    /// artwork only ever got thumbnailed — asking for it leaves the whole
    /// screen grey.
    private func loadTracks() async -> [Track] {
        if libraryManager.discoverTracks.isEmpty {
            libraryManager.loadDiscoverTracks(populateArtwork: false)
        }
        return libraryManager.discoverTracks
    }

    // MARK: - Playback

    private func play(_ track: Track, in tracks: [Track]) {
        playlistManager.play(track, source: .library(context: tracks))
    }

    private func playAll(_ tracks: [Track]) {
        playlistManager.playLibrary(tracks)
    }

    private func shuffleAll(_ tracks: [Track]) {
        playlistManager.shuffleLibrary(tracks)
    }
}
