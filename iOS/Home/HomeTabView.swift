//
// HomeTabView (iOS)
//
// Favorites is the primary destination; all music and recent albums follow.
//

import SwiftUI

struct HomeTabView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var libraryManager: LibraryManager
    @EnvironmentObject private var playlistManager: PlaylistManager
    @EnvironmentObject private var playbackManager: PlaybackManager

    @Binding var path: [LibraryDestination]
    @Binding var showingSettings: Bool

    @State private var recentAlbums: [AlbumEntity] = []
    @State private var loadTask: Task<Void, Never>?
    @Namespace private var zoomNamespace

    /// Tracks fetched per refresh; the grouping caps the shelf itself.
    private static let recentTracksFetchLimit = 100
    private static let albumShelfLimit = 10

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    favoritesButton
                    librarySection
                    if !recentAlbums.isEmpty {
                        RecentAlbumsShelf(
                            albums: recentAlbums,
                            headerValue: smartPlaylistID(DefaultPlaylists.recentlyPlayed),
                            zoomNamespace: zoomNamespace
                        )
                    }
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
            .overlay {
                if isEmpty, libraryManager.shouldShowMainUI {
                    ContentUnavailableView {
                        Label(String(localized: "No Music"), systemImage: Icons.musicNote)
                    } description: {
                        // System description uses `.secondary` (~3.4:1); the
                        // shared color clears the WCAG AA bar the Home audit
                        // enforces.
                        Text(String(localized: "Add music files to the Petrichor folder in the Files app"))
                            .foregroundStyle(Color.secondaryText)
                    }
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

    // MARK: - Library

    @ViewBuilder
    private var favoritesButton: some View {
        if let favorites = smartPlaylist(DefaultPlaylists.favorites) {
            NavigationLink(value: LibraryDestination.playlist(favorites.id)) {
                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                    : AnyLayout(HStackLayout(spacing: 20))
                layout {
                    Image(systemName: "star.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(DefaultPlaylists.displayName(for: favorites))
                            .font(.title2.bold())
                            .fixedSize(horizontal: false, vertical: true)
                        Text(TrackCountText.songs(favorites.trackCount))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if !dynamicTypeSize.isAccessibilitySize {
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, minHeight: 132, alignment: .leading)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 20))
                .contentShape(RoundedRectangle(cornerRadius: 20))
                .detailZoomSource(.playlist(favorites.id), in: zoomNamespace, cornerRadius: 20)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("home.favorites")
            .padding(.horizontal, 16)
        }
    }

    private var librarySection: some View {
        NavigationLink(value: LibraryDestination.allTracks) {
            libraryRowLabel(
                title: String(localized: "Songs"),
                count: libraryManager.countsLoaded ? libraryManager.songsDisplayCount : nil
            )
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemGroupedBackground)))
        .padding(.horizontal, 16)
    }

    private func libraryRowLabel(title: String, count: Int?) -> some View {
        HStack {
            Text(title)
                .font(.body)
            Spacer()
            if let count {
                Text("\(count)")
                    .font(.body)
                    .foregroundColor(.secondaryText)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 16)
        // Min, not fixed: the row grows with Dynamic Type instead of
        // clipping the title at the largest accessibility sizes.
        .frame(minHeight: 44)
        .contentShape(Rectangle())
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
            CategoryItemsView(filterType: filterType, zoomNamespace: zoomNamespace)
        case .tracks(let item):
            TrackListView(filterItem: item)
        case .allTracks:
            TrackListView(filterItem: nil)
        case .artist(let name):
            ArtistPage(artistName: name, zoomNamespace: zoomNamespace)
        case .album(let album):
            AlbumPage(album: album)
                .detailZoomDestination(.album(album.id), in: zoomNamespace)
        case .playlist(let playlistID):
            PlaylistDetailScreen(
                playlistID: playlistID,
                playlistManager: playlistManager,
                playbackManager: playbackManager,
                playlistCatalog: playlistManager.catalogObservation
            )
            .detailZoomDestination(.playlist(playlistID), in: zoomNamespace)
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
        // Read on the main actor before detaching: `albumEntities` mirrors real
        // `@Published` state, unlike the query wrappers below (which are `nonisolated`
        // because they touch only the `Sendable` `databaseManager`).
        let albumEntities = libraryManager.albumEntities

        let loaded = await Task.detached(priority: .userInitiated) {
            let recentTracks = libraryManager.getRecentlyPlayedTracks(limit: fetchLimit)
            let albumCounts = Dictionary(
                albumEntities.compactMap { entity in
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
