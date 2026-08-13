import SwiftUI
import UniformTypeIdentifiers

struct PlaylistSidebarView: View {
    @EnvironmentObject var playlistManager: PlaylistManager
    @EnvironmentObject var libraryManager: LibraryManager
    @Binding var selectedPlaylist: Playlist?
    @State private var selectedSidebarItem: PlaylistSidebarItem?
    @State private var playlistToDelete: Playlist?
    @State private var showingDeleteConfirmation = false
    @State private var collageArtwork: [UUID: SidebarItemArtwork] = [:]

    var body: some View {
        VStack(spacing: 0) {
            sidebarHeader

            Divider()

            playlistsList
        }
        .alert("Delete Playlist", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) {
                playlistToDelete = nil
            }
            Button("Delete", role: .destructive) {
                if let playlist = playlistToDelete {
                    playlistManager.deletePlaylist(playlist)
                    if selectedPlaylist?.id == playlist.id {
                        selectedPlaylist = nil
                    }
                    playlistToDelete = nil
                }
            }
        } message: {
            if let playlist = playlistToDelete {
                Text("Are you sure you want to delete \"\(DefaultPlaylists.displayName(for: playlist))\"? This action cannot be undone.")
            }
        }
        .onAppear {
            updateSelectedSidebarItem()
        }
        .onChange(of: selectedPlaylist) {
            updateSelectedSidebarItem()
        }
        .onChange(of: displayedPlaylists.map(\.id)) {
            Task { await warmCollageArtwork() }
        }
        .task {
            await warmCollageArtwork()
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectPlaylist)) { notification in
            if let playlistID = notification.userInfo?["playlistID"] as? UUID,
               let playlist = playlistManager.playlists.first(where: { $0.id == playlistID }) {
                selectedPlaylist = playlist
            }
        }
    }

    // MARK: - Update Selection Helper

    private func updateSelectedSidebarItem() {
        if let playlist = selectedPlaylist {
            selectedSidebarItem = PlaylistSidebarItem(playlist: playlist)
        }
    }

    // MARK: - Sidebar Header

    private var sidebarHeader: some View {
        ListHeader(opaque: true) {
            Text("Playlists")
                .headerTitleStyle()

            Spacer()

            Menu {
                Button("New Playlist") {
                    playlistManager.showCreateRegularPlaylistModal()
                }

                Button("New Smart Playlist") {
                    playlistManager.showCreateSmartPlaylistModal()
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
                    .hoverEffect(scale: 1.1)
            }
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .help("Create New Playlist")

            // Kebab menu button
            Menu {
                Button("Import Playlists...") {
                    NotificationCenter.default.post(name: .importPlaylists, object: nil)
                }
                
                Button("Export Playlists...") {
                    NotificationCenter.default.post(name: .exportPlaylists, object: nil)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
                    .hoverEffect(scale: 1.1)
            }
            .buttonStyle(.plain)
            .help("Playlist Options")
        }
    }

    // MARK: - Playlists List

    private var nonEditableCount: Int {
        displayedPlaylists.prefix { !$0.isUserEditable }.count
    }

    private var playlistsList: some View {
        SidebarView(
            items: allPlaylistItems,
            selectedItem: $selectedSidebarItem,
            onItemTap: { item in
                selectedPlaylist = item.playlist
            },
            contextMenuItems: { item in
                playlistMenuItems(for: item)
            },
            showIcon: true,
            iconColor: .secondary,
            showCount: false,
            trailingContent: { item in
                kebabMenu(for: item)
            },
            reorderableFromIndex: nonEditableCount,
            // swiftlint:disable:next trailing_closure
            onReorder: { reorderedItems in
                handlePlaylistReorder(reorderedItems)
            }
        )
    }

    // MARK: - Kebab Menu

    private func kebabMenu(for item: PlaylistSidebarItem) -> AnyView {
        guard item.playlist.isUserEditable else { return AnyView(EmptyView()) }

        let isSelected = selectedSidebarItem?.id == item.id

        return AnyView(
            Menu {
                // Same items as the right-click context menu.
                ForEach(playlistMenuItems(for: item), id: \.id) { menuItem in
                    ContextMenuItemView(item: menuItem)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11))
                    .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
                    .imageScale(.large)
                    .frame(width: 16, height: 16)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        )
    }

    /// Same rule as the iOS Playlists tab: only Favorites among the built-in
    /// smart playlists. Top 25 Most/Recently Played stay on Home.
    private var displayedPlaylists: [Playlist] {
        playlistManager.playlists.filter { playlist in
            guard playlist.type == .smart, !playlist.isUserEditable else { return true }
            return playlist.name == DefaultPlaylists.favorites
        }
    }

    private var allPlaylistItems: [PlaylistSidebarItem] {
        displayedPlaylists.map {
            PlaylistSidebarItem(playlist: $0, artworkOverride: collageArtwork[$0.id])
        }
    }

    private func warmCollageArtwork() async {
        let database = libraryManager.databaseManager
        let playlists = displayedPlaylists.filter {
            PlaylistSidebarArtwork.resolve(for: $0) == nil
        }
        guard !playlists.isEmpty else { return }

        var updates: [UUID: SidebarItemArtwork] = [:]
        for playlist in playlists {
            if let artwork = await PlaylistSidebarArtwork.resolveOrWarmCollage(
                for: playlist,
                database: database
            ), case .data = artwork {
                updates[playlist.id] = artwork
            }
        }
        guard !updates.isEmpty else { return }
        collageArtwork.merge(updates) { _, new in new }
    }

    // MARK: - Reorder Playlists

    private func handlePlaylistReorder(_ reorderedItems: [PlaylistSidebarItem]) {
        let visibleOrder = reorderedItems.map(\.playlist)
        let visibleIDs = Set(visibleOrder.map(\.id))
        let previous = playlistManager.playlists

        // Keep hidden Top 25s in their prior slots; only reshuffle visible rows.
        var visibleIterator = visibleOrder.makeIterator()
        var merged: [Playlist] = []
        merged.reserveCapacity(previous.count)
        for playlist in previous {
            if visibleIDs.contains(playlist.id) {
                if let next = visibleIterator.next() {
                    merged.append(next)
                }
            } else {
                merged.append(playlist)
            }
        }
        while let next = visibleIterator.next() {
            merged.append(next)
        }
        playlistManager.reorderPlaylists(merged)
    }

    // MARK: - Menu Items

    /// Single source of truth for a playlist's actions, rendered by both the right-click
    /// context menu and the kebab menu so the two stay identical. Shared with the Home
    /// sidebar via `PlaylistMenuBuilder`.
    private func playlistMenuItems(for item: PlaylistSidebarItem) -> [ContextMenuItem] {
        PlaylistMenuBuilder.items(for: item.playlist, playlistManager: playlistManager) {
            playlistToDelete = item.playlist
            showingDeleteConfirmation = true
        }
    }
}

// MARK: - Preview

#Preview("Playlist Sidebar") {
    @Previewable @State var selectedPlaylist: Playlist?

    let previewManager = {
        let manager = PlaylistManager()

        // Create sample playlists using the new criteria-based approach
        let smartPlaylists = [
            Playlist(
                name: DefaultPlaylists.favorites,
                criteria: SmartPlaylistCriteria(
                    rules: [
                        SmartPlaylistCriteria.Rule(
                            field: "isFavorite",
                            condition: .equals,
                            value: "true"
                        )
                    ],
                    sortBy: "title",
                    sortAscending: true
                ),
                isUserEditable: false
            ),
            Playlist(
                name: DefaultPlaylists.mostPlayed,
                criteria: SmartPlaylistCriteria(
                    rules: [
                        SmartPlaylistCriteria.Rule(
                            field: "playCount",
                            condition: .greaterThanOrEqual,
                            value: "5"
                        )
                    ],
                    limit: 25,
                    sortBy: "playCount",
                    sortAscending: false
                ),
                isUserEditable: false
            ),
            Playlist(
                name: DefaultPlaylists.recentlyPlayed,
                criteria: SmartPlaylistCriteria(
                    rules: [
                        SmartPlaylistCriteria.Rule(
                            field: "lastPlayedDate",
                            condition: .greaterThan,
                            value: "7days"
                        )
                    ],
                    limit: 25,
                    sortBy: "lastPlayedDate",
                    sortAscending: false
                ),
                isUserEditable: false
            )
        ]

        // Create sample tracks for regular playlists
        var sampleTrack1 = Track(url: URL(fileURLWithPath: "/sample1.mp3"))
        sampleTrack1.title = "Sample Song 1"
        sampleTrack1.artist = "Artist 1"

        var sampleTrack2 = Track(url: URL(fileURLWithPath: "/sample2.mp3"))
        sampleTrack2.title = "Sample Song 2"
        sampleTrack2.artist = "Artist 2"

        let regularPlaylists = [
            Playlist(name: "My Favorites", tracks: [sampleTrack1, sampleTrack2]),
            Playlist(name: "Workout Mix", tracks: [sampleTrack1]),
            Playlist(name: "Relaxing Music", tracks: [])
        ]

        manager.playlists = smartPlaylists + regularPlaylists
        return manager
    }()

    PlaylistSidebarView(selectedPlaylist: $selectedPlaylist)
        .environmentObject(previewManager)
        .frame(width: 250, height: 500)
}

#Preview("Empty Sidebar") {
    @Previewable @State var selectedPlaylist: Playlist?

    let emptyManager = PlaylistManager()

    return PlaylistSidebarView(selectedPlaylist: $selectedPlaylist)
        .environmentObject(emptyManager)
        .frame(width: 250, height: 500)
}
