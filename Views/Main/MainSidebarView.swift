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
    /// An album or artist page covers the center: no row is selected then,
    /// so clicking the row it came from opens that row again.
    let isShowingPage: Bool
    /// Called whenever a row is picked.
    let onSelect: () -> Void

    @State private var collageArtwork: [UUID: SidebarItemArtwork] = [:]
    @State private var playlistToDelete: Playlist?
    @State private var showingDeleteConfirmation = false

    var body: some View {
        // Native selection, as the Music app's sidebar: the whole row takes the
        // click and selects on mouse down, with the system highlight and arrow keys.
        List(selection: selection) {
            let displayed = displayedPlaylists

            Section {
                sectionRow(.home)
                sectionRow(.discover)
            }

            Section {
                playlistRows(displayed.filter { !$0.isUserEditable })
                playlistRows(displayed.filter { $0.isUserEditable && !PlaylistSource.isImported($0) })
            } header: {
                playlistsHeader
            }

            ForEach(PlaylistSource.allCases, id: \.title) { source in
                let playlists = source.members(of: displayed)
                if !playlists.isEmpty {
                    Section(source.title) {
                        playlistRows(playlists, movable: false)
                    }
                }
            }

            let otherImports = displayed.filter {
                PlaylistSource.isImported($0) && PlaylistSource.of($0) == nil
            }
            if !otherImports.isEmpty {
                Section {
                    playlistRows(otherImports)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(SeeThroughSidebar())
        .task(id: displayedPlaylists.map(\.id)) {
            await warmCollageArtwork()
            await preloadPlaylistTracks()
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

    private enum Selection: Hashable {
        case section(Sections)
        case playlist(UUID)
    }

    private var selection: Binding<Selection?> {
        Binding {
            guard !isShowingPage else { return nil }
            switch selectedTab {
            case .home, .discover: return .section(selectedTab)
            case .playlists: return selectedPlaylist.map { .playlist($0.id) }
            case .library, .search: return nil
            }
        } set: { newValue in
            switch newValue {
            case .section(let section):
                selectedTab = section
            case .playlist(let id):
                guard let playlist = playlistManager.playlists.first(where: { $0.id == id }) else { return }
                selectedPlaylist = playlist
                selectedTab = .playlists
            case nil:
                return
            }
            onSelect()
        }
    }

    private func sectionRow(_ section: Sections) -> some View {
        SidebarRowLabel(item: SectionSidebarItem(section: section))
            .tag(Selection.section(section))
    }

    /// Service sections keep their pinned order, as on the iPhone, so only
    /// the user's own rows can be dragged.
    private func playlistRows(_ playlists: [Playlist], movable: Bool = true) -> some View {
        let items = playlists.map {
            PlaylistSidebarItem(playlist: $0, artworkOverride: collageArtwork[$0.id])
        }
        return ForEach(items) { item in
            SidebarRowLabel(item: item)
                .tag(Selection.playlist(item.playlist.id))
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

    /// Loads every sidebar playlist's tracks in the background, so opening one
    /// shows its table at once instead of waiting on the database.
    private func preloadPlaylistTracks() async {
        for playlist in displayedPlaylists where playlist.tracks.isEmpty {
            guard !Task.isCancelled else { return }
            if playlist.type == .smart {
                await playlistManager.loadSmartPlaylistTracks(playlist)
            } else {
                await playlistManager.loadPlaylistTracks(for: playlist.id)
            }
        }
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

/// A sidebar row's content; the list draws the highlight.
private struct SidebarRowLabel<Item: SidebarItem>: View {
    let item: Item

    var body: some View {
        Label {
            Text(item.title)
                .lineLimit(1)
                .help(item.title)
        } icon: {
            switch item.artwork {
            case .data(let data):
                if let image = PlatformImage(data: data) {
                    Image(platformImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 20, height: 20)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                } else {
                    symbol
                }
            case .playlistCover(let cover):
                PlaylistCoverView(cover: cover, cornerRadius: 3)
                    .frame(width: 20, height: 20)
            case nil:
                symbol
            }
        }
    }

    @ViewBuilder private var symbol: some View {
        let icon = item.icon ?? Icons.musicNoteList
        if icon.hasPrefix("custom.") {
            Image(icon)
        } else {
            Image(systemName: icon)
        }
    }
}

/// Lets the desktop show through the sidebar like glass. The system sidebar's
/// vibrancy alone stays nearly opaque, so the window stops drawing its own
/// background and the sidebar's vibrancy view is made half transparent;
/// the detail column paints the window background itself.
private struct SeeThroughSidebar: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear

            var ancestor = superview
            while let view = ancestor, !(view is NSVisualEffectView) {
                ancestor = view.superview
            }
            guard let vibrancy = ancestor as? NSVisualEffectView else { return }
            vibrancy.state = .active
            vibrancy.alphaValue = 0.5
        }
    }
}
