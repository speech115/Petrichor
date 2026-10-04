import SwiftUI

/// Home, as on the iPhone: a shelf of recently played albums and the
/// Favorites card. Albums open their page, the shelf title and the card
/// open their smart playlists.
struct HomePage: View {
    @EnvironmentObject var libraryManager: LibraryManager
    @EnvironmentObject var playlistManager: PlaylistManager

    let onOpenAlbum: (AlbumEntity) -> Void
    let onOpenPlaylist: (Playlist) -> Void

    @State private var recentAlbums: [AlbumEntity] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                Text("Home")
                    .font(.system(size: 28, weight: .bold))

                if !recentAlbums.isEmpty {
                    recentShelf
                }

                if let favorites = smartPlaylist(DefaultPlaylists.favorites) {
                    favoritesCard(favorites)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Reloaded whenever Home is shown: the shelf follows what was just played.
        .task(id: libraryManager.libraryRevision) {
            await loadRecentAlbums()
        }
    }

    // MARK: - Recently Played

    private var recentShelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let recentlyPlayed = smartPlaylist(DefaultPlaylists.recentlyPlayed) {
                Button { onOpenPlaylist(recentlyPlayed) } label: {
                    HStack(spacing: 4) {
                        Text("Recently Played")
                        Image(systemName: Icons.chevronRight)
                            .foregroundStyle(.secondary)
                    }
                    .font(.title2.bold())
                }
                .buttonStyle(.plain)
            } else {
                Text("Recently Played")
                    .font(.title2.bold())
            }

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(recentAlbums) { album in
                        EntityTile(entity: album, subtitle: album.artistName) { onOpenAlbum(album) }
                    }
                }
            }
        }
    }

    // MARK: - Favorites

    private func favoritesCard(_ favorites: Playlist) -> some View {
        Button { onOpenPlaylist(favorites) } label: {
            HStack(spacing: 20) {
                Image(systemName: Icons.starFill)
                    .font(.system(size: 36))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(DefaultPlaylists.displayName(for: favorites))
                        .font(.title2.bold())
                    Text("\(favorites.trackCount) songs")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: Icons.chevronRight)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: 520, minHeight: 110, alignment: .leading)
            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Data

    private func smartPlaylist(_ name: String) -> Playlist? {
        playlistManager.playlists.first { $0.type == .smart && $0.name == name }
    }

    private func loadRecentAlbums() async {
        let library = libraryManager
        let counts = Dictionary(
            library.albumEntities.compactMap { album in album.albumId.map { ($0, album.trackCount) } },
            uniquingKeysWith: { first, _ in first }
        )
        let albums = await Task.detached(priority: .userInitiated) {
            library.recentlyPlayedAlbums(trackCountsByAlbumID: counts)
        }.value
        guard !Task.isCancelled else { return }
        recentAlbums = albums
    }
}
