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
        .navigationBarTitleDisplayMode(.inline)
        .task(id: tracksTaskID) {
            await loadTracksIfNeeded()
            await refreshMissingFiles()
        }
    }

    // MARK: - Track List

    private func trackList(_ playlist: Playlist) -> some View {
        List {
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
