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

    @State private var tracks: [Track] = []
    @State private var loadTask: Task<Void, Never>?

    var body: some View {
        Group {
            if node.children.isEmpty, tracks.isEmpty {
                ContentUnavailableView(
                    String(localized: "No Tracks"),
                    systemImage: Icons.musicNote
                )
            } else {
                folderList
            }
        }
        .navigationTitle(node.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    playAll()
                } label: {
                    Image(systemName: Icons.playFill)
                }
                .disabled(tracks.isEmpty)
                .accessibilityLabel(String(localized: "Play All"))
            }
        }
        .task(id: node.id) {
            await loadTracks()
        }
        .onDisappear {
            loadTask?.cancel()
        }
    }

    private var folderList: some View {
        List {
            if !node.children.isEmpty {
                Section(String(localized: "Folders")) {
                    ForEach(node.children) { child in
                        NavigationLink(value: child) {
                            FolderRowView(node: child)
                        }
                    }
                }
            }
            if !tracks.isEmpty {
                Section(String(localized: "Tracks")) {
                    ForEach(tracks) { track in
                        TrackRow(
                            track: track,
                            isCurrent: isCurrent(track),
                            isPlaying: isCurrent(track) && playbackManager.isPlaying,
                            onPlay: { play(track) }
                        )
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func isCurrent(_ track: Track) -> Bool {
        guard let currentTrack = playbackManager.currentTrack else { return false }
        if let currentId = currentTrack.trackId, let trackId = track.trackId {
            return currentId == trackId
        }
        return currentTrack.url.path == track.url.path
    }

    private func play(_ track: Track) {
        playlistManager.playTrackFromFolder(track, folderTracks: tracks)
    }

    private func playAll() {
        guard let first = tracks.first else { return }
        play(first)
    }

    private func loadTracks() async {
        loadTask?.cancel()
        loadTask = Task {
            let node = node
            let libraryManager = libraryManager

            let loaded = await Task.detached(priority: .userInitiated) {
                node.getImmediateTracks(using: libraryManager)
            }.value

            guard !Task.isCancelled else { return }
            await MainActor.run {
                tracks = loaded
            }
        }
    }
}
