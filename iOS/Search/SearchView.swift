//
// SearchView (iOS)
//
// The Search tab: one query, results grouped by type — tracks, artists,
// albums. Tracks reuse the shared TrackRow; artist and album rows get their
// page navigation in ticket 06 (TODO below). An empty query explains what
// can be searched; a query without matches falls back to the system
// "No Results for ..." state.
//
// Tracks come from the FTS5-backed `LibraryManager.searchResults`; artists
// and albums are filtered in memory from the cached entity lists, which are
// small next to 2829 tracks.
//

import SwiftUI
import UIKit

struct SearchView: View {
    @EnvironmentObject private var libraryManager: LibraryManager
    @EnvironmentObject private var playbackManager: PlaybackManager
    @EnvironmentObject private var playlistManager: PlaylistManager

    private var query: String {
        libraryManager.globalSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// FTS5 requires at least two characters (LibrarySearch); artists and
    /// albums apply the same threshold so all sections agree.
    private var isSearching: Bool {
        query.count >= 2
    }

    private var trackResults: [Track] {
        libraryManager.searchResults
    }

    private var artistResults: [ArtistEntity] {
        guard isSearching else { return [] }
        return libraryManager.artistEntities.filter {
            $0.name.localizedCaseInsensitiveContains(query)
        }
    }

    private var albumResults: [AlbumEntity] {
        guard isSearching else { return [] }
        return libraryManager.albumEntities.filter {
            $0.name.localizedCaseInsensitiveContains(query)
        }
    }

    private var hasResults: Bool {
        !trackResults.isEmpty || !artistResults.isEmpty || !albumResults.isEmpty
    }

    var body: some View {
        NavigationStack {
            resultsList
                .searchable(
                    text: $libraryManager.globalSearchText,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: String(localized: "Search Library")
                )
                .searchToolbarBehavior(.minimize)
                .autocorrectionDisabled()
                .navigationTitle(String(localized: "Search"))
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for: LibraryDestination.self) { destination in
                    switch destination {
                    case .artist(let name):
                        ArtistPage(artistName: name)
                    case .album(let album):
                        AlbumPage(album: album)
                    case .category, .tracks, .allTracks, .discover:
                        EmptyView()
                    }
                }
        }
    }

    private var resultsList: some View {
        List {
            if !trackResults.isEmpty {
                Section(String(localized: "Tracks")) {
                    ForEach(trackResults) { track in
                        TrackRow(
                            track: track,
                            isCurrent: isCurrent(track),
                            isPlaying: isCurrent(track) && playbackManager.isPlaying,
                            onPlay: { play(track) }
                        )
                    }
                }
            }

            if !artistResults.isEmpty {
                Section(LibraryFilterType.artists.pluralDisplayName) {
                    ForEach(artistResults) { artist in
                        artistRow(artist)
                    }
                }
            }

            if !albumResults.isEmpty {
                Section(LibraryFilterType.albums.pluralDisplayName) {
                    ForEach(albumResults) { album in
                        albumRow(album)
                    }
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if !hasResults {
                emptyState
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if libraryManager.globalSearchText.isEmpty {
            ContentUnavailableView(
                String(localized: "Search Library"),
                systemImage: Icons.magnifyingGlass,
                description: Text(String(localized: "Find tracks, artists and albums"))
            )
        } else {
            ContentUnavailableView.search(text: libraryManager.globalSearchText)
        }
    }

    private func artistRow(_ artist: ArtistEntity) -> some View {
        NavigationLink(value: LibraryDestination.artist(name: artist.displayName)) {
            entityRow(
                title: artist.displayName,
                subtitle: artist.subtitle,
                artworkData: artist.artworkData,
                icon: LibraryFilterType.artists.icon
            )
        }
        .buttonStyle(.plain)
    }

    private func albumRow(_ album: AlbumEntity) -> some View {
        NavigationLink(value: LibraryDestination.album(album)) {
            entityRow(
                title: album.displayName,
                subtitle: album.artistName ?? album.subtitle,
                artworkData: album.artworkData,
                icon: LibraryFilterType.albums.icon
            )
        }
        .buttonStyle(.plain)
    }

    private func entityRow(
        title: String,
        subtitle: String?,
        artworkData: Data?,
        icon: String
    ) -> some View {
        HStack(spacing: 12) {
            Group {
                if let artworkData, let image = UIImage(data: artworkData) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.secondary.opacity(0.12))
                        Image(systemName: icon)
                            .font(.system(size: 16))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)
        }
        .contentShape(Rectangle())
    }

    private func isCurrent(_ track: Track) -> Bool {
        guard let currentTrack = playbackManager.currentTrack else { return false }
        if let currentId = currentTrack.trackId, let trackId = track.trackId {
            return currentId == trackId
        }
        return currentTrack.url.path == track.url.path
    }

    private func play(_ track: Track) {
        playlistManager.playTrack(track, fromTracks: trackResults)
        playlistManager.currentQueueSource = .library
    }
}
