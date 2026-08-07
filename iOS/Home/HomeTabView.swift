//
// HomeTabView (iOS)
//
// The Home tab: the playlists grid on top (smart playlists first, then user
// playlists alphabetically - source-name prefixes cluster on their own), then
// three horizontal track-card carousels: Recently Played, Discover, Recently
// Added. A playlist card shows a 2x2 mosaic of its first four tracks' album
// thumbnails; fewer than four tracks fall back to a single cover or a
// placeholder. Track cards play their track on tap.
//

import SwiftUI
import UIKit

struct HomeTabView: View {
    @EnvironmentObject private var libraryManager: LibraryManager
    @EnvironmentObject private var playlistManager: PlaylistManager
    @EnvironmentObject private var playbackManager: PlaybackManager

    @Binding var showingPlaylistImporter: Bool

    @State private var recentlyPlayed: [Track] = []
    @State private var recentlyAdded: [Track] = []
    @State private var discoverTracks: [Track] = []
    @State private var playlistPreviews: [UUID: [Track]] = [:]
    @State private var loadTask: Task<Void, Never>?

    private static let playlistPreviewLimit = 4
    private static let carouselLimit = 10

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if !displayPlaylists.isEmpty {
                        playlistsSection
                    }
                    if !recentlyPlayed.isEmpty {
                        carouselSection(
                            title: String(localized: "Recently Played"),
                            tracks: recentlyPlayed
                        )
                    }
                    if !discoverTracks.isEmpty {
                        carouselSection(
                            title: String(localized: "Discover"),
                            tracks: discoverTracks
                        )
                    }
                    if !recentlyAdded.isEmpty {
                        carouselSection(
                            title: String(localized: "Recently Added"),
                            tracks: recentlyAdded
                        )
                    }
                }
                .padding(.vertical, 8)
            }
            .navigationTitle(String(localized: "Home"))
            .navigationBarTitleDisplayMode(.large)
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
            .navigationDestination(for: UUID.self) { playlistID in
                PlaylistDetailScreen(playlistID: playlistID)
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
            .overlay {
                if isEmpty, libraryManager.shouldShowMainUI {
                    ContentUnavailableView(
                        String(localized: "No Music"),
                        systemImage: Icons.musicNote,
                        description: Text(String(localized: "Add a music folder to get started"))
                    )
                }
            }
            .onAppear(perform: scheduleLoad)
            .onChange(of: libraryManager.tracks.count) { _, _ in
                scheduleLoad()
            }
            .onDisappear {
                loadTask?.cancel()
            }
        }
    }

    private var isEmpty: Bool {
        displayPlaylists.isEmpty
            && recentlyPlayed.isEmpty
            && discoverTracks.isEmpty
            && recentlyAdded.isEmpty
    }

    // MARK: - Playlists Grid

    /// Smart playlists in the manager's order, then user playlists
    /// alphabetically (source prefixes cluster on their own).
    private var displayPlaylists: [Playlist] {
        let smart = playlistManager.playlists.filter { $0.type == .smart }
        let regular = playlistManager.playlists
            .filter { $0.type == .regular }
            .sorted {
                DefaultPlaylists.displayName(for: $0)
                    .localizedStandardCompare(DefaultPlaylists.displayName(for: $1)) == .orderedAscending
            }
        return smart + regular
    }

    private var playlistsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "Playlists"))
                .font(.title2.weight(.bold))
                .padding(.horizontal, 16)

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 16),
                    GridItem(.flexible(), spacing: 16)
                ],
                spacing: 16
            ) {
                ForEach(displayPlaylists) { playlist in
                    NavigationLink(value: playlist.id) {
                        PlaylistCard(
                            playlist: playlist,
                            previewTracks: playlistPreviews[playlist.id] ?? []
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Carousels

    private func carouselSection(title: String, tracks: [Track]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title2.weight(.bold))
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(tracks) { track in
                        HomeTrackCard(track: track) {
                            play(track, in: tracks)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: - Playback

    private func play(_ track: Track, in tracks: [Track]) {
        playlistManager.play(track, source: .library(context: tracks))
    }

    // MARK: - Loading

    private func scheduleLoad() {
        loadTask?.cancel()
        loadTask = Task {
            await load()
        }
    }

    private func load() async {
        if playlistManager.playlists.isEmpty {
            playlistManager.loadPlaylists()
        }

        let libraryManager = libraryManager
        let playlists = displayPlaylists
        let previewLimit = Self.playlistPreviewLimit
        let carouselLimit = Self.carouselLimit

        // The manager keeps the weekly Discover rotation; the Home carousel
        // reads only thumbnails.
        libraryManager.loadDiscoverTracks(populateArtwork: false)
        let managerDiscover = libraryManager.discoverTracks

        let loaded = await Task.detached(priority: .userInitiated) {
            let recentPlayed = libraryManager.getRecentlyPlayedTracks(limit: carouselLimit)
            let recentAdded = libraryManager.getRecentlyAddedTracks(limit: carouselLimit)
            let discover = managerDiscover
            let previews = Dictionary(
                uniqueKeysWithValues: playlists.map {
                    ($0.id, libraryManager.getPlaylistPreviewTracks($0, limit: previewLimit))
                }
            )
            return (recentPlayed, recentAdded, discover, previews)
        }.value

        guard !Task.isCancelled else { return }
        recentlyPlayed = loaded.0
        recentlyAdded = loaded.1
        discoverTracks = loaded.2
        playlistPreviews = loaded.3
    }
}

// MARK: - Playlist Card

private struct PlaylistCard: View {
    let playlist: Playlist
    let previewTracks: [Track]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkMosaic(covers: previewTracks.compactMap { $0.displayArtwork })
                .aspectRatio(1, contentMode: .fit)

            Text(DefaultPlaylists.displayName(for: playlist))
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)

            Text(String(localized: "\(playlist.trackCount) songs"))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Home Track Card

/// The single unit of all three carousels: album thumbnail, title, artist;
/// a tap plays the track.
private struct HomeTrackCard: View {
    let track: Track
    let onPlay: () -> Void

    var body: some View {
        Button(action: onPlay) {
            VStack(alignment: .leading, spacing: 6) {
                artwork
                    .frame(width: 140, height: 140)

                Text(track.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Text(track.displayArtist)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 140, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var artwork: some View {
        ArtworkTile(data: track.displayArtwork, cornerRadius: 10, iconSize: 28)
            .frame(width: 140, height: 140)
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
