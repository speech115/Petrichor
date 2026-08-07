//
// FolderDetailView (iOS)
//
// A folder inside the tree: its subfolders on top (NavigationLinks deeper
// into the stack), its tracks below, using the shared TrackRow. The Play
// action in the navigation bar starts the whole folder contents, and tapping
// a track queues the same folder list from that track.
//

import SwiftUI

struct FolderDetailView: View {
    @EnvironmentObject private var libraryManager: LibraryManager
    @EnvironmentObject private var playbackManager: PlaybackManager
    @EnvironmentObject private var playlistManager: PlaylistManager

    @ObservedObject var node: FolderNode

    var body: some View {
        TrackListScreen(
            identity: AnyHashable(node.id),
            load: { node.getImmediateTracks(using: libraryManager) },
            sectioner: { [IndexedSection(key: String(localized: "Tracks"), items: $0)] },
            headerTitle: String(localized: "Folders"),
            showsHeader: !node.children.isEmpty,
            showEmptyState: node.children.isEmpty,
            header: { _ in
                ForEach(node.children) { child in
                    NavigationLink(value: child) {
                        FolderRowView(node: child)
                    }
                }
            },
            row: { track, context in
                TrackRow(
                    track: track,
                    isCurrent: playlistManager.isCurrent(track),
                    isPlaying: playlistManager.isCurrent(track) && playbackManager.isPlaying,
                    onPlay: { play(track, in: context) }
                )
            }
        )
        .navigationTitle(node.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    playAll()
                } label: {
                    Image(systemName: Icons.playFill)
                }
                .disabled(node.getImmediateTracks(using: libraryManager).isEmpty)
                .accessibilityLabel(String(localized: "Play All"))
            }
        }
    }

    private func play(_ track: Track, in context: [Track]) {
        playlistManager.play(track, source: .folder(context: context))
    }

    private func playAll() {
        let tracks = node.getImmediateTracks(using: libraryManager)
        guard let first = tracks.first else { return }
        playlistManager.play(first, source: .folder(context: tracks))
    }
}
