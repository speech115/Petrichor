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
    @Environment(\.dismiss) private var dismiss

    @ObservedObject private var screenCache = LibraryScreenCache.shared

    @State private var showingAddSongs = false
    @State private var missingPaths: Set<String> = []
    @State private var showingRenameAlert = false
    @State private var renameText = ""
    @State private var showingDeleteConfirmation = false
    @State private var headerTint: Color?
    @State private var heroScroll = FavoritesHeroScroll()
    /// Apple Music's Edit: handles for reordering and delete circles. Drag
    /// reorder and swipe delete also work outside it.
    @State private var editMode = EditMode.inactive

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
                    initialRows: playlist.tracks.isEmpty && playlist.trackCount > 0 ? nil : playlist.tracks,
                    usesPlainStyle: true,
                    showEmptyState: false,
                    onMove: canEditContent(playlist) ? { offsets, destination in
                        move(offsets, to: destination, in: playlist)
                    } : nil,
                    onDelete: canEditContent(playlist) ? { offsets in
                        remove(offsets, from: playlist)
                    } : nil,
                    header: { tracks in
                        VStack(spacing: 16) {
                            header(playlist, tracks: tracks)
                            if tracks.isEmpty {
                                ContentUnavailableView {
                                    Label(DefaultPlaylists.noSongsText(for: playlist), systemImage: Icons.musicNoteList)
                                } description: {
                                    Text(playlist.type == .regular
                                         ? String(localized: "Choose songs from your library to start this playlist.")
                                         : String(localized: "Songs will appear here as you listen or add favorites."))
                                } actions: {
                                    if playlist.type == .regular && playlist.isContentEditable {
                                        Button("Add Songs") { showingAddSongs = true }.buttonStyle(.borderedProminent)
                                    }
                                }
                            }
                        }
                            .frame(maxWidth: .infinity)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    },
                    row: { track, _ in playlistTrackRow(track, playlist: playlist) }
                )
                .detailPageWash(isFavorites(playlist) ? nil : headerTint,
                                base: isFavorites(playlist) ? .appleFavoritesBackground : nil)
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.contentOffset.y + geometry.contentInsets.top
                } action: { _, offset in
                    heroScroll.offset = offset
                }
                .environment(\.editMode, $editMode)
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
            if editMode.isEditing {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "Done")) {
                        withAnimation { editMode = .inactive }
                    }
                    .fontWeight(.semibold)
                }
            } else if let playlist, playlist.isUserEditable {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if canEditContent(playlist) {
                            Button("Add Songs", systemImage: "plus") { showingAddSongs = true }
                            Button {
                                withAnimation { editMode = .active }
                            } label: {
                                Label(String(localized: "Edit"), systemImage: "arrow.up.arrow.down")
                            }
                            .disabled(playlist.tracks.isEmpty)
                        }
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
                    dismiss()
                }
            }
        } message: {
            if let playlist {
                Text(String(
                    localized: "Are you sure you want to delete \"\(PlaylistDisplay.name(for: playlist))\"?"
                ))
            }
        }
        .sheet(isPresented: $showingAddSongs) {
            AddSongsSheet(playlistID: playlistID, playlistManager: playlistManager)
        }
        // Keyed on the loaded track set, not just the playlist: on first open
        // the tracks arrive after this view appears, and a playlist-only key
        // would check the still-empty list and never look again.
        .task(id: playlist.map { "\(tracksTaskID($0))-\($0.tracks.count)" }) {
            await refreshMissingFiles()
        }
        .detailHeaderTint(cacheID: playlistID.uuidString, imageData: playlist?.coverArtworkData, tint: $headerTint)
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

    // MARK: - Editing

    private func canEditContent(_ playlist: Playlist) -> Bool {
        playlist.type == .regular && playlist.isContentEditable
    }

    /// The manager persists positions and reorders its own rows, which this
    /// screen renders through `initialRows`.
    private func move(_ offsets: IndexSet, to destination: Int, in playlist: Playlist) {
        var ordered = playlist.tracks
        ordered.move(fromOffsets: offsets, toOffset: destination)
        let orderedIDs = ordered.compactMap(\.trackId)
        Task { await playlistManager.applyPlaylistTrackOrder(playlistID: playlist.id, orderedTrackIds: orderedIDs) }
    }

    private func remove(_ offsets: IndexSet, from playlist: Playlist) {
        let removed = offsets.compactMap { playlist.tracks.indices.contains($0) ? playlist.tracks[$0] : nil }
        guard !removed.isEmpty else { return }
        Task { await playlistManager.removeTracksFromPlaylist(tracks: removed, playlistID: playlist.id) }
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
        // Favorites keeps its page color under the songs, as in Music; other
        // playlists keep the system row background over their wash.
        .listRowBackground(isFavorites(playlist) ? Color.clear : nil)
    }

    // MARK: - Header

    private func header(_ playlist: Playlist, tracks: [Track]) -> some View {
        DetailHeader(
            onPlay: { playAll(playlist, tracks: tracks) },
            onShuffle: { shuffleAll(playlist, tracks: tracks) },
            playDisabled: tracks.isEmpty,
            title: PlaylistDisplay.name(for: playlist),
            subtitle: subtitle(playlist),
            artwork: {
                if isFavorites(playlist) {
                    FavoritesHeroStar(scroll: heroScroll)
                } else {
                    PlaylistArtworkView(
                        playlist: playlist,
                        tracks: screenCache.playlistPreviews[playlist.id] ?? tracks,
                        cornerRadius: 12,
                        iconSize: 56
                    )
                        .frame(width: 280, height: 280)
                }
            }
        )
    }

    /// Favorites opens as Music's Favorite Songs page: the star alone, large,
    /// on a page the color of its tile, instead of a framed cover.
    private func isFavorites(_ playlist: Playlist) -> Bool {
        PlaylistCover.of(playlist) == .appleFavorites
    }

    /// "N songs" plus the total duration, mirroring the macOS header.
    private func subtitle(_ playlist: Playlist) -> String {
        let count = TrackCountText.songs(playlist.trackCount)
        if playlist.trackCount > 0 {
            return "\(count) • \(playlist.formattedTotalDuration)"
        }
        return count
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
        playlistManager.queueSourceName = playlist.name
    }
}

