import SwiftUI
import UniformTypeIdentifiers

enum RightSidebarContent: Equatable {
    case none
    case queue
    case trackDetail(Track)
    case lyrics
}

private enum MainWindowPanelState: String {
    case none
    case queue
    case lyrics

    init(content: RightSidebarContent) {
        switch content {
        case .queue:
            self = .queue
        case .lyrics:
            self = .lyrics
        case .none, .trackDetail:
            self = .none
        }
    }

    var content: RightSidebarContent {
        switch self {
        case .none:
            return .none
        case .queue:
            return .queue
        case .lyrics:
            return .lyrics
        }
    }
}

private let mainWindowPanelStateKey = "mainWindowPanelState"

struct ContentView: View {
    @EnvironmentObject var playbackManager: PlaybackManager
    @EnvironmentObject var libraryManager: LibraryManager
    @EnvironmentObject var playlistManager: PlaylistManager

    @AppStorage("showFoldersTab")
    private var showFoldersTab = false
    @AppStorage("useArtworkColors")
    private var useArtworkColors = true
    @AppStorage("tintNowPlayingBackground")
    private var tintNowPlayingBackground = true
    @Environment(\.colorScheme)
    private var colorScheme

    @State private var selectedTab: Sections = .home
    @State private var showingSettings = false
    @AppStorage(mainWindowPanelStateKey)
    private var mainWindowPanelState: MainWindowPanelState = .none
    @State private var rightSidebarContent: RightSidebarContent = .none
    @State private var isImmersiveActive = false
    // Toolbar state captured before immersive hides it, so closing restores it.
    @State private var immersiveToolbarWasVisible = true
    @State private var pendingLibraryFilter: LibraryFilterRequest?
    /// An album or artist page shown over the current section, with a back button.
    @State private var detailEntity: (any Entity)?
    @State private var windowDelegate = WindowDelegate()
    @State private var shouldFocusSearch = false
    @State private var showingExportPlaylistSheet = false

    // Sidebar selection state (owned here, passed as bindings to sidebars + content views)
    @State private var selectedPlaylist: Playlist?
    @State private var selectedFolderNode: FolderNode?
    @AppStorage("librarySelectedFilterType")
    private var libraryFilterType: LibraryFilterType = .artists
    @State private var libraryFilterItem: LibraryFilterItem?
    @State private var libraryPendingSearchText: String?
    @State private var libraryFilteredItems: [LibraryFilterItem] = []
    @State private var libraryCachedTracks: [Track] = []
    @State private var librarySelectedSidebarItem: LibrarySidebarItem?

    @ObservedObject private var notificationManager = NotificationManager.shared

