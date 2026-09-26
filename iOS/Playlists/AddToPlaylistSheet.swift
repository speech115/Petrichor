import SwiftUI

struct AddToPlaylistSheet: View {
    let track: Track
    let playlistManager: PlaylistManager
    @ObservedObject private var catalog: PlaylistCatalogObservation
    @Environment(\.dismiss)
    private var dismiss
    @State private var query = ""
    @State private var saving = false
    @State private var failed = false
    @State private var showingCreate = false
    @State private var name = ""

    init(track: Track, playlistManager: PlaylistManager) {
        self.track = track
        self.playlistManager = playlistManager
        catalog = playlistManager.catalogObservation
    }

    private var playlists: [Playlist] {
        catalog.playlists.filter {
            $0.type == .regular && $0.isContentEditable
                && (query.isEmpty || PlaylistDisplay.name(for: $0).localizedCaseInsensitiveContains(query))
        }
        .sorted { PlaylistDisplay.name(for: $0).localizedStandardCompare(PlaylistDisplay.name(for: $1)) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List {
                Button {
                    showingCreate = true
                } label: {
                    Label("New Playlist", systemImage: "plus")
                }
                .disabled(saving)
                ForEach(playlists) { playlist in
                    let contains = playlistManager.playlistContainsTrack(track, in: playlist)
                    Button {
                        add(to: playlist)
                    } label: {
                        HStack {
                            Text(PlaylistDisplay.name(for: playlist))
                                .foregroundStyle(.primary)
                            Spacer()
                            if contains {
                                Label("Added", systemImage: "checkmark")
                                    .font(.subheadline)
                            }
                        }
                        .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(contains || saving)
                }
                if playlists.isEmpty {
                    Text(query.isEmpty ? String(localized: "Create a playlist to add this song.") : String(localized: "No Playlists Found"))
                        .foregroundStyle(.secondary)
                }
            }
            .searchable(text: $query, prompt: Text("Search Playlists"))
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .disabled(saving)
                }
            }
            .alert("New Playlist", isPresented: $showingCreate) {
                TextField("Playlist Name", text: $name)
                Button("Cancel", role: .cancel) { name = "" }
                Button("Create") {
                    playlistManager.createRegularPlaylist(name: name.trimmingCharacters(in: .whitespacesAndNewlines), tracks: [track])
                    dismiss()
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .alert("Unable to Add Songs", isPresented: $failed) {
                Button("OK", role: .cancel) {}
            } message: { Text("The playlist could not be saved. Try again.") }
        }
        .interactiveDismissDisabled(saving)
    }

    private func add(to playlist: Playlist) {
        saving = true
        Task {
            if await playlistManager.addTracksToPlaylist(tracks: [track], playlistID: playlist.id) {
                UIAccessibility.post(notification: .announcement, argument: String(localized: "Added to \(PlaylistDisplay.name(for: playlist))"))
            } else {
                failed = true
            }
            saving = false
        }
    }
}
