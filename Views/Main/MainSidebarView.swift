import SwiftUI

/// The main window's single sidebar, shaped like the iPhone app: Discover and
/// the playlists in one list. Picking a row sets the section shown in the
/// center and that section's own selection. Search and library links (an
/// artist name in a track) open the column browser, which has no row.
struct MainSidebarView: View {
    @EnvironmentObject var libraryManager: LibraryManager
    @EnvironmentObject var playlistManager: PlaylistManager

    @Binding var selectedTab: Sections
    @Binding var selectedHomeItem: HomeSidebarItem?
    @Binding var selectedPlaylist: Playlist?

    @AppStorage("showFoldersTab")
    private var showFoldersTab = false

    @State private var hoveredItemID: UUID?
    @State private var collageArtwork: [UUID: SidebarItemArtwork] = [:]
    @State private var playlistToDelete: Playlist?
    @State private var showingDeleteConfirmation = false

    var body: some View {
        List {
            Section {
                homeRow(HomeSidebarItem(type: .discover))
                if showFoldersTab {
                    sectionRow(.folders, title: Sections.folders.label)
                }
            }

            Section {
                playlistRows(displayedPlaylists.filter { !$0.isUserEditable })
                playlistRows(displayedPlaylists.filter { $0.isUserEditable && !PlaylistSource.isImported($0) })
            } header: {
                playlistsHeader
            }

            let otherImports = displayedPlaylists.filter {
                PlaylistSource.isImported($0) && PlaylistSource.of($0) == nil
            }
            if !otherImports.isEmpty {
                Section(String(localized: "Imported from services")) {
                    playlistRows(otherImports)
                }
            }
            ForEach(PlaylistSource.allCases, id: \.title) { source in
                let playlists = displayedPlaylists.filter { PlaylistSource.of($0) == source }
                if !playlists.isEmpty {
                    Section(source.importTitle) {
                        playlistRows(playlists)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onAppear {
            if selectedHomeItem == nil {
                selectedHomeItem = HomeSidebarItem(type: .discover)
            }
        }
        .task(id: displayedPlaylists.map(\.id)) {
            await warmCollageArtwork()
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectPlaylist)) { notification in
            if let playlistID = notification.userInfo?["playlistID"] as? UUID,
               let playlist = playlistManager.playlists.first(where: { $0.id == playlistID }) {
                selectedPlaylist = playlist
            }
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
    }

    // MARK: - Rows

    private func homeRow(_ item: HomeSidebarItem) -> some View {
        row(item, isSelected: selectedTab == .home && selectedHomeItem?.id == item.id) {
            selectedHomeItem = item
            selectedTab = .home
        }
    }

    private func sectionRow(_ section: Sections, title: String) -> some View {
        row(SectionSidebarItem(section: section, title: title), isSelected: selectedTab == section) {
            selectedTab = section
        }
    }

    private func playlistRows(_ playlists: [Playlist]) -> some View {
        let items = playlists.map {
            PlaylistSidebarItem(playlist: $0, artworkOverride: collageArtwork[$0.id])
        }
        return ForEach(items) { item in
            row(item, isSelected: selectedTab == .playlists && selectedPlaylist?.id == item.playlist.id) {
                selectedPlaylist = item.playlist
                selectedTab = .playlists
            }
            .moveDisabled(!item.playlist.isUserEditable)
            .contextMenu {
                ForEach(playlistMenuItems(for: item.playlist), id: \.id) { menuItem in
                    ContextMenuItemView(item: menuItem)
                }
            }
        }
        .onMove { offsets, destination in
            var reordered = items.map(\.playlist)
            reordered.move(fromOffsets: offsets, toOffset: destination)
            handlePlaylistReorder(reordered)
        }
    }

    private func row<Item: SidebarItem>(_ item: Item, isSelected: Bool, onTap: @escaping () -> Void) -> some View {
        SidebarItemRow(
            item: item,
            isSelected: isSelected,
            isHovered: hoveredItemID == item.id,
            showCount: false,
            onTap: onTap,
            // swiftlint:disable:next trailing_closure
            onHover: { hoveredItemID = $0 ? item.id : nil }
        )
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(.default, onTap)
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
    }

    private var playlistsHeader: some View {
        HStack {
            Text("Playlists")
            Spacer()
            Menu {
                Button("New Playlist") {
                    playlistManager.showCreateRegularPlaylistModal()
                }
                Button("New Smart Playlist") {
                    playlistManager.showCreateSmartPlaylistModal()
                }
                Divider()
                Button("Import Playlists...") {
                    NotificationCenter.default.post(name: .importPlaylists, object: nil)
                }
                Button("Export Playlists...") {
                    NotificationCenter.default.post(name: .exportPlaylists, object: nil)
                }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Create New Playlist")
        }
    }

    // MARK: - Data

    /// Same rule as the iOS Playlists tab: only Favorites among the built-in
    /// smart playlists. Top 25 Most/Recently Played stay on Home.
    private var displayedPlaylists: [Playlist] {
        playlistManager.playlists.filter { playlist in
            guard playlist.type == .smart, !playlist.isUserEditable else { return true }
            return playlist.name == DefaultPlaylists.favorites
        }
    }

    private func warmCollageArtwork() async {
        let database = libraryManager.databaseManager
        let playlists = displayedPlaylists.filter {
            PlaylistSidebarArtwork.resolve(for: $0) == nil
        }
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

    /// Reorders one section's playlists; every other playlist keeps its slot.
    private func handlePlaylistReorder(_ visibleOrder: [Playlist]) {
        let visibleIDs = Set(visibleOrder.map(\.id))
        var visibleIterator = visibleOrder.makeIterator()
        var merged: [Playlist] = []
        merged.reserveCapacity(playlistManager.playlists.count)
        for playlist in playlistManager.playlists {
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

    // MARK: - Menus

    private func playlistMenuItems(for playlist: Playlist) -> [ContextMenuItem] {
        PlaylistMenuBuilder.items(for: playlist, playlistManager: playlistManager) {
            playlistToDelete = playlist
            showingDeleteConfirmation = true
        }
    }
}

/// A row that opens a whole center section (folders).
private struct SectionSidebarItem: SidebarItem {
    let section: Sections
    let title: String

    var id: UUID {
        switch section {
        case .home: return UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0))
        case .library: return UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1))
        case .playlists: return UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2))
        case .folders: return UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 3))
        }
    }

    var subtitle: String? { nil }
    var icon: String? { section.icon }
    var count: Int? { nil }
}
