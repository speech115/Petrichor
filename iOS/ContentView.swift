//
// ContentView (iOS)
//
// iPhone adaptation of the Petrichor main window: tab bar for the main sections,
// a mini player floating above the tab bar, and a Now Playing sheet with the
// shared player components. Library folders are added through the Files app
// picker.
//

import SwiftUI
import UniformTypeIdentifiers

enum RightSidebarContent: Equatable {
    case none
    case queue
    case trackDetail(Track)
    case lyrics
}

struct ContentView: View {
    @EnvironmentObject var playbackManager: PlaybackManager
    @EnvironmentObject var libraryManager: LibraryManager
    @EnvironmentObject var playlistManager: PlaylistManager

    @AppStorage("showFoldersTab")
    private var showFoldersTab = false
    @AppStorage("useArtworkColors")
    private var useArtworkColors = true
    @AppStorage("tintPlaybackControls")
    private var tintPlaybackControls = true

    @Environment(\.colorScheme)
    private var colorScheme

    @State private var selectedTab: Sections = .home
    @State private var selectedHomeSidebarItem: HomeSidebarItem?
    @State private var selectedPlaylist: Playlist?
    @State private var selectedFolderNode: FolderNode?

    @AppStorage("librarySelectedFilterType")
    private var libraryFilterType: LibraryFilterType = .artists
    @State private var libraryFilterItem: LibraryFilterItem?
    @State private var libraryPendingSearchText: String?
    @State private var libraryFilteredItems: [LibraryFilterItem] = []
    @State private var libraryCachedTracks: [Track] = []
    @State private var librarySelectedSidebarItem: LibrarySidebarItem?
    @State private var pendingLibraryFilter: LibraryFilterRequest?

    @State private var showingSettings = false
    @State private var showingNowPlaying = false
    @State private var showingQueue = false
    @State private var showingLyrics = false
    @State private var showingFileImporter = false
    @State private var showingPlaylistImporter = false

    var body: some View {
        TabView(selection: $selectedTab) {
            homeTab
                .tag(Sections.home)
            libraryTab
                .tag(Sections.library)
            playlistsTab
                .tag(Sections.playlists)
            if showFoldersTab {
                foldersTab
                    .tag(Sections.folders)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if playbackManager.currentTrack != nil {
                miniPlayerBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: playbackManager.currentTrack?.id)
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                SettingsView()
                    .environmentObject(libraryManager)
            }
        }
        .sheet(isPresented: $showingNowPlaying) {
            nowPlayingSheet
        }
        .sheet(isPresented: $showingQueue) {
            NavigationStack {
                PlayQueueView(showingQueue: $showingQueue)
                    .environmentObject(playbackManager)
                    .environmentObject(playlistManager)
                    .navigationTitle(String(localized: "Queue"))
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
        .sheet(isPresented: $showingLyrics) {
            NavigationStack {
                TrackLyricsView {
                    showingLyrics = false
                }
                .environmentObject(playbackManager)
                .environmentObject(playlistManager)
                .navigationTitle(String(localized: "Lyrics"))
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .sheet(item: $libraryManager.pendingMergeRequest) { request in
            NavigationStack {
                MergeEntitySheet(request: request)
                    .environmentObject(libraryManager)
            }
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                libraryManager.addFolder(urls: urls)
            }
        }
        .fileImporter(
            isPresented: $showingPlaylistImporter,
            allowedContentTypes: ["m3u", "m3u8"].compactMap { UTType(filenameExtension: $0) },
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                Task {
                    _ = await playlistManager.importPlaylists(from: urls)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showFolderImporter)) { _ in
            showingFileImporter = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryDataDidChange)) { _ in
            refreshLibraryFilterItems()
        }
        .onReceive(NotificationCenter.default.publisher(for: .goToLibraryFilter)) { notification in
            if let filterType = notification.userInfo?["filterType"] as? LibraryFilterType,
               let filterValue = notification.userInfo?["filterValue"] as? String {
                selectedTab = .library
                let allItems = libraryManager.getLibraryFilterItems(for: filterType)
                if let item = allItems.first(where: { $0.name == filterValue }) {
                    libraryFilterType = filterType
                    libraryFilterItem = item
                }
            }
        }
    }

    // MARK: - Home Tab

    private var homeTab: some View {
        NavigationStack {
            HomeView(selectedSidebarItem: $selectedHomeSidebarItem, isShowingEntities: .constant(false))
                .navigationTitle(selectedHomeSidebarItem?.title ?? String(localized: "Home"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        homeSectionMenu
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        HStack(spacing: 12) {
                            Button {
                                showingFileImporter = true
                            } label: {
                                Image(systemName: "folder.badge.plus")
                            }
                            Button {
                                showingSettings = true
                            } label: {
                                Image(systemName: Icons.settings)
                            }
                        }
                    }
                }
                .onAppear {
                    ensureHomeSelection()
                }
                .onChange(of: selectedTab) { _, tab in
                    if tab == .home {
                        ensureHomeSelection()
                    }
                }
        }
    }

    private func ensureHomeSelection() {
        if selectedHomeSidebarItem == nil {
            selectedHomeSidebarItem = HomeSidebarItem(type: .albums, albumCount: libraryManager.albumCount)
        }
    }

    private var homeSectionMenu: some View {
        Menu {
            ForEach(HomeSidebarItem.HomeItemType.allCases, id: \.self) { type in
                Button {
                    selectHomeSection(type)
                } label: {
                    if selectedHomeSidebarItem?.type == type {
                        Label(type.title, systemImage: "checkmark")
                    } else {
                        Text(type.title)
                    }
                }
            }
        } label: {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 16, weight: .medium))
        }
    }