    init() {
        let raw = UserDefaults.standard.string(forKey: mainWindowPanelStateKey)
        let restoredPanel = MainWindowPanelState(rawValue: raw ?? "") ?? .none
        _rightSidebarContent = State(initialValue: restoredPanel.content)
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            // Main Content Area with Queue
            mainContentArea

            playerControls
                .animation(.easeInOut(duration: 0.3), value: libraryManager.folders.isEmpty)
        }
        .onKeyPress(.space) {
            if isCurrentlyEditingText() {
                return .ignored
            }

            if playbackManager.currentTrack != nil {
                DispatchQueue.main.async {
                    playbackManager.togglePlayPause()
                }
                return .handled
            }

            return .ignored
        }
        .frame(minWidth: 1000, minHeight: 600)
        .overlay {
            if isImmersiveActive {
                ImmersiveView(
                    isPresented: $isImmersiveActive,
                    artwork: NowPlayingArtwork.image(for: playbackManager.currentTrack),
                    gradient: NowPlayingArtwork.gradient(
                        for: playbackManager.currentTrack,
                        isDark: colorScheme == .dark,
                        enabled: useArtworkColors && tintNowPlayingBackground
                    ),
                    trackID: playbackManager.currentTrack?.id,
                    isDarkMode: colorScheme == .dark
                )
                .transition(.move(edge: .bottom))
            }
        }
        .onChange(of: isImmersiveActive) { _, active in
            // Restore the toolbar at the start of the close, while immersive still
            // covers the window, so its reflow stays off-screen.
            if !active {
                WindowManager.shared.mainWindow?.toolbar?.isVisible = immersiveToolbarWasVisible
            }
        }
        .onAppear(perform: handleOnAppear)
        .contentViewNotificationHandlers(
            shouldFocusSearch: $shouldFocusSearch,
            showingSettings: $showingSettings,
            selectedTab: $selectedTab,
            goToLibraryFilter: goToLibraryFilter,
            showTrackDetail: showTrackDetail
        )
        .onChange(of: playbackManager.currentTrack?.id) { oldId, _ in
            if case .trackDetail(let currentDetailTrack) = rightSidebarContent,
               currentDetailTrack.id == oldId,
               let newTrack = playbackManager.currentTrack {
                rightSidebarContent = .trackDetail(newTrack)
            }
        }
        .onChange(of: selectedTab) {
            // Any section change (a new playlist, a search) leaves the page.
            detailEntity = nil
        }
        .onChange(of: rightSidebarContent) { _, newValue in
            mainWindowPanelState = MainWindowPanelState(content: newValue)
        }
        .onChange(of: libraryManager.globalSearchText) { _, newValue in
            if !newValue.isEmpty {
                detailEntity = nil
            }
            if !newValue.isEmpty && selectedTab != .search {
                selectedTab = .search
            } else if newValue.isEmpty && selectedTab == .search {
                // Search has no sidebar row; a cleared search goes back home.
                selectedTab = .home
            }
        }
        .onChange(of: showFoldersTab) { _, newValue in
            if !newValue && selectedTab == .folders {
                withAnimation(.easeInOut(duration: 0.25)) {
                    selectedTab = .home
                }
            }
        }
        .background(WindowAccessor(windowDelegate: windowDelegate))
        .navigationTitle("")
        .toolbar {
            if #available(macOS 26.0, *) {
                modernToolbarContent
            } else {
                toolbarContent
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
                .environmentObject(libraryManager)
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
        .sheet(isPresented: $playlistManager.showingSmartPlaylistEditor) {
            SmartPlaylistEditorSheet(
                isPresented: $playlistManager.showingSmartPlaylistEditor,
                editingPlaylist: playlistManager.smartPlaylistToEdit
            )
            .environmentObject(playlistManager)
        }
        .sheet(isPresented: $playlistManager.showingRegularPlaylistEditor) {
            RegularPlaylistEditorSheet(
                isPresented: $playlistManager.showingRegularPlaylistEditor,
                editingPlaylist: playlistManager.regularPlaylistToEdit
            )
            .environmentObject(libraryManager)
            .environmentObject(playlistManager)
        }
        .sheet(isPresented: $showingExportPlaylistSheet) {
            ExportPlaylistsSheet(isPresented: $showingExportPlaylistSheet)
                .environmentObject(playlistManager)
        }
        .sheet(item: $libraryManager.pendingMergeRequest) { request in
            MergeEntitySheet(request: request)
                .environmentObject(libraryManager)
        }
        .onReceive(NotificationCenter.default.publisher(for: .importPlaylists)) { _ in
            importPlaylists()
        }
        .onReceive(NotificationCenter.default.publisher(for: .exportPlaylists)) { _ in
            showingExportPlaylistSheet = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleImmersivePlayer)) { _ in
            guard playbackManager.currentTrack != nil || isImmersiveActive else { return }
            if isImmersiveActive {
                withAnimation(.easeInOut(duration: AnimationDuration.immersiveTransition)) {
                    isImmersiveActive = false
                }
            } else {
                openImmersive()
            }
        }
    }

    /// Opens immersive mode, hiding the toolbar only once the cover animation finishes
    /// so its reflow stays hidden behind immersive (hiding earlier reveals a jump).
    private func openImmersive() {
        immersiveToolbarWasVisible = WindowManager.shared.mainWindow?.toolbar?.isVisible ?? true
        withAnimation(.easeInOut(duration: AnimationDuration.immersiveTransition)) {
            isImmersiveActive = true
        }
        // Hide the toolbar after the cover animation via a timed dispatch rather than
        // withAnimation's completion handler, which fires unreliably on macOS 14.
        DispatchQueue.main.asyncAfter(deadline: .now() + AnimationDuration.immersiveTransition) {
            if isImmersiveActive {
                WindowManager.shared.mainWindow?.toolbar?.isVisible = false
            }
        }
    }

    // MARK: - View Components

    @ViewBuilder private var mainContentArea: some View {
        if !libraryManager.shouldShowMainUI {
            NoMusicEmptyStateView(context: .mainWindow)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            PersistentSplitView(
                left: {
                    leftSidebar
                },
                center: {
                    sectionContent
                },
                right: {
                    sidePanel
                }
            )
            .frame(minHeight: 0, maxHeight: .infinity)
        }
    }

    private var leftSidebar: some View {
        MainSidebarView(
            selectedTab: $selectedTab,
            selectedPlaylist: $selectedPlaylist
        ) {
            detailEntity = nil
        }
    }

    private var sectionContent: some View {
        ZStack {
            // Kept alive while hidden: rebuilding the Discover table is slow.
            DiscoverView()
                .opacity(selectedTab == .discover ? 1 : 0)
                .allowsHitTesting(selectedTab == .discover)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if selectedTab == .home {
                HomePage(
                    onOpenAlbum: { album in
                        // The shelf's entity carries only a thumbnail; the library's has the cover.
                        detailEntity = libraryManager.albumEntities.first { $0.albumId == album.albumId } ?? album
                    },
                    onOpenPlaylist: { playlist in
                        selectedPlaylist = playlist
                        selectedTab = .playlists
                    }
                )
            }

            if selectedTab == .library {
                PersistentSplitView(
                    left: {
                        LibrarySidebarView(
                            selectedFilterType: $libraryFilterType,
                            selectedFilterItem: $libraryFilterItem,
                            pendingSearchText: $libraryPendingSearchText,
                            filteredItems: $libraryFilteredItems,
                            selectedSidebarItem: $librarySelectedSidebarItem
                        )
                    },
                    main: {
                        LibraryView(
                            selectedFilterType: $libraryFilterType,
                            selectedFilterItem: $libraryFilterItem,
                            pendingSearchText: $libraryPendingSearchText,
                            cachedFilteredTracks: $libraryCachedTracks,
                            pendingFilter: $pendingLibraryFilter
                        )
                    },
                    leftStorageKey: "libraryColumnSplitPosition"
                )
            }

            if selectedTab == .playlists {
                PlaylistsView(selectedPlaylist: $selectedPlaylist)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if selectedTab == .folders && showFoldersTab {
                PersistentSplitView(
                    left: {
                        FoldersSidebarView(selectedNode: $selectedFolderNode)
                    },
                    main: {
                        FoldersView(selectedFolderNode: $selectedFolderNode)
                    },
                    leftStorageKey: "foldersColumnSplitPosition"
                )
            }

            if selectedTab == .search {
                SearchPage { detailEntity = $0 }
            }

            if let entity = detailEntity {
                EntityDetailView(entity: entity) {
                    detailEntity = nil
                }
                .id(entity.id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var sidePanel: some View {
        switch rightSidebarContent {
        case .queue:
            PlayQueueView(showingQueue: Binding(
                get: { rightSidebarContent == .queue },
                set: { if !$0 { rightSidebarContent = .none } }
            ))
            .background(.ultraThinMaterial)
        case .trackDetail(let track):
            TrackDetailView(track: track) {
                rightSidebarContent = .none
            }
        case .lyrics:
            TrackLyricsView {
                rightSidebarContent = .none
            }
            .background(.ultraThinMaterial)
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder private var playerControls: some View {
        if libraryManager.shouldShowMainUI {
            PlayerView(
                rightSidebarContent: $rightSidebarContent
            )
            .frame(height: 110)
            .background(.windowBackground)
            .shadow(color: .black.opacity(0.08), radius: 10, x: 0, y: -4)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        // Do not remove this spacer, it allows
        // for pushing toolbar items below to the
        // right-edge of window frame on macOS 14.x
        ToolbarItem { Spacer() }

        ToolbarItem(placement: .confirmationAction) {
            HStack(spacing: 8) {
                NotificationTray()
                    .frame(width: 24, height: 24)

                SearchInputField(
                    text: $libraryManager.globalSearchText,
                    placeholder: String(localized: "Search"),
                    fontSize: 12,
                    shouldFocus: shouldFocusSearch
                )
                .frame(width: 280)
                .disabled(!libraryManager.shouldShowMainUI)
            }
        }
    }

    @available(macOS 26.0, *)
    @ToolbarContentBuilder private var modernToolbarContent: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            NotificationTray()
                .frame(width: 34, height: 30)
        }
        .sharedBackgroundVisibility(.hidden)

        ToolbarItem(placement: .confirmationAction) {
            SearchInputField(
                text: $libraryManager.globalSearchText,
                placeholder: String(localized: "Search"),
                fontSize: 12,
                shouldFocus: shouldFocusSearch
            )
            .frame(width: 280)
            .disabled(!libraryManager.shouldShowMainUI)
        }
    }

    // MARK: - Event Handlers

    private func handleOnAppear() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }

    // MARK: - Playlist Import/Export

    private func importPlaylists() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Import Playlists")
        panel.message = String(localized: "Select up to 25 playlist files to import")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = ["m3u", "m3u8"].compactMap { UTType(filenameExtension: $0) }

        panel.begin { response in
            guard response == .OK else { return }

            let urls = panel.urls

            guard urls.count <= 25 else {
                NotificationManager.shared.addMessage(
                    .warning,
                    String(localized: "Selected \(urls.count) files. Please select up to 25 files at a time.")
                )
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    importPlaylists()
                }
                return
            }

            guard !urls.isEmpty else { return }

            NotificationManager.shared.startActivity(String(localized: "Importing playlists..."))

            Task {
                let importResult = await playlistManager.importPlaylists(from: urls)

                await MainActor.run {
                    NotificationManager.shared.stopActivity()
                    showImportNotifications(result: importResult)
                }
            }
        }
    }

    private func showImportNotifications(result: BulkImportResult) {
        var notifications: [(type: NotificationType, message: String)] = []

        // Add individual error messages for failed imports
        for importResult in result.results where importResult.error != nil {
            if let error = importResult.error {
                notifications.append((.error, error.localizedDescription))
            }
        }

        // Build aggregate notification messages
        if result.withWarnings > 0 {
            let message = String(
                localized: "Imported \(result.withWarnings) playlists with \(result.totalTracksMissing) missing tracks"
            )
            notifications.append((.warning, message))
        }

        if result.successful > 0 {
            let message = String(localized: "Successfully imported \(result.successful) playlists (\(result.totalTracksImported) tracks)")
            notifications.append((.info, message))
        }

        if result.totalFiles > 0 && result.successful == 0 && result.withWarnings == 0 {
            let message = String(localized: "Failed to import all \(result.totalFiles) playlists")
            notifications.append((.error, message))
        }

        // Show all notifications
        for notification in notifications {
            NotificationManager.shared.addMessage(notification.type, notification.message)
        }
    }

    // MARK: - Helper Methods

    /// Artists and albums open their own page, as on the iPhone; other filters
    /// (genres, years, composers) open the column browser.
    private func goToLibraryFilter(_ filterType: LibraryFilterType, value: String) {
        if let entity = detailPage(for: filterType, value: value) {
            detailEntity = entity
            return
        }
        detailEntity = nil
        withAnimation(.easeInOut(duration: AnimationDuration.standardDuration)) {
            selectedTab = .library
            pendingLibraryFilter = LibraryFilterRequest(filterType: filterType, value: value)
        }
    }

    private func detailPage(for filterType: LibraryFilterType, value: String) -> (any Entity)? {
        switch filterType {
        case .artists:
            return libraryManager.artistEntities.first { $0.name == value }
                ?? ArtistEntity(name: value, trackCount: 0)
        case .albums:
            return libraryManager.albumEntities.first { $0.name == value }
        default:
            return nil
        }
    }

    private func showTrackDetail(for track: Track) {
        rightSidebarContent = .trackDetail(track)
    }

    private func isCurrentlyEditingText() -> Bool {
        guard let firstResponder = NSApp.keyWindow?.firstResponder else {
            return false
        }

        if firstResponder is NSText || firstResponder is NSTextView {
            return true
        }

        if let textField = firstResponder as? NSTextField, textField.isEditable {
            return true
        }

        return false
    }
}

extension View {
    func contentViewNotificationHandlers(
        shouldFocusSearch: Binding<Bool>,
        showingSettings: Binding<Bool>,
        selectedTab: Binding<Sections>,
        goToLibraryFilter: @escaping (LibraryFilterType, String) -> Void,
        showTrackDetail: @escaping (Track) -> Void
    ) -> some View {
        self
            .onReceive(NotificationCenter.default.publisher(for: .focusSearchField)) { _ in
                shouldFocusSearch.wrappedValue.toggle()
            }
            .onReceive(NotificationCenter.default.publisher(for: .goToLibraryFilter)) { notification in
                if let filterType = notification.userInfo?["filterType"] as? LibraryFilterType,
                   let filterValue = notification.userInfo?["filterValue"] as? String {
                    goToLibraryFilter(filterType, filterValue)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ShowTrackInfo"))) { notification in
                if let track = notification.userInfo?["track"] as? Track {
                    showTrackDetail(track)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("OpenSettings"))) { _ in
                showingSettings.wrappedValue = true
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("OpenSettingsAboutTab"))) { _ in
                showingSettings.wrappedValue = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    NotificationCenter.default.post(
                        name: NSNotification.Name("SettingsSelectTab"),
                        object: SettingsView.SettingsTab.about
                    )
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .navigateToPlaylists)) { notification in
                if let playlistID = notification.userInfo?["playlistID"] as? UUID {
                    // Only animate tab switch if not already on playlists
                    if selectedTab.wrappedValue != .playlists {
                        withAnimation(.easeInOut(duration: AnimationDuration.standardDuration)) {
                            selectedTab.wrappedValue = .playlists
                        }
                    }
                    // Select the playlist in the sidebar
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        NotificationCenter.default.post(
                            name: .selectPlaylist,
                            object: nil,
                            userInfo: ["playlistID": playlistID]
                        )
                    }
                }
            }
    }
}

