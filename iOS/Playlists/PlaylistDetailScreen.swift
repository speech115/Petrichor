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
    let playlistManager: PlaylistManager
    let playbackManager: PlaybackManager
    @ObservedObject var playlistCatalog: PlaylistCatalogObservation

    @EnvironmentObject private var libraryManager: LibraryManager

    @AppStorage("useArtworkColors")
    private var useArtworkColors = true

    @State private var missingPaths: Set<String> = []
    @State private var showingRenameAlert = false
    @State private var renameText = ""
    @State private var showingDeleteConfirmation = false
    @State private var headerDominantColor: PlatformColor?

    private var playlist: Playlist? {
        playlistCatalog.playlists.first { $0.id == playlistID }
    }

    var body: some View {
        Group {
            if let playlist {
                TrackListScreen(
                    identity: AnyHashable(tracksTaskID(playlist)),
                    load: { await loadTracks(playlist) },
                    sectioner: { [IndexedSection(key: "", items: $0)] },
                    usesPlainStyle: true,
                    emptyTitle: DefaultPlaylists.noSongsText(for: playlist),
                    emptyIcon: Icons.musicNoteList,
                    header: { tracks in
                        header(playlist, tracks: tracks)
                            .frame(maxWidth: .infinity)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                    },
                    row: { track, _ in playlistTrackRow(track, playlist: playlist) }
                )
            } else {
                ContentUnavailableView(
                    String(localized: "Playlist Not Found"),
                    systemImage: Icons.musicNoteList
                )
            }
        }
        .navigationTitle(playlist == nil ? String(localized: "Playlist Not Found") : "")
        .navigationBarTitleDisplayMode(.inline)
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
                    localized: "Are you sure you want to delete \"\(PlaylistDisplay.name(for: playlist))\"?"
                ))
            }
        }
        .task(id: playlistID) {
            await refreshMissingFiles()
        }
        .task(id: tintTaskID) {
            await updateHeaderTint()
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

    private func playlistTrackRow(_ track: Track, playlist: Playlist) -> some View {
        Group {
            if missingPaths.contains(track.url.path) {
                MissingTrackRow(track: track)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            } else {
                TrackRow(
                    track: track,
                    onPlay: { play(track, in: playlist) },
                    playlistManager: playlistManager,
                    libraryManager: libraryManager,
                    playbackManager: playbackManager,
                    menuContext: .playlist(playlist)
                )
                .equatable()
            }
        }
    }

    // MARK: - Header

    private func header(_ playlist: Playlist, tracks: [Track]) -> some View {
        DetailHeader(
            onPlay: { playAll(playlist, tracks: tracks) },
            onShuffle: { shuffleAll(playlist, tracks: tracks) },
            playDisabled: tracks.isEmpty,
            title: PlaylistDisplay.name(for: playlist),
            subtitle: subtitle(playlist),
            tint: headerTint,
            artwork: {
                if playlist.coverArtworkData != nil {
                    ArtworkTile(data: playlist.coverArtworkData, cacheKey: "playlist-\(playlist.id)", cornerRadius: 12, iconSize: 56)
                        .frame(width: 240, height: 240)
                } else if let cover = PlaylistCover.of(playlist) {
                    PlaylistCoverView(cover: cover, cornerRadius: 12)
                        .frame(width: 240, height: 240)
                // No service-mark fallback here: the row for this playlist
                // shows the mosaic, and the page it opens has to show the same
                // cover it grew out of.
                } else {
                    ArtworkMosaic(covers: PlaylistCover.mosaicCovers(from: tracks))
                        .frame(width: 240, height: 240)
                }
            }
        )
    }

    /// "N songs" plus the total duration, mirroring the macOS header.
    private func subtitle(_ playlist: Playlist) -> String {
        let count = String(localized: "\(playlist.trackCount) songs")
        if playlist.trackCount > 0 {
            return "\(count) • \(playlist.formattedTotalDuration)"
        }
        return count
    }

    /// The custom cover tints the header; a mosaic has no single color.
    private var headerTint: Color? {
        NowPlayingArtwork.headerTint(
            forDominantColor: headerDominantColor,
            enabled: useArtworkColors
        )
    }

    private var tintTaskID: String {
        "\(playlistID)-\(playlist?.coverArtworkData?.count ?? 0)-\(useArtworkColors)"
    }

    private func updateHeaderTint() async {
        guard useArtworkColors, let artworkData = playlist?.coverArtworkData else {
            headerDominantColor = nil
            return
        }
        let cacheID = playlistID.uuidString
        let dominant = await ImageUtils.cachedDominantColors(id: cacheID, imageData: artworkData).first
        guard !Task.isCancelled else { return }
        headerDominantColor = dominant
    }

    // MARK: - Loading

    private func tracksTaskID(_ playlist: Playlist) -> String {
        "\(playlistID)-\(playlist.dateModified.timeIntervalSince1970)"
    }

    private func loadTracks(_ playlist: Playlist) async -> [Track] {
        if playlist.tracks.isEmpty {
            if playlist.type == .smart {
                await playlistManager.loadSmartPlaylistTracks(playlist)
            } else {
                await playlistManager.loadPlaylistTracks(for: playlist.id)
            }
        }
        return playlistManager.playlists.first { $0.id == playlistID }?.tracks ?? []
    }

    /// Computes which track files are missing from disk. One cheap pass over
    /// the list on open and on every track-set change, so a returned file
    /// revives its row without any reordering. Path building happens inside
    /// the detached task so the main thread never walks the track list.
    private func refreshMissingFiles() async {
        guard let playlist else {
            missingPaths = []
            return
        }

        let tracks = playlist.tracks

        let missing = await Task.detached(priority: .utility) {
            Set(tracks.map(\.url.path).filter { !FileManager.default.fileExists(atPath: $0) })
        }.value

        guard !Task.isCancelled else { return }
        missingPaths = missing
    }

    // MARK: - Playback

    private func play(_ track: Track, in playlist: Playlist) {
        playlistManager.play(track, source: .playlist(playlist))
    }

    private func playAll(_ playlist: Playlist, tracks: [Track]) {
        guard let first = tracks.first else { return }
        playlistManager.play(first, source: .playlist(playlist))
    }

    private func shuffleAll(_ playlist: Playlist, tracks: [Track]) {
        playlistManager.playTrackShuffled(tracks)
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
