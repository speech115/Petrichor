//
// HomeTabView (iOS)
//
// The Home tab, top to bottom:
//   1. Recently Played - a horizontal shelf of albums (large squares are
//      containers, not songs), grouped from the recently played tracks.
//   2. Library - three rows (Songs, Favorites, Top 25 Most Played) with
//      counts on the right, leading to the all-tracks list and the smart
//      playlists.
//
// Every section title is itself a link - the chevron sits flush against the
// word, there is no "See All" label. Settings live in the navigation bar;
// the playlists grid moved to the Playlists tab and Discover became a tab of
// its own, so Home no longer carries a shelf of it.
//

import SwiftUI

struct HomeTabView: View {
    @EnvironmentObject private var libraryManager: LibraryManager
    @EnvironmentObject private var playlistManager: PlaylistManager
    @EnvironmentObject private var playbackManager: PlaybackManager

    @Binding var path: [LibraryDestination]
    @Binding var showingSettings: Bool

    @State private var recentAlbums: [AlbumEntity] = []
    @State private var loadTask: Task<Void, Never>?

    /// Tracks fetched per refresh; the grouping caps the shelf itself.
    private static let recentTracksFetchLimit = 100
    private static let albumShelfLimit = 10

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if !recentAlbums.isEmpty {
                        RecentAlbumsShelf(
                            albums: recentAlbums,
                            headerValue: smartPlaylistID(DefaultPlaylists.recentlyPlayed)
                        )
                    }
                    librarySection
                }
                .padding(.vertical, 8)
            }
            .rootTitle(String(localized: "Home"))
            .toolbar {
                SettingsToolbarItem(showingSettings: $showingSettings)
            }
            .navigationDestination(for: LibraryDestination.self) { destination in
                destinationView(destination)
            }
            .navigationDestination(for: UUID.self) { playlistID in
                PlaylistDetailScreen(
                    playlistID: playlistID,
                    playlistManager: playlistManager,
                    playbackManager: playbackManager,
                    playlistCatalog: playlistManager.catalogObservation
                )
            }
            .overlay {
                if isEmpty, libraryManager.shouldShowMainUI {
                    ContentUnavailableView(
                        String(localized: "No Music"),
                        systemImage: Icons.musicNote,
                        description: Text(String(localized: "Add music files to the Petrichor folder in the Files app"))
                    )
                }
            }
            .onAppear(perform: scheduleLoad)
            .onChange(of: libraryManager.libraryRevision) { _, _ in
                scheduleLoad()
            }
            .onChange(of: libraryManager.entitiesLoaded) { _, _ in
                scheduleLoad()
            }
            .onDisappear {
                loadTask?.cancel()
            }
        }
    }

    /// The library has no tracks at all. `libraryManager.tracks` is never
    /// populated on iOS (only the macOS Home loads it), so the empty state
    /// keys on the database-backed total instead.
    private var isEmpty: Bool {
        libraryManager.countsLoaded && libraryManager.totalTrackCount == 0
    }

    // MARK: - Library Block

    /// The one section without a title link: it has no whole-list
    /// destination. Rows carry their counts on the right.
    private var librarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: String(localized: "Library"))

            VStack(spacing: 0) {
                libraryRow(
                    title: String(localized: "Songs"),
                    count: libraryManager.countsLoaded ? libraryManager.totalTrackCount : nil,
                    value: LibraryDestination.allTracks
                )
                if let favorites = smartPlaylist(DefaultPlaylists.favorites) {
                    rowDivider
                    libraryRow(
                        title: DefaultPlaylists.displayName(for: favorites),
                        count: favorites.trackCount,
                        value: favorites.id
                    )
                }
                if let mostPlayed = smartPlaylist(DefaultPlaylists.mostPlayed) {
                    rowDivider
                    libraryRow(
                        title: DefaultPlaylists.displayName(for: mostPlayed),
                        count: mostPlayed.trackCount,
                        value: mostPlayed.id
                    )
                }
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemGroupedBackground)))
            .padding(.horizontal, 16)
        }
    }

    private var rowDivider: some View {
        Divider().padding(.leading, 16)
    }

    private func libraryRow(title: String, count: Int?, value: some Hashable) -> some View {
        NavigationLink(value: value) {
            HStack {
                Text(title)
                    .font(.body)
                Spacer()
                if let count {
                    Text("\(count)")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func smartPlaylist(_ name: String) -> Playlist? {
        playlistManager.playlists.first { $0.type == .smart && $0.name == name }
    }

    private func smartPlaylistID(_ name: String) -> UUID? {
        smartPlaylist(name)?.id
    }

    // MARK: - Destinations

    @ViewBuilder
    private func destinationView(_ destination: LibraryDestination) -> some View {
        switch destination {
        case .category(let filterType):
            CategoryItemsView(filterType: filterType)
        case .tracks(let item):
            TrackListView(filterItem: item)
        case .allTracks:
            TrackListView(filterItem: nil)
        case .artist(let name):
            ArtistPage(artistName: name)
        case .album(let album):
            AlbumPage(album: album)
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
        let fetchLimit = Self.recentTracksFetchLimit
        let albumLimit = Self.albumShelfLimit

        let loaded = await Task.detached(priority: .userInitiated) {
            let recentTracks = libraryManager.getRecentlyPlayedTracks(limit: fetchLimit)
            let albumCounts = Dictionary(
                libraryManager.albumEntities.compactMap { entity in
                    entity.albumId.map { ($0, entity.trackCount) }
                },
                uniquingKeysWith: { first, _ in first }
            )
            let albums = RecentAlbumsShelf.albums(
                from: recentTracks,
                limit: albumLimit,
                trackCountsByAlbumID: albumCounts
            )
            return albums
        }.value

        guard !Task.isCancelled else { return }
        recentAlbums = loaded
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
