import SwiftUI

/// Home, laid out as the Music app's: shelves of recently played albums,
/// the playlists and the library's most played artists. Albums and artists
/// open their pages, playlists open in the Playlists section.
struct HomePage: View {
    @EnvironmentObject var libraryManager: LibraryManager
    @EnvironmentObject var playlistManager: PlaylistManager

    let onOpenEntity: (any Entity) -> Void
    let onOpenPlaylist: (Playlist) -> Void

    /// Artists on the shelf: the library's largest, a stand-in for "your
    /// artists" that needs no play history.
    private static let artistLimit = 15

    /// Tile sizes chosen so all three shelves fit above the floating player
    /// in a 900 pt window: the artist names no longer sit under the capsule.
    static let tileSize: CGFloat = 140
    private static let artistTileSize: CGFloat = 112

    /// The last shelf, so Home shows it at once while the fresh one loads.
    @MainActor private static var lastRecentAlbums: [AlbumEntity] = []
    @State private var recentAlbums: [AlbumEntity] = HomePage.lastRecentAlbums

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Home")
                    .font(.system(size: 28, weight: .bold))

                if !recentAlbums.isEmpty {
                    recentShelf
                }

                if !shelfPlaylists.isEmpty {
                    EntityShelf(title: String(localized: "Playlists")) {
                        ForEach(shelfPlaylists) { playlist in
                            PlaylistTile(playlist: playlist) { onOpenPlaylist(playlist) }
                        }
                    }
                }

                if !topArtists.isEmpty {
                    EntityShelf(title: LibraryFilterType.artists.pluralDisplayName) {
                        ForEach(topArtists) { artist in
                            EntityTile(entity: artist, subtitle: String(localized: "\(artist.trackCount) songs"), size: Self.artistTileSize) {
                                onOpenEntity(artist)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
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
                        EntityTile(entity: album, subtitle: album.artistName, size: Self.tileSize) { onOpenEntity(album) }
                    }
                }
            }
        }
    }

    // MARK: - Data

    /// Favorites first, then the user's and imported playlists in sidebar order.
    private var shelfPlaylists: [Playlist] {
        let favorites = smartPlaylist(DefaultPlaylists.favorites).map { [$0] } ?? []
        let others = playlistManager.playlists.filter { $0.type == .regular && !PlaylistSource.isHidden($0) }
        return favorites + others
    }

    private var topArtists: [ArtistEntity] {
        Array(libraryManager.artistEntities.sorted { $0.trackCount > $1.trackCount }.prefix(Self.artistLimit))
    }

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
        Self.lastRecentAlbums = albums
        // Same shelf: keep the tiles instead of rebuilding them.
        let shelf = { (albums: [AlbumEntity]) in albums.map { "\($0.albumId ?? 0)|\($0.name)|\($0.trackCount)" } }
        guard shelf(albums) != shelf(recentAlbums) else { return }
        recentAlbums = albums
    }
}

/// A playlist on the Home shelf: its cover (pinned cover, saved artwork or
/// the four-cover collage) with the name and song count under it.
private struct PlaylistTile: View {
    let playlist: Playlist
    let onOpen: () -> Void

    private static let size = HomePage.tileSize

    @EnvironmentObject private var libraryManager: LibraryManager
    @State private var artwork: SidebarItemArtwork?

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 6) {
                cover
                    .frame(width: Self.size, height: Self.size)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .shadow(color: .black.opacity(0.15), radius: 6, y: 3)

                VStack(alignment: .leading, spacing: 2) {
                    Text(PlaylistDisplay.name(for: playlist))
                        .font(.system(size: 13, weight: .semibold))
                    Text(String(localized: "\(playlist.trackCount) songs"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
            }
            .frame(width: Self.size, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .task(id: playlist.id) {
            artwork = PlaylistSidebarArtwork.resolve(for: playlist)
            if artwork == nil {
                artwork = await PlaylistSidebarArtwork.resolveOrWarmCollage(
                    for: playlist,
                    database: libraryManager.databaseManager
                )
            }
        }
    }

    @ViewBuilder private var cover: some View {
        switch artwork {
        case .data(let data):
            if let image = PlatformImage(data: data) {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
        case .playlistCover(let cover):
            PlaylistCoverView(cover: cover, cornerRadius: 10)
        case nil:
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            Color.secondary.opacity(0.15)
            Image(systemName: Icons.musicNoteList)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
        }
    }
}
