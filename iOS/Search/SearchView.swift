//
// SearchView (iOS)
//
// The Search tab: one query, results grouped by type — tracks, artists,
// albums. Tracks reuse the shared TrackRow; artist and album rows get their
// page navigation. An empty query offers the library catalogs;
// a query without matches falls back to the system
// "No Results for ..." state.
//
// Tracks come from the FTS5-backed `LibraryManager.searchResults`; artists
// and albums are filtered in memory from the cached entity lists, which are
// small next to 2829 tracks. The query is local state, cleared when the app
// goes to background: each keystroke runs the FTS search off the main
// thread, so typing never blocks the main actor.
//

import SwiftUI
import UIKit

private enum SearchScope: String, CaseIterable {
    case all, songs, albums, artists

    var title: String {
        switch self {
        case .all: String(localized: "All")
        case .songs: String(localized: "Songs")
        case .albums: String(localized: "Albums")
        case .artists: String(localized: "Artists")
        }
    }
}

struct SearchView: View {
    @Binding var showingSettings: Bool
    /// Bumped by the tab bar when Search is tapped while already open; each
    /// bump puts the keyboard back up without clearing what was typed.
    let focusRequest: Int

    @EnvironmentObject private var libraryManager: LibraryManager
    @EnvironmentObject private var playbackManager: PlaybackManager
    @EnvironmentObject private var playlistManager: PlaylistManager
    @Environment(\.scenePhase) private var scenePhase

