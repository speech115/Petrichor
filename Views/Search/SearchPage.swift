import SwiftUI

/// Search, a sidebar section as in the Music app: a large title and the search
/// field on top, then artists and albums as shelves that open their pages and
/// the matching songs as a track table. The field edits
/// `LibraryManager.globalSearchText`.
struct SearchPage: View {
    @EnvironmentObject var libraryManager: LibraryManager
    @EnvironmentObject var playlistManager: PlaylistManager

    /// Flips to true when ⌘F asks for the cursor in the field.
    var shouldFocusField = false
    let onOpen: (any Entity) -> Void

    @State private var selectedTrackID: String?
    @State private var trackTableSortOrder: [KeyPathComparator<Track>] = []

    /// Results are capped per shelf; the songs table holds everything else.
    private static let shelfLimit = 20

    private var query: String {
        libraryManager.globalSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// FTS5 needs at least two characters (LibrarySearch); the shelves follow it.
    private var isSearching: Bool { query.count >= 2 }

    private var artists: [ArtistEntity] {
        guard isSearching else { return [] }
        return Array(libraryManager.artistEntities.filter { $0.name.localizedCaseInsensitiveContains(query) }
            .prefix(Self.shelfLimit))
    }

    private var albums: [AlbumEntity] {
        guard isSearching else { return [] }
        return Array(libraryManager.albumEntities.filter { $0.name.localizedCaseInsensitiveContains(query) }
            .prefix(Self.shelfLimit))
    }

    private var tracks: [Track] {
        isSearching ? libraryManager.searchResults : []
    }

    var body: some View {
        let artists = artists
        let albums = albums
        let tracks = tracks

        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Search")
                    .font(DetailPageStyle.titleFont)

                SearchInputField(
                    text: $libraryManager.globalSearchText,
                    placeholder: String(localized: "Artists, Albums, Songs"),
                    fontSize: 13,
                    shouldFocus: shouldFocusField
                )
                .frame(maxWidth: 420)
            }

            if !artists.isEmpty {
                EntityShelf(title: LibraryFilterType.artists.pluralDisplayName) {
                    ForEach(artists) { artist in
                        EntityTile(entity: artist, subtitle: String(localized: "\(artist.trackCount) songs"), size: 120) {
                            onOpen(artist)
                        }
                    }
                }
            }

            if !albums.isEmpty {
                EntityShelf(title: LibraryFilterType.albums.pluralDisplayName) {
                    ForEach(albums) { album in
                        EntityTile(entity: album, subtitle: album.artistName, size: 120) {
                            onOpen(album)
                        }
                    }
                }
            }

            if !tracks.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Songs")
                        .font(.title2.bold())
                    TrackView(
                        tracks: tracks,
                        selectedTrackID: $selectedTrackID,
                        playlistID: nil,
                        entityID: nil,
                        sortOrder: $trackTableSortOrder,
                        onPlayTrack: { track in
                            playlistManager.playTrack(track, fromTracks: tracks)
                            playlistManager.currentQueueSource = .library
                        },
                        contextMenuItems: { track, _ in
                            TrackContextMenu.createMenuItems(
                                for: track,
                                playlistManager: playlistManager,
                                currentContext: .library
                            )
                        }
                    )
                }
            }
        }
        .padding([.top, .horizontal], 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay {
            if query.isEmpty {
                EmptyView()
            } else if !isSearching {
                ContentUnavailableView(
                    String(localized: "Keep Typing"),
                    systemImage: Icons.magnifyingGlass,
                    description: Text(String(localized: "Enter at least two characters to search your library."))
                )
            } else if artists.isEmpty && albums.isEmpty && tracks.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
    }
}
