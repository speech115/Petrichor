//
// PlaylistsTabView (iOS)
//
// The Playlists tab: the playlist list with track counts, smart playlists
// included. Rows swipe to rename or delete (user-editable playlists only),
// and M3U import is exposed from the toolbar. A row pushes to
// PlaylistDetailScreen, which renders the tracks in their stored order.
//
// The list renders `playlistManager.playlists` exactly as loaded — the
// manager owns the order (smart first, then regular by sort order), the view
// never re-sorts.
//

import SwiftUI
import UIKit

struct PlaylistsTabView: View {
    @EnvironmentObject private var playlistManager: PlaylistManager

    @Binding var showingPlaylistImporter: Bool

    @State private var playlistToRename: Playlist?
    @State private var renameText = ""
    @State private var playlistToDelete: Playlist?

    var body: some View {
        NavigationStack {
            playlistList
                .navigationTitle(String(localized: "Playlists"))
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for: UUID.self) { playlistID in
                    PlaylistDetailScreen(playlistID: playlistID)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            playlistManager.showCreatePlaylistModal()
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel(String(localized: "New Playlist"))
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingPlaylistImporter = true
                        } label: {
                            Image(systemName: "square.and.arrow.down")
                        }
                        .accessibilityLabel(String(localized: "Import Playlists"))
                    }
                }
                .sheet(isPresented: $playlistManager.showingCreatePlaylistModal) {
                    CreatePlaylistSheet(
                        isPresented: $playlistManager.showingCreatePlaylistModal,
                        playlistName: $playlistManager.newPlaylistName,
                        tracksToAdd: playlistManager.tracksToAddToNewPlaylist
                    ) {
                        playlistManager.createPlaylistFromModal()
                    }
                    .environmentObject(playlistManager)
                }
                .alert(
                    String(localized: "Rename Playlist"),
                    isPresented: renameAlertBinding
                ) {
                    TextField(String(localized: "Playlist Name"), text: $renameText)
                    Button(String(localized: "Cancel"), role: .cancel) {
                        playlistToRename = nil
                    }
                    Button(String(localized: "Rename")) {
                        commitRename()
                    }
                    .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .alert(
                    String(localized: "Delete Playlist"),
                    isPresented: deleteAlertBinding
                ) {
                    Button(String(localized: "Cancel"), role: .cancel) {
                        playlistToDelete = nil
                    }
                    Button(String(localized: "Delete"), role: .destructive) {
                        if let playlist = playlistToDelete {
                            playlistManager.deletePlaylist(playlist)
                        }
                        playlistToDelete = nil
                    }
                } message: {
                    if let playlist = playlistToDelete {
                        Text(String(
                            localized: "Are you sure you want to delete \"\(DefaultPlaylists.displayName(for: playlist))\"?"
                        ))
                    }
                }
                .onAppear {
                    if playlistManager.playlists.isEmpty {
                        playlistManager.loadPlaylists()
                    }
                }
        }
    }

    // MARK: - Playlist List

    private var playlistList: some View {
        List(playlistManager.playlists) { playlist in
            NavigationLink(value: playlist.id) {
                HStack(spacing: 12) {
                    SymbolImage(playlistIcon(for: playlist))
                        .font(.system(size: 17))
                        .foregroundColor(.accentColor)
                        .frame(width: 28)

                    Text(DefaultPlaylists.displayName(for: playlist))
                        .lineLimit(1)

                    Spacer()

                    Text("\(playlist.trackCount)")
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
            }
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                if playlist.isUserEditable {
                    Button {
                        beginRename(playlist)
                    } label: {
                        Label(String(localized: "Rename"), systemImage: Icons.edit)
                    }
                    .tint(.blue)
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if playlist.isUserEditable {
                    Button(role: .destructive) {
                        playlistToDelete = playlist
                    } label: {
                        Label(String(localized: "Delete"), systemImage: Icons.trash)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if playlistManager.playlists.isEmpty {
                ContentUnavailableView(
                    String(localized: "No Playlists"),
                    systemImage: Icons.musicNoteList,
                    description: Text(String(localized: "Create a playlist or import one from an M3U file"))
                )
            }
        }
    }

    private func playlistIcon(for playlist: Playlist) -> String {
        if playlist.type == .smart {
            return Icons.defaultPlaylistIcon(for: playlist)
        }
        return Icons.musicNoteList
    }

    // MARK: - Rename

    private var renameAlertBinding: Binding<Bool> {
        Binding(
            get: { playlistToRename != nil },
            set: { isPresented in
                if !isPresented {
                    playlistToRename = nil
                }
            }
        )
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { playlistToDelete != nil },
            set: { isPresented in
                if !isPresented {
                    playlistToDelete = nil
                }
            }
        )
    }

    private func beginRename(_ playlist: Playlist) {
        playlistToRename = playlist
        renameText = playlist.name
    }

    private func commitRename() {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let playlist = playlistToRename, !trimmed.isEmpty else {
            playlistToRename = nil
            return
        }
        playlistManager.renamePlaylist(playlist, newName: trimmed)
        playlistToRename = nil
    }
}

// MARK: - Create Playlist Sheet (iOS)

struct CreatePlaylistSheet: View {
    @EnvironmentObject var playlistManager: PlaylistManager
    @Binding var isPresented: Bool
    @Binding var playlistName: String
    let tracksToAdd: [Track]
    let onCreate: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                TextField(String(localized: "Playlist Name"), text: $playlistName)
                    .onSubmit {
                        if !playlistName.isEmpty {
                            onCreate()
                        }
                    }

                if !tracksToAdd.isEmpty {
                    Section {
                        Text(String(localized: "Will add: \(tracksToAdd.count) tracks"))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle(String(localized: "New Playlist"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) {
                        playlistName = ""
                        isPresented = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Create")) {
                        onCreate()
                    }
                    .disabled(playlistName.isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