    /// Newline-joined, newest first. Queries never contain a newline: the
    /// search field is single-line.
    @AppStorage("recentSearches")
    private var recentSearchesRaw = ""
    @State private var isTabVisible = false
    @State private var query = ""
    @State private var isSearchPresented = false
    @State private var scope = SearchScope.all
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
        isSearching ? libraryManager.searchResults : []
    }

    private var artistResults: [ArtistEntity] {
        guard isSearching else { return [] }
        return libraryManager.artistEntities.filter {
            $0.name.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    private var albumResults: [AlbumEntity] {
        guard isSearching else { return [] }
        return libraryManager.albumEntities.filter {
            $0.name.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    private var hasResults: Bool {
        switch scope {
        case .all: !trackResults.isEmpty || !artistResults.isEmpty || !albumResults.isEmpty
        case .songs: !trackResults.isEmpty
        case .albums: !albumResults.isEmpty
        case .artists: !artistResults.isEmpty
        }
    }

    private var topArtist: ArtistEntity? {
        guard scope == .all else { return nil }
        return artistResults.first { $0.name.localizedStandardCompare(trimmedQuery) == .orderedSame }
    }

    private var topAlbum: AlbumEntity? {
        guard scope == .all, topArtist == nil else { return nil }
        return albumResults.first { $0.name.localizedStandardCompare(trimmedQuery) == .orderedSame }
    }

    private var topTrack: Track? {
        guard scope == .all, topArtist == nil, topAlbum == nil else { return nil }
        return trackResults.first { $0.title.localizedCaseInsensitiveContains(trimmedQuery) } ?? trackResults.first
    }

    var body: some View {
        NavigationStack {
            resultsList
                .searchable(
                    text: $query,
                    isPresented: $isSearchPresented,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: String(localized: "Search Library")
                )
                // The system scope bar under the field, as in Apple Music's
                // search: it appears with the first character typed.
                .searchScopes($scope, activation: .onTextEntry) {
                    ForEach(SearchScope.allCases, id: \.self) { item in
                        Text(item.title).tag(item)
                    }
                }
                .dismissKeyboardOnTap(isActive: isTabVisible) { isSearchFieldFocused = false }
                .onAppear { isTabVisible = true }
                .onDisappear { isTabVisible = false }
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
                    case .category(let filterType):
                        CategoryItemsView(filterType: filterType, zoomNamespace: zoomNamespace)
                    case .allTracks:
                        TrackListView(filterItem: nil)
                    case .tracks(let item):
                        TrackListView(filterItem: item)
                    case .playlist:
                        EmptyView()
                    }
                }
                .onChange(of: focusRequest) { _, _ in
                    isSearchFieldFocused = true
                }
                .onSubmit(of: .search) { rememberQuery() }
                // A query is for this visit. Coming back to the app later
                // starts from the empty field; Recent Searches keeps the
                // query one tap away.
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .background else { return }
                    query = ""
                    scope = .all
                    isSearchPresented = false
                }
                .task(id: query) {
                    await libraryManager.search(query: query)
                    // A query that stood still for a moment and found something
                    // is one worth coming back to; keystrokes on the way there
                    // are not, and `remember` folds them into it.
                    try? await Task.sleep(for: .seconds(1.5))
                    guard !Task.isCancelled else { return }
                    rememberQuery()
                }
        }
    }

    // MARK: - Recent Searches

    private static let recentSearchLimit = 8

    private var recentSearches: [String] {
        recentSearchesRaw.split(separator: "\n").map(String.init)
    }

    /// Stores the current query when it found something. Older entries the new
    /// one extends ("10" before "104") or repeats are dropped.
    private func rememberQuery() {
        guard isSearching, hasResults else { return }
        let kept = recentSearches.filter {
            !trimmedQuery.localizedCaseInsensitiveContains($0)
        }
        let updated = ([trimmedQuery] + kept)
            .prefix(Self.recentSearchLimit)
            .joined(separator: "\n")
        if updated != recentSearchesRaw { recentSearchesRaw = updated }
    }

    private func forgetRecentSearch(_ text: String) {
        recentSearchesRaw = recentSearches.filter { $0 != text }.joined(separator: "\n")
    }

    private var resultsList: some View {
        List {
            if trimmedQuery.isEmpty {
                Section("Library") {
                    NavigationLink(value: LibraryDestination.allTracks) {
                        Label("All Music", systemImage: "music.note")
                    }
                    .accessibilityIdentifier("library.allMusic")
                    NavigationLink(value: LibraryDestination.category(.albums)) {
                        Label("Albums", systemImage: "square.stack")
                    }
                    NavigationLink(value: LibraryDestination.category(.artists)) {
                        Label("Artists", systemImage: "person.2")
                    }
                }
                if !recentSearches.isEmpty {
                    Section {
                        ForEach(recentSearches, id: \.self) { text in
                            Button {
                                query = text
                            } label: {
                                Label {
                                    Text(text).foregroundStyle(.primary)
                                } icon: {
                                    Image(systemName: "clock.arrow.circlepath")
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    forgetRecentSearch(text)
                                } label: {
                                    Label(String(localized: "Delete"), systemImage: Icons.trash)
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text("Recent Searches")
                            Spacer()
                            Button("Clear") { recentSearchesRaw = "" }
                                .textCase(nil)
                        }
                    }
                }
            }
            if let topArtist {
                Section("Top Result") { artistRow(topArtist) }
            } else if let topAlbum {
                Section("Top Result") { albumRow(topAlbum) }
            } else if let topTrack {
                Section("Top Result") { topResultRow(topTrack) }
            }

            if scope == .all || scope == .songs, !remainingTracks.isEmpty {
                Section(String(localized: "Tracks")) {
                    ForEach(remainingTracks) { track in
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

            if scope == .all || scope == .artists, !remainingArtists.isEmpty {
                Section(LibraryFilterType.artists.pluralDisplayName) {
                    ForEach(remainingArtists) { artist in
                        artistRow(artist)
                    }
                }
            }

            if scope == .all || scope == .albums, !remainingAlbums.isEmpty {
                Section(LibraryFilterType.albums.pluralDisplayName) {
                    ForEach(remainingAlbums) { album in
                        albumRow(album)
                    }
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if !trimmedQuery.isEmpty, !hasResults {
                emptyState
            }
        }
    }

    private var remainingTracks: [Track] {
        let topID = topTrack?.id
        return trackResults.filter { $0.id != topID }
    }

    private var remainingArtists: [ArtistEntity] {
        let topID = topArtist?.id
        return artistResults.filter { $0.id != topID }
    }

    private var remainingAlbums: [AlbumEntity] {
        let topID = topAlbum?.id
        return albumResults.filter { $0.id != topID }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !isSearching {
            ContentUnavailableView(
                String(localized: "Keep Typing"),
                systemImage: Icons.magnifyingGlass,
                description: Text(String(localized: "Enter at least two characters to search your library."))
            )
        } else {
            ContentUnavailableView.search(text: trimmedQuery)
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
        NavigationLink(value: LibraryDestination.artist(name: artist.name)) {
            entityRow(
                title: artist.displayName,
                subtitle: artist.subtitle,
                artworkData: artist.displayArtwork,
                cacheKey: ArtworkCacheKey.artist(artist.name),
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
                cacheKey: album.albumId.map(ArtworkCacheKey.album),
                icon: LibraryFilterType.albums.icon,
                loader: albumArtworkLoader(for: album.albumId)
            )
            // On the label, not the link: on the link matchedTransitionSource
            // swallows the tap and the row stops navigating.
            .detailZoomSource(.album(album.id), in: zoomNamespace, cornerRadius: 6)
        }
        .buttonStyle(.plain)
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