// MARK: - Favorites Hero

/// The list's scroll position, read only by the hero star, so scrolling
/// redraws the star and never the screen around it.
@Observable
final class FavoritesHeroScroll {
    /// Points scrolled past the top: negative while the list is pulled down.
    var offset: CGFloat = 0
}

/// Music's large favorites star. Pulled down, it stretches from its bottom
/// edge so its top stays put; scrolled up, it trails the list and softens
/// into a blur as it goes under the bar.
private struct FavoritesHeroStar: View {
    let scroll: FavoritesHeroScroll

    var body: some View {
        let offset = scroll.offset
        Image("cover-apple-favorites")
            .resizable()
            .aspectRatio(1, contentMode: .fit)
            .visualEffect { content, proxy in
                let side = max(proxy.size.height, 1)
                let pull = max(-offset, 0)
                let push = max(offset, 0)
                return content
                    .scaleEffect(1 + pull / side, anchor: .bottom)
                    .offset(y: push * 0.4)
                    .blur(radius: min(push / 14, 18))
                    .opacity(1 - min(push / side, 1) * 0.6)
            }
            // Music draws the star at 0.589 of the screen width and the star
            // fills 0.527 of its square: the square is drawn 1.118 screens
            // wide. Scaled, not framed — a width read from the container
            // inside a List row sends the collection view into a layout loop.
            // The star's own empty margin above it stands in for the gap
            // under the bar.
            .scaleEffect(1.118)
            .padding(.horizontal, -16)
            .padding(.top, -48)
            .accessibilityHidden(true)
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
                    .font(.body)
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
