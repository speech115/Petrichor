import SwiftUI

struct AddSongsSheet: View {
    let playlistID: UUID
    let playlistManager: PlaylistManager
    @EnvironmentObject private var libraryManager: LibraryManager
    @Environment(\.dismiss)
    private var dismiss
    @State private var tracks: [Track] = []
    @State private var existingIDs: Set<String> = []
    @State private var selectedIDs: Set<String> = []
    @State private var query = ""
    @State private var saving = false
    @State private var failed = false

    private var results: [Track] {
        tracks.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.artist.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List(results) { track in
                let exists = existingIDs.contains(track.id)
                Button {
                    if !selectedIDs.insert(track.id).inserted { selectedIDs.remove(track.id) }
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading) {
                            Text(track.title).foregroundStyle(.primary)
                            Text(track.displayArtist).font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: exists || selectedIDs.contains(track.id) ? "checkmark.circle.fill" : "circle")
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(exists || saving)
                .accessibilityAddTraits(exists || selectedIDs.contains(track.id) ? .isSelected : [])
            }
            .searchable(text: $query, prompt: Text("Search Library"))
            .overlay {
                if results.isEmpty {
                    ContentUnavailableView(
                        "No Songs",
                        systemImage: Icons.musicNote,
                        description: Text("Add music to your library first, or try another search.")
                    )
                }
            }
            .navigationTitle("Add Songs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add (\(selectedIDs.count))") { save() }
                        .disabled(selectedIDs.isEmpty || saving)
                }
            }
            .alert("Unable to Add Songs", isPresented: $failed) {
                Button("OK", role: .cancel) {}
            } message: { Text("The playlist could not be saved. Try again.") }
            .task {
                await playlistManager.loadPlaylistTracks(for: playlistID)
                existingIDs = Set(playlistManager.playlists.first { $0.id == playlistID }?.tracks.map(\.id) ?? [])
                let library = libraryManager
                let loaded = await Task.detached(priority: .userInitiated) { library.getAllTracks() }.value
                guard !Task.isCancelled else { return }
                tracks = loaded
            }
        }
        .interactiveDismissDisabled(saving)
    }

    private func save() {
        saving = true
        Task {
            let success = await playlistManager.addTracksToPlaylist(
                tracks: tracks.filter { selectedIDs.contains($0.id) }, playlistID: playlistID
            )
            saving = false
            if success { dismiss() } else { failed = true }
        }
    }
}