    private func selectHomeSection(_ type: HomeSidebarItem.HomeItemType) {
        switch type {
        case .discover:
            selectedHomeSidebarItem = HomeSidebarItem(type: .discover, trackCount: libraryManager.discoverTracks.count)
        case .tracks:
            selectedHomeSidebarItem = HomeSidebarItem(type: .tracks, trackCount: libraryManager.totalTrackCount)
        case .artists:
            selectedHomeSidebarItem = HomeSidebarItem(type: .artists, artistCount: libraryManager.artistCount)
        case .albums:
            selectedHomeSidebarItem = HomeSidebarItem(type: .albums, albumCount: libraryManager.albumCount)
        }
    }

    // MARK: - Library Tab

    private var libraryTab: some View {
        NavigationStack {
            Group {
                if !libraryManager.globalSearchText.isEmpty {
                    searchResultsList
                } else if let filterItem = libraryFilterItem {
                    LibraryView(
                        selectedFilterType: $libraryFilterType,
                        selectedFilterItem: $libraryFilterItem,
                        pendingSearchText: $libraryPendingSearchText,
                        cachedFilteredTracks: $libraryCachedTracks,
                        pendingFilter: $pendingLibraryFilter
                    )
                    .id(filterItem.id)
                    .navigationTitle(filterItem.name)
                    .navigationBarTitleDisplayMode(.inline)
                } else {
                    libraryFilterList
                }
            }
            .searchable(
                text: $libraryManager.globalSearchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: String(localized: "Search Library")
            )
            .autocorrectionDisabled()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 8) {
                        if libraryFilterItem != nil {
                            Button {
                                libraryFilterItem = nil
                                refreshLibraryFilterItems()
                            } label: {
                                Image(systemName: "chevron.left")
                            }
                        }
                        filterTypeMenu
                    }
                }
            }
        }
        .onAppear {
            if libraryFilterItem == nil, libraryFilteredItems.isEmpty {
                refreshLibraryFilterItems()
            }
        }
        .onChange(of: libraryFilterType) { _, _ in
            libraryFilterItem = nil
            refreshLibraryFilterItems()
        }
        .onChange(of: libraryManager.tracks.count) { _, _ in
            refreshLibraryFilterItems()
        }
    }

    private var searchResultsList: some View {
        TrackView(
            tracks: libraryManager.searchResults,
            selectedTrackID: .constant(nil),
            playlistID: nil,
            entityID: nil,
            sortOrder: .constant([]),
            onPlayTrack: { track in
                playlistManager.playTrack(track, fromTracks: libraryManager.searchResults)
                playlistManager.currentQueueSource = .library
            },
            contextMenuItems: { track, _ in
                TrackContextMenu.createMenuItems(
                    for: track,
                    playlistManager: playlistManager,
                    currentContext: .library
                )
            }
        )
        .navigationTitle(String(localized: "Search"))
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if libraryManager.searchResults.isEmpty {
                ContentUnavailableView.search(text: libraryManager.globalSearchText)
            }
        }
    }

    private var libraryFilterList: some View {
        List {
            Section {
                ForEach(libraryFilteredItems) { item in
                    Button {
                        libraryFilterItem = item
                    } label: {
                        HStack {
                            Text(item.name)
                            Spacer()
                            Text("\(item.count)")
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(String(localized: "Library"))
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if libraryFilteredItems.isEmpty, !libraryManager.shouldShowMainUI {
                ContentUnavailableView(
                    String(localized: "No Music"),
                    systemImage: Icons.musicNote,
                    description: Text(String(localized: "Add a music folder to get started"))
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                filterTypeMenu
            }
        }
    }

    private var filterTypeMenu: some View {
        Menu {
            ForEach(LibraryFilterType.allCases, id: \.self) { type in
                Button {
                    libraryFilterType = type
                } label: {
                    if libraryFilterType == type {
                        Label(type.pluralDisplayName, systemImage: "checkmark")
                    } else {
                        Text(type.pluralDisplayName)
                    }
                }
            }
        } label: {
            Image(systemName: libraryFilterType.icon)
                .font(.system(size: 16, weight: .medium))
        }
    }

    // MARK: - Playlists Tab

    private var playlistsTab: some View {
        NavigationStack {
            List {
                ForEach(playlistManager.playlists) { playlist in
                    NavigationLink(value: playlist.id) {
                        HStack {
                            Image(systemName: Icons.musicNoteList)
                                .foregroundColor(.accentColor)
                            Text(DefaultPlaylists.displayName(for: playlist))
                            Spacer()
                            Text("\(playlist.trackCount)")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        playlistManager.deletePlaylist(playlistManager.playlists[index])
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(String(localized: "Playlists"))
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: UUID.self) { playlistID in
                PlaylistDetailView(playlistID: playlistID)
                    .navigationTitle(String(localized: "Playlist"))
                    .navigationBarTitleDisplayMode(.inline)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        playlistManager.showCreatePlaylistModal()
                    } label: {
                        Image(systemName: "plus")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingPlaylistImporter = true
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                }
            }
            .sheet(isPresented: $playlistManager.showingCreatePlaylistModal) {
                CreatePlaylistSheet(
                    isPresented: $playlistManager.showingCreatePlaylistModal,
                    playlistName: $playlistManager.newPlaylistName,
                    tracksToAdd: playlistManager.tracksToAddToNewPlaylist
                ) {
                    playlistManager.createPlaylistFromModal()
                }
                .environmentObject(playlistManager)
            }
            .onAppear {
                if playlistManager.playlists.isEmpty {
                    playlistManager.loadPlaylists()
                }
            }
        }
    }

    // MARK: - Folders Tab

    private var foldersTab: some View {
        NavigationStack {
            List(libraryManager.folders) { folder in
                Button {
                    selectedFolderNode = folderNode(for: folder)
                } label: {
                    HStack {
                        Image(systemName: Icons.folderFill)
                            .foregroundColor(.accentColor)
                        Text(folder.name)
                        Spacer()
                        Text("\(folder.trackCount)")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(String(localized: "Folders"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingFileImporter = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                }
            }
            .navigationDestination(item: $selectedFolderNode) { node in
                FoldersView(selectedFolderNode: $selectedFolderNode)
                    .navigationTitle(node.name)
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    private func folderNode(for folder: Folder) -> FolderNode {
        let node = FolderNode(url: folder.url, name: folder.name, isWatchFolder: true)
        node.databaseFolder = folder
        return node
    }

    // MARK: - Mini Player

    private var miniPlayerBar: some View {
        HStack(spacing: 12) {
            Button {
                showingNowPlaying = true
            } label: {
                HStack(spacing: 12) {
                    miniArtwork
                        .frame(width: 44, height: 44)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(playbackManager.currentTrack?.title ?? "")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        Text(playbackManager.currentTrack?.displayArtist ?? "")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                playbackManager.togglePlayPause()
            } label: {
                Image(systemName: playbackManager.isPlaying ? Icons.pauseFill : Icons.playFill)
                    .font(.system(size: 22))
                    .foregroundColor(.primary)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.secondary.opacity(0.12)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .animation(.easeInOut(duration: 0.15), value: playbackManager.isPlaying)
            .accessibilityLabel(playbackManager.isPlaying ? String(localized: "Pause") : String(localized: "Play"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    private var miniArtwork: some View {
        Group {
            if let data = playbackManager.currentTrack?.artworkData,
               let image = PlatformImage(data: data) {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.15))
                    Image(systemName: Icons.musicNote)
                        .foregroundColor(.secondary)
                }
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Now Playing Sheet

    private var nowPlayingSheet: some View {
        NavigationStack {
            GeometryReader { geometry in
                let artworkSize = min(280, geometry.size.height * 0.36)
                VStack(spacing: 16) {
                    Spacer(minLength: 4)

                    nowPlayingArtwork
                        .frame(width: artworkSize, height: artworkSize)

                    PlayerTrackDetailsView(
                        track: playbackManager.currentTrack,
                        contextMenuItems: currentTrackContextMenuItems,
                        playlistManager: playlistManager,
                        showTechnicalInfo: false
                    )
                    .padding(.horizontal, 32)

                    NowPlayingProgressBar(
                        accent: controlAccent,
                        neutral: .primary
                    )
                    .padding(.horizontal, 32)

                    NowPlayingControlsView(
                        tint: controlTint,
                        accent: controlAccent,
                        transport: .primary,
                        neutral: .secondary,
                        scale: 1.4
                    )

                    HStack(spacing: 40) {
                        Button {
                            UISelectionFeedbackGenerator().selectionChanged()
                            showingLyrics = true
                        } label: {
                            Image(systemName: Icons.customLyrics)
                                .font(.system(size: 18))
                                .foregroundColor(.secondary)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .disabled(playbackManager.currentTrack == nil)

                        Button {
                            UISelectionFeedbackGenerator().selectionChanged()
                            showingQueue = true
                        } label: {
                            Image(systemName: Icons.queueList)
                                .font(.system(size: 18))
                                .foregroundColor(.secondary)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                    }
                    .padding(.top, 2)

                    Spacer(minLength: 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 8)
            }
            .background(.ultraThinMaterial)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 16) {
                        if playbackManager.currentTrack != nil, !currentTrackContextMenuItems.isEmpty {
                            Menu {
                                TrackContextMenuContent(items: currentTrackContextMenuItems)
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(.secondary)
                                    .frame(width: 32, height: 32)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityLabel(String(localized: "Track menu"))
                        }

                        Button {
                            showingNowPlaying = false
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.secondary)
                                .frame(width: 32, height: 32)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel(String(localized: "Close"))
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear {
            playbackManager.setFineProgressSampling(true)
        }
        .onDisappear {
            playbackManager.setFineProgressSampling(false)
        }
    }

    private var nowPlayingArtwork: some View {
        Group {
            if let data = playbackManager.currentTrack?.artworkData,
               let image = PlatformImage(data: data) {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.secondary.opacity(0.15))
                    Image(systemName: Icons.musicNote)
                        .font(.system(size: 80, weight: .light))
                        .foregroundColor(.secondary)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
    }

    // MARK: - Helpers

    private var controlsTinted: Bool {
        useArtworkColors && tintPlaybackControls
    }

    private var controlTint: Color {
        NowPlayingArtwork.tint(for: playbackManager.currentTrack, useArtworkTint: controlsTinted)
    }

    private var controlAccent: Color {
        NowPlayingArtwork.controlColor(
            for: playbackManager.currentTrack,
            useArtworkTint: controlsTinted,
            isDarkBackground: colorScheme == .dark
        )
    }

    private var currentTrackContextMenuItems: [ContextMenuItem] {
        guard let track = playbackManager.currentTrack else { return [] }
        return TrackContextMenu.createPlayerViewMenuItems(
            for: track,
            playlistManager: playlistManager
        )
    }

    private func refreshLibraryFilterItems() {
        let items = libraryManager.getLibraryFilterItems(for: libraryFilterType)
        let all = [LibraryFilterItem.allItem(for: libraryFilterType, totalCount: libraryManager.totalTrackCount)]
        libraryFilteredItems = all + items
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
