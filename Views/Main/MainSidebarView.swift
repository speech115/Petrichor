import SwiftUI

/// The main window's single sidebar, shaped like the iPhone app: Home,
/// Discover and the playlists in one list, imports grouped under their
/// service the way the iPhone's Playlists tab groups them. Picking a row sets
/// the section shown in the center and that section's own selection.
struct MainSidebarView: View {
    @EnvironmentObject var libraryManager: LibraryManager
    @EnvironmentObject var playlistManager: PlaylistManager

    @Binding var selectedTab: Sections
    @Binding var selectedPlaylist: Playlist?
    /// Called on every row click, including the already selected row.
    let onSelect: () -> Void

    @State private var hoveredItemID: UUID?
    @State private var collageArtwork: [UUID: SidebarItemArtwork] = [:]
    @State private var playlistToDelete: Playlist?
    @State private var showingDeleteConfirmation = false

    var body: some View {
        List {
            Section {
                sectionRow(.home)
                sectionRow(.discover)
            }

            Section {
                playlistRows(displayedPlaylists.filter { !$0.isUserEditable })
                playlistRows(displayedPlaylists.filter { $0.isUserEditable && !PlaylistSource.isImported($0) })
            } header: {
                playlistsHeader
            }

            ForEach(PlaylistSource.allCases, id: \.title) { source in
                let playlists = source.members(of: displayedPlaylists)
                if !playlists.isEmpty {
                    Section(source.title) {
                        playlistRows(playlists, movable: false)
                    }
                }
            }

            let otherImports = displayedPlaylists.filter {
                PlaylistSource.isImported($0) && PlaylistSource.of($0) == nil
            }
            if !otherImports.isEmpty {
                Section {
                    playlistRows(otherImports)
                }
            }
        }
        .listStyle(.sidebar)
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
                Text("Are you sure you want to delete \"\(PlaylistDisplay.name(for: playlist))\"? This action cannot be undone.")
            }
        }
    }

    // MARK: - Rows

    private func sectionRow(_ section: Sections) -> some View {
        row(SectionSidebarItem(section: section), isSelected: selectedTab == section) {
            selectedTab = section
            onSelect()
        }
    }

    /// Service sections keep their pinned order, as on the iPhone, so only
    /// the user's own rows can be dragged.
    private func playlistRows(_ playlists: [Playlist], movable: Bool = true) -> some View {
        let items = playlists.map {
            PlaylistSidebarItem(playlist: $0, artworkOverride: collageArtwork[$0.id])
        }
        return ForEach(items) { item in
            row(item, isSelected: selectedTab == .playlists && selectedPlaylist?.id == item.playlist.id) {
                selectedPlaylist = item.playlist
                selectedTab = .playlists
                onSelect()
            }
            .moveDisabled(!movable || !item.playlist.isUserEditable)
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

    /// Same rules as the iOS Playlists tab: only Favorites among the built-in
    /// smart playlists (Top 25 Most/Recently Played stay on Home), and no
    /// exports a strict service section leaves out.
    private var displayedPlaylists: [Playlist] {
        playlistManager.playlists.filter { playlist in
            guard playlist.type == .smart, !playlist.isUserEditable else {
                return !PlaylistSource.isHidden(playlist)
            }
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

/// A row that opens a whole center section (Home, Discover).
private struct SectionSidebarItem: SidebarItem {
    let section: Sections

    /// Stable per section, so hover and selection survive a redraw.
    var id: UUID {
        let index = UInt8(Sections.allCases.firstIndex(of: section) ?? 0)
        return UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, index))
    }

    var title: String { section.label }
    var subtitle: String? { nil }
    var icon: String? { section.icon }
}
