import SwiftUI

/// The Discover rotation: library tracks not played yet, as a track table.
struct DiscoverView: View {
    @EnvironmentObject var libraryManager: LibraryManager
    @EnvironmentObject var playlistManager: PlaylistManager

    @AppStorage("trackTableRowSize")
    private var trackTableRowSize: TableRowSize = .expanded

    @State private var selectedTrackID: String?
    @State private var trackTableSortOrder = [KeyPathComparator(\Track.title)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TrackListHeader(
                title: String(localized: "Discover"),
                sortOrder: $trackTableSortOrder,
                tableRowSize: $trackTableRowSize
            ) {
                Button(action: {
                    Task { await libraryManager.refreshDiscoverTracks() }
                }, label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                })
                .buttonStyle(.borderless)
                .hoverEffect(scale: 1.1)
                .help("Refresh Discover tracks")
            }

            Divider()

            if libraryManager.discoverTracks.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: Icons.sparkles)
                        .font(.system(size: 48))
                        .foregroundColor(.gray)

                    Text("No undiscovered tracks")
                        .font(.headline)

                    Text("You've played all tracks in your library!")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                TrackView(
                    tracks: libraryManager.discoverTracks,
                    selectedTrackID: $selectedTrackID,
                    playlistID: nil,
                    entityID: nil,
                    sortOrder: $trackTableSortOrder,
                    onPlayTrack: { track in
                        playlistManager.playTrack(track, fromTracks: libraryManager.discoverTracks)
                        playlistManager.currentQueueSource = .library
                    },
                    contextMenuItems: { track, _ in
                        TrackContextMenu.createMenuItems(
                            for: track,
                            playlistManager: playlistManager,
                            currentContext: .library
                        )
                    }
                )
                .id(libraryManager.discoverLastUpdated)
            }
        }
        .onAppear {
            if libraryManager.discoverTracks.isEmpty {
                Task { await libraryManager.loadDiscoverTracks() }
            }
        }
    }
}
