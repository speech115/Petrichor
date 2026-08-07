//
// PlaylistDetailScreen (iOS)
//
// Detail screen for a playlist: the tracks in their stored order, exactly as
// `PlaylistManager` loaded them — no re-sorting in the view. Tracks whose
// file has vanished from disk stay in place, dimmed as missing, so they
// never shift their neighbours; a returned file revives the row on the next
// visit. Regular playlists load lazily on open; smart playlists re-evaluate
// through the manager and are refreshed by it on library changes.
//
// Rows reuse the shared TrackRow; gestures land on it in ticket 05.
//

import SwiftUI

struct PlaylistDetailScreen: View {
    let playlistID: UUID

    @EnvironmentObject private var playlistManager: PlaylistManager
    @EnvironmentObject private var playbackManager: PlaybackManager

    @State private var missingPaths: Set<String> = []
    @State private var showingRenameAlert = false
    @State private var renameText = ""
    @State private var showingDeleteConfirmation = false

    private var playlist: Playlist? {
        playlistManager.playlists.first { $0.id == playlistID }
    }

    var body: some View {
        Group {
            if let playlist {
                trackList(playlist)
            } else {
                ContentUnavailableView(
                    String(localized: "Playlist Not Found"),
                    systemImage: Icons.musicNoteList
                )
            }
        }
        .navigationTitle(playlist.map { DefaultPlaylists.displayName(for: $0) } ?? "")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            if let playlist, playlist.isUserEditable {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            beginRename(playlist)
                        } label: {
                            Label(String(localized: "Rename"), systemImage: Icons.edit)
                        }
                        Button(role: .destructive) {
                            showingDeleteConfirmation = true
                        } label: {
                            Label(String(localized: "Delete"), systemImage: Icons.trash)
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel(String(localized: "Playlist menu"))
                }
            }
        }
        .alert(String(localized: "Rename Playlist"), isPresented: $showingRenameAlert) {
            TextField(String(localized: "Playlist Name"), text: $renameText)
            Button(String(localized: "Cancel"), role: .cancel) {}
            Button(String(localized: "Rename")) {
                commitRename()
            }
            .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert(String(localized: "Delete Playlist"), isPresented: $showingDeleteConfirmation) {
            Button(String(localized: "Cancel"), role: .cancel) {}
            Button(String(localized: "Delete"), role: .destructive) {
                if let playlist {
                    playlistManager.deletePlaylist(playlist)
                }
            }
        } message: {
            if let playlist {
                Text(String(
                    localized: "Are you sure you want to delete \"\(DefaultPlaylists.displayName(for: playlist))\"?"
                ))
            }
        }
        .task(id: tracksTaskID) {
            await loadTracksIfNeeded()
            await refreshMissingFiles()
        }
    }

    // MARK: - Rename

    private func beginRename(_ playlist: Playlist) {
        renameText = playlist.name
        showingRenameAlert = true
    }

    private func commitRename() {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let playlist, !trimmed.isEmpty else { return }
        playlistManager.renamePlaylist(playlist, newName: trimmed)
    }

    // MARK: - Track List

    private func trackList(_ playlist: Playlist) -> some View {
        List {
            Section {
                header(playlist)
                    .frame(maxWidth: .infinity)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
            }

            if !playlist.tracks.isEmpty {
                ForEach(playlist.tracks) { track in
                    if missingPaths.contains(track.url.path) {
                        MissingTrackRow(track: track)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    } else {
                        TrackRow(
                            track: track,
                            isCurrent: isCurrent(track),
                            isPlaying: isCurrent(track) && playbackManager.isPlaying,
                            onPlay: { play(track, in: playlist) }
                        )
                    }
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if playlist.tracks.isEmpty {
                ContentUnavailableView(
                    DefaultPlaylists.noSongsText(for: playlist),
                    systemImage: Icons.musicNoteList,
                    description: Text(DefaultPlaylists.emptyStateText(for: playlist))
                )
            }
        }
    }

    // MARK: - Header

    private func header(_ playlist: Playlist) -> some View {
        VStack(spacing: 12) {
            ArtworkMosaic(covers: playlist.tracks.compactMap { $0.albumArtworkThumbnail ?? $0.artworkData })
                .frame(width: 240, height: 240)
                .padding(.top, 16)

            Text(String(localized: "\(playlist.trackCount) songs"))
                .font(.subheadline)
                .foregroundColor(.secondary)

            PlayShuffleRow(
                onPlay: { playAll(playlist) },
                onShuffle: { shuffleAll(playlist) },
                playDisabled: playlist.tracks.isEmpty
            )
            .padding(.top, 4)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    // MARK: - Loading

    private var tracksTaskID: String {
        guard let playlist else { return "\(playlistID)-nil" }
        return "\(playlistID)-\(playlist.tracks.count)-\(playlist.dateModified.timeIntervalSince1970)"
    }

    private func loadTracksIfNeeded() async {
        guard let playlist, playlist.tracks.isEmpty else { return }

        if playlist.type == .smart {
            await playlistManager.loadSmartPlaylistTracks(playlist)
        } else {
            playlistManager.loadPlaylistTracks(for: playlist.id)
        }

        // Playlist rows are list rows: swap the display-size artwork pass for
        // the album thumbnail pass once the shared loader has finished.
        if let index = playlistManager.playlists.firstIndex(where: { $0.id == playlistID }),
           let databaseManager = playlistManager.libraryManager?.databaseManager {
            var tracks = playlistManager.playlists[index].tracks
            databaseManager.populateAlbumArtworkThumbnailsForTracks(&tracks)
            playlistManager.playlists[index].tracks = tracks
        }
    }

    /// Computes which track files are missing from disk. One cheap pass over
    /// the list on open and on every track-set change, so a returned file
    /// revives its row without any reordering.
    private func refreshMissingFiles() async {
        guard let playlist else {
            missingPaths = []
            return
        }

        let paths = playlist.tracks.map(\.url.path)

        let missing = await Task.detached(priority: .utility) {
            Set(paths.filter { !FileManager.default.fileExists(atPath: $0) })
        }.value

        guard !Task.isCancelled else { return }
        missingPaths = missing
    }

    // MARK: - Playback

    private func isCurrent(_ track: Track) -> Bool {
        guard let currentTrack = playbackManager.currentTrack else { return false }
        if let currentId = currentTrack.trackId, let trackId = track.trackId {
            return currentId == trackId
        }
        return currentTrack.url.path == track.url.path
    }

    private func play(_ track: Track, in playlist: Playlist) {
        guard let index = playlist.tracks.firstIndex(of: track) else { return }
        playlistManager.playTrackFromPlaylist(playlist, at: index)
    }

    private func playAll(_ playlist: Playlist) {
        guard let first = playlist.tracks.first else { return }
        playlistManager.playTrackFromPlaylist(playlist, at: playlist.tracks.firstIndex(of: first) ?? 0)
    }

    private func shuffleAll(_ playlist: Playlist) {
        let shuffled = playlist.tracks.shuffled()
        guard let first = shuffled.first else { return }
        playlistManager.playTrack(first, fromTracks: shuffled)
        playlistManager.currentQueueSource = .playlist
    }
}

// MARK: - Missing Track Row

/// A track whose audio file is gone from disk. Rendered in place of TrackRow,
/// dimmed and inert, so the playlist keeps its order and the row still names
/// the track. Returns to a normal TrackRow once the file is back.
private struct MissingTrackRow: View {
    let track: Track

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.12))
                Image(systemName: Icons.questionmarkCircle)
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.body)
                    .lineLimit(1)
                Text(String(localized: "File not found"))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .opacity(0.5)

            Spacer(minLength: 8)
        }
    }
}
