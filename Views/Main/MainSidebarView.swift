import SwiftUI

/// The main window's single sidebar, Apple Music style: Discover, the library
/// sections, pinned items and playlists in one list. Picking a row sets the
/// section shown in the center and that section's own selection.
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
            }

            Section(String(localized: "Library")) {
                homeRow(HomeSidebarItem(type: .tracks))
                homeRow(HomeSidebarItem(type: .artists))
                homeRow(HomeSidebarItem(type: .albums))
                sectionRow(.library, title: String(localized: "Browse"))
                if showFoldersTab {
                    sectionRow(.folders, title: Sections.folders.label)
                }
            }

            if !pinnedItems.isEmpty {
                Section(String(localized: "Pinned")) {
                    ForEach(pinnedItems) { item in
                        homeRow(item)
                    }
                    .onMove { offsets, destination in
                        var reordered = libraryManager.pinnedItems
                        reordered.move(fromOffsets: offsets, toOffset: destination)
                        Task { await libraryManager.reorderPinnedItems(reordered) }
                    }
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
        .task(id: collagePlaylistIDs) {
            await warmCollageArtwork()
        }
        .onChange(of: libraryManager.pinnedItems) {
            // A removed pinned item can't stay selected.
            if case .pinned(let pinned) = selectedHomeItem?.source,
               !libraryManager.pinnedItems.contains(where: { $0.id == pinned.id }) {
                selectedHomeItem = HomeSidebarItem(type: .discover)
            }
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
        row(item, isSelected: selectedTab == .home && isSelectedHomeItem(item)) {
            selectedHomeItem = item
            selectedTab = .home
        }
        .contextMenu {
            ForEach(homeMenuItems(for: item), id: \.id) { menuItem in
                ContextMenuItemView(item: menuItem)
            }
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

    private var pinnedItems: [HomeSidebarItem] {
        let playlistsById = Dictionary(playlistManager.playlists.map { ($0.id, $0) }) { first, _ in first }
        return libraryManager.pinnedItems.map { pinnedItem in
            let playlist = pinnedItem.playlistId.flatMap { playlistsById[$0] }
            return HomeSidebarItem(
                pinnedItem: pinnedItem,
                playlist: playlist,
                artworkOverride: playlist.flatMap { collageArtwork[$0.id] }
            )
        }
    }

    /// Same rule as the iOS Playlists tab: only Favorites among the built-in
    /// smart playlists. Top 25 Most/Recently Played stay on Home.
    private var displayedPlaylists: [Playlist] {
        playlistManager.playlists.filter { playlist in
            guard playlist.type == .smart, !playlist.isUserEditable else { return true }
            return playlist.name == DefaultPlaylists.favorites
        }
    }

    /// Displayed and pinned playlists — the ones whose rows may need a collage.
    private var collagePlaylistIDs: [UUID] {
        let pinned = Set(libraryManager.pinnedItems.compactMap(\.playlistId))
        let displayed = Set(displayedPlaylists.map(\.id))
        return playlistManager.playlists.map(\.id).filter { pinned.contains($0) || displayed.contains($0) }
    }

    private func isSelectedHomeItem(_ item: HomeSidebarItem) -> Bool {
        switch (selectedHomeItem?.source, item.source) {
        case let (.fixed(selected)?, .fixed(type)):
            return selected == type
        case let (.pinned(selected)?, .pinned(pinned)):
            return selected.id == pinned.id
        default:
            return false
        }
    }

    private func warmCollageArtwork() async {
        let database = libraryManager.databaseManager
        let ids = Set(collagePlaylistIDs)
        let playlists = playlistManager.playlists.filter {
            ids.contains($0.id) && PlaylistSidebarArtwork.resolve(for: $0) == nil
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

    private func homeMenuItems(for item: HomeSidebarItem) -> [ContextMenuItem] {
        guard case .pinned(let pinnedItem) = item.source else { return [] }

        if let playlistId = pinnedItem.playlistId,
           let playlist = playlistManager.playlists.first(where: { $0.id == playlistId }) {
            return playlistMenuItems(for: playlist)
        }

        return [
            .button(title: String(localized: "Remove from Home"), role: nil) {
                Task { await libraryManager.removePinnedItem(pinnedItem) }
            }
        ]
    }

    private func playlistMenuItems(for playlist: Playlist) -> [ContextMenuItem] {
        PlaylistMenuBuilder.items(for: playlist, playlistManager: playlistManager) {
            playlistToDelete = playlist
            showingDeleteConfirmation = true
        }
    }
}

/// A row that opens a whole center section (the column browser, folders).
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
