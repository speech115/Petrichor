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
// small next to 2829 tracks. The query is local state: each keystroke runs
// the FTS search off the main thread, so typing never blocks the main actor.
//

import SwiftUI
import UIKit

struct SearchView: View {
    @Binding var showingSettings: Bool
    /// Bumped by the tab bar when Search is tapped while already open; each
    /// bump puts the keyboard back up without clearing what was typed.
    let focusRequest: Int

    @EnvironmentObject private var libraryManager: LibraryManager
    @EnvironmentObject private var playbackManager: PlaybackManager
    @EnvironmentObject private var playlistManager: PlaylistManager

    @State private var query = ""
    @FocusState private var isSearchFieldFocused: Bool
    @Namespace private var zoomNamespace

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// FTS5 requires at least two characters (LibrarySearch); artists and
    /// albums apply the same threshold so all sections agree.
    private var isSearching: Bool {
        trimmedQuery.count >= 2
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

    /// The single best match, shown as the first block while results exist.
    /// FTS5 already ranks tracks; prefer the first track whose title contains
    /// the query, fall back to the top-ranked row.
    private var topResult: Track? {
        guard isSearching, !trackResults.isEmpty else { return nil }
        return trackResults.first { track in
            track.title.localizedCaseInsensitiveContains(query)
        } ?? trackResults.first
    }

    var body: some View {
        NavigationStack {
            resultsList
                .searchable(
                    text: $query,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: String(localized: "Search Library")
                )
                .searchFocused($isSearchFieldFocused)
                .searchToolbarBehavior(.minimize)
                .autocorrectionDisabled()
                .rootTitle(String(localized: "Search"))
                .toolbar {
                    SettingsToolbarItem(showingSettings: $showingSettings)
                }
                .navigationDestination(for: LibraryDestination.self) { destination in
                    switch destination {
                    case .artist(let name):
                        ArtistPage(artistName: name, zoomNamespace: zoomNamespace)
                    case .album(let album):
                        AlbumPage(album: album)
                            .detailZoomDestination(.album(album.id), in: zoomNamespace)
                    case .category, .tracks, .allTracks:
                        EmptyView()
                    }
                }
                .onChange(of: focusRequest) { _, _ in
                    isSearchFieldFocused = true
                }
                .task(id: query) {
                    await libraryManager.search(query: query)
                }
        }
    }

    private var resultsList: some View {
        List {
            if let topResult {
                Section(String(localized: "Top Result")) {
                    topResultRow(topResult)
                }
            }

            if !trackResults.isEmpty {
                Section(String(localized: "Tracks")) {
                    ForEach(trackResults) { track in
                        TrackRow(
                            track: track,
                            onPlay: { play(track) },
                            playlistManager: playlistManager,
                            libraryManager: libraryManager,
                            playbackManager: playbackManager
                        )
                        .equatable()
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
        if query.isEmpty {
            ContentUnavailableView(
                String(localized: "Search Library"),
                systemImage: Icons.magnifyingGlass,
                description: Text(String(localized: "Find tracks, artists and albums"))
            )
        } else {
            ContentUnavailableView.search(text: query)
        }
    }

    private func topResultRow(_ track: Track) -> some View {
        Button {
            play(track)
        } label: {
            HStack(spacing: 12) {
                topResultArtwork(track)
                    .frame(width: 56, height: 56)

                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(track.displayArtist)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Image(systemName: playlistManager.isCurrent(track) && playbackManager.isPlaying ? Icons.pauseFill : Icons.playFill)
                    .font(.body)
                    .foregroundColor(playlistManager.isCurrent(track) ? .accentColor : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func topResultArtwork(_ track: Track) -> some View {
        ArtworkTile(
            data: track.displayArtwork,
            cacheKey: ArtworkDataLoader.cacheKey(albumId: track.albumId, trackId: track.trackId),
            cornerRadius: 8,
            iconSize: 20,
            loader: track.trackId.flatMap { trackId in
                ArtworkDataLoader.trackListArtwork(
                    database: libraryManager.databaseManager,
                    albumId: track.albumId,
                    trackId: trackId,
                    hasDisplayArtwork: track.displayArtwork != nil
                )
            }
        )
            .frame(width: 56, height: 56)
    }

    private func artistRow(_ artist: ArtistEntity) -> some View {
        NavigationLink(value: LibraryDestination.artist(name: artist.displayName)) {
            entityRow(
                title: artist.displayName,
                subtitle: artist.subtitle,
                artworkData: artist.displayArtwork,
                cacheKey: "artist-\(artist.name)",
                icon: LibraryFilterType.artists.icon,
                loader: artistArtworkLoader(for: artist.name)
            )
        }
        .buttonStyle(.plain)
    }

    private func albumRow(_ album: AlbumEntity) -> some View {
        NavigationLink(value: LibraryDestination.album(album)) {
            entityRow(
                title: album.displayName,
                subtitle: album.artistName ?? album.subtitle,
                artworkData: album.displayArtwork,
                cacheKey: album.albumId.map { "album-\($0)" },
                icon: LibraryFilterType.albums.icon,
                loader: albumArtworkLoader(for: album.albumId)
            )
        }
        .buttonStyle(.plain)
        .detailZoomSource(.album(album.id), in: zoomNamespace)
    }

    private func entityRow(
        title: String,
        subtitle: String?,
        artworkData: Data?,
        cacheKey: String?,
        icon: String,
        loader: ArtworkDataLoader?
    ) -> some View {
        HStack(spacing: 12) {
            ArtworkTile(
                data: artworkData,
                cacheKey: cacheKey,
                placeholderIcon: icon,
                loader: loader
            )
                .frame(width: 44, height: 44)

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

    private func play(_ track: Track) {
        playlistManager.play(track, source: .library(context: trackResults))
    }

    private func artistArtworkLoader(for name: String) -> ArtworkDataLoader {
        let database = libraryManager.databaseManager
        return ArtworkDataLoader { database.getArtistArtworkThumbnail(name: name) }
    }

    private func albumArtworkLoader(for albumId: Int64?) -> ArtworkDataLoader? {
        guard let albumId else { return nil }
        let database = libraryManager.databaseManager
        return ArtworkDataLoader { database.getAlbumArtworkThumbnail(albumId: albumId) }
    }
}
