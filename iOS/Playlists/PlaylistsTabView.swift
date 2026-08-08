//
// PlaylistsTabView (iOS)
//
// Root of the Playlists tab: smart playlists first in the manager's order
// (Favorites, Top 25 Most Played, Top 25 Recently Played), then user
// playlists alphabetically under a "My Playlists" header - the same order
// as the macOS sidebar. Rows are 56 pt: the playlist's own cover when it
// has one, otherwise the 2x2 preview mosaic; name and track count.
//
// Import (M3U) and the "+" for creating a playlist live in the navigation
// bar. A tap opens the playlist's detail screen.
//

import SwiftUI

struct PlaylistsTabView: View {
    @EnvironmentObject private var libraryManager: LibraryManager
    @EnvironmentObject private var playlistManager: PlaylistManager

    @Binding var showingPlaylistImporter: Bool

    @State private var playlistPreviews: [UUID: [Track]] = [:]
    @State private var loadTask: Task<Void, Never>?

    private static let previewLimit = 4

    var body: some View {
        NavigationStack {
            List {
                if !smartPlaylists.isEmpty {
                    Section {
                        playlistRows(smartPlaylists)
                    }
                }
                if !regularPlaylists.isEmpty {
                    Section(String(localized: "My Playlists")) {
                        playlistRows(regularPlaylists)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(String(localized: "Playlists"))
            .navigationBarTitleDisplayMode(.large)
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
            .overlay {
                if isEmpty, libraryManager.shouldShowMainUI {
                    ContentUnavailableView(
                        String(localized: "No Music"),
                        systemImage: Icons.musicNoteList,
                        description: Text(String(localized: "Add music files to the Petrichor folder in the Files app"))
                    )
                }
            }
            .onAppear(perform: scheduleLoad)
            .onChange(of: playlistManager.playlists.count) { _, _ in
                scheduleLoad()
            }
            .onDisappear {
                loadTask?.cancel()
            }
        }
    }

    private var isEmpty: Bool {
        playlistManager.playlists.isEmpty
    }

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

    private var smartPlaylists: [Playlist] {
        displayPlaylists.filter { $0.type == .smart }
    }

    private var regularPlaylists: [Playlist] {
        displayPlaylists.filter { $0.type == .regular }
    }

    private func playlistRows(_ playlists: [Playlist]) -> some View {
        ForEach(playlists) { playlist in
            NavigationLink(value: playlist.id) {
                PlaylistRowView(
                    playlist: playlist,
                    previewTracks: playlistPreviews[playlist.id] ?? []
                )
            }
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        }
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
        let previewLimit = Self.previewLimit

        let previews = await Task.detached(priority: .userInitiated) {
            Dictionary(
                uniqueKeysWithValues: playlists.map {
                    ($0.id, libraryManager.getPlaylistPreviewTracks($0, limit: previewLimit))
                }
            )
        }.value

        guard !Task.isCancelled else { return }
        playlistPreviews = previews
    }
}

// MARK: - Playlist Row

/// The 56 pt row: cover (own artwork or the preview mosaic), name, count.
private struct PlaylistRowView: View {
    let playlist: Playlist
    let previewTracks: [Track]

    var body: some View {
        HStack(spacing: 12) {
            artwork
                .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 2) {
                Text(DefaultPlaylists.displayName(for: playlist))
                    .font(.body)
                    .lineLimit(1)
                Text(String(localized: "\(playlist.trackCount) songs"))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(height: 56)
    }

    /// The playlist's own cover wins over the preview mosaic, matching the
    /// macOS sidebar: imported playlists (VK, Yandex, Spotify) carry custom
    /// artwork that the 2x2 mosaic would silently ignore.
    @ViewBuilder
    private var artwork: some View {
        if playlist.coverArtworkData != nil {
            ArtworkTile(data: playlist.coverArtworkData, cacheKey: "playlist-\(playlist.id)", cornerRadius: 8, iconSize: 20)
        } else {
            ArtworkMosaic(covers: previewTracks.compactMap { $0.displayArtwork })
        }
    }
}