// MARK: - Create Playlist Sheet

struct CreatePlaylistSheet: View {
    @EnvironmentObject var playlistManager: PlaylistManager
    @Binding var isPresented: Bool
    @Binding var playlistName: String
    let tracksToAdd: [Track]
    let onCreate: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("New Playlist")
                .font(.headline)

            TextField("Playlist Name", text: $playlistName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 250)
                .onSubmit {
                    if !playlistName.isEmpty {
                        onCreate()
                    }
                }

            if !tracksToAdd.isEmpty {
                Text("Will add: \(tracksToAdd.count) tracks")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 12) {
                Button("Cancel") {
                    playlistName = ""
                    isPresented = false
                }
                .keyboardShortcut(.escape)

                Button("Create") {
                    onCreate()
                }
                .keyboardShortcut(.return)
                .disabled(playlistName.isEmpty)
            }
        }
        .padding(30)
        .frame(width: 350)
    }
}

// MARK: - Window Accessor

struct WindowAccessor: NSViewRepresentable {
    let windowDelegate: WindowDelegate

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                window.delegate = windowDelegate
                window.identifier = NSUserInterfaceItemIdentifier(WindowIdentifier.mainWindow)
                window.setFrameAutosaveName(WindowIdentifier.mainWindow)
                WindowManager.shared.mainWindow = window
                window.title = ""
                window.isExcludedFromWindowsMenu = true
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Window Manager

class WindowManager {
    static let shared = WindowManager()
    weak var mainWindow: NSWindow?

    private init() {}
}

// MARK: - Preview

#Preview {
    ContentView()
        .environmentObject({
            let coordinator = AppCoordinator()
            return coordinator.playbackManager
        }())
        .environmentObject({
            let coordinator = AppCoordinator()
            NotificationManager.shared.isActivityInProgress = true
            coordinator.libraryManager.folders = [Folder(url: URL(fileURLWithPath: "/Music"))]
            return coordinator.libraryManager
        }())
        .environmentObject({
            let coordinator = AppCoordinator()
            return coordinator.playlistManager
        }())
}
