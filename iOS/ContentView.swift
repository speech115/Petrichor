//
// ContentView (iOS)
//
// iPhone main window: four tabs in one bar — Home, Discover, Playlists,
// Search — the shape Apple Music uses. Search is a plain tab, not a
// `role: .search` one: that role draws a separate round button beside the
// pill, which would leave the bar with three items and a satellite.
//
// The tab bar minimizes on scroll down and the accessory (mini player)
// expands with it. Every tab puts its name in a large title top-left and the
// settings gear top-right.
//

import CoreSpotlight
import SwiftUI
import UniformTypeIdentifiers

private enum IOSSection: Hashable {
    case home
    case discover
    case playlists
    case search
}

struct ContentView: View {
    @EnvironmentObject var libraryManager: LibraryManager
    let playlistManager: PlaylistManager
    let playbackManager: PlaybackManager
    @ObservedObject private var createPlaylistPresentation: PlaylistCreatePresentationObservation
    @ObservedObject private var playbackAvailability: PlaybackAvailabilityObservation

    @State private var selectedTab: IOSSection = .home
    @State private var homePath: [LibraryDestination] = []

    @State private var showingSettings = false
    @State private var showingNowPlaying = false
    @State private var showingPlaylistImporter = false
    @State private var importSummary: String?
    @State private var trackInfoTrack: Track?
    /// Incremented every time the Search tab is tapped while Search is already
    /// open. SearchView watches it and raises the keyboard.
    @State private var searchFocusRequest = 0
    @Namespace private var settingsZoomNamespace
    @Namespace private var nowPlayingZoomNamespace

    init(playlistManager: PlaylistManager, playbackManager: PlaybackManager) {
        self.playlistManager = playlistManager
        self.playbackManager = playbackManager
        createPlaylistPresentation = playlistManager.createPresentationObservation
        playbackAvailability = playbackManager.availabilityObservation
    }

    var body: some View {
        mainInterface
        .environment(\.settingsZoomNamespace, settingsZoomNamespace)
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                SettingsScreen()
            }
            .settingsZoomDestination()
            .environment(\.settingsZoomNamespace, settingsZoomNamespace)
        }
        // The create-playlist sheet lives here, not in a tab: TrackRow's
        // "New Playlist..." and the Playlists tab's menu both open it.
        .sheet(isPresented: createPlaylistPresentedBinding) {
            CreatePlaylistSheet(
                isPresented: createPlaylistPresentedBinding,
                playlistName: createPlaylistNameBinding,
                tracksToAdd: createPlaylistPresentation.tracksToAdd
            ) {
                playlistManager.createPlaylistFromModal()
            }
            .environmentObject(playlistManager)
        }
        // Mini-player artwork zooms into the full player (Music-style). The
        // earlier slide overlay was faster (~120 vs ~212 ms) but never read as
        // the Music morph; system zoom wins on feel. The cover is a modal
        // fullScreenCover, so the system already keeps the covered TabView out
        // of hit-testing and VoiceOver — no manual gating needed (the old
        // overlay had to do it by hand).
        .fullScreenCover(isPresented: $showingNowPlaying) {
            NowPlayingScreen(
                isPresented: $showingNowPlaying,
                playbackManager: playbackManager,
                playlistManager: playlistManager
            )
            .navigationTransition(.zoom(sourceID: NowPlayingZoomID.player, in: nowPlayingZoomNamespace))
        }
        .sheet(item: $libraryManager.pendingMergeRequest) { request in
            NavigationStack {
                MergeEntitySheet(request: request)
                    .environmentObject(libraryManager)
            }
        }
        // Presented from here, not from the row or the player, so "Show Info"
        // reaches the same sheet from a list deep in a NavigationStack and from
        // the player surface that covers it.
        .sheet(item: $trackInfoTrack) { track in
            TrackInfoSheet(track: track)
                .environmentObject(libraryManager)
        }
        .fileImporter(
            isPresented: $showingPlaylistImporter,
            allowedContentTypes: ["m3u", "m3u8"].compactMap { UTType(filenameExtension: $0) },
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                Task {
                    let importResult = await playlistManager.importPlaylists(from: urls)
                    await MainActor.run {
                        importSummary = Self.importSummary(for: importResult)
                    }
                }
            }
        }
        .alert(
            String(localized: "Import Playlists"),
            isPresented: Binding(
                get: { importSummary != nil },
                set: { isPresented in
                    if !isPresented {
                        importSummary = nil
                    }
                }
            )
        ) {
            Button(String(localized: "OK"), role: .cancel) {
                importSummary = nil
            }
        } message: {
            Text(importSummary ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: .goToLibraryFilter)) { notification in
            if let filterType = notification.userInfo?["filterType"] as? LibraryFilterType,
               let filterValue = notification.userInfo?["filterValue"] as? String {
                let items = libraryManager.getLibraryFilterItems(for: filterType)
                guard let item = items.first(where: { $0.name == filterValue }) else { return }
                selectedTab = .home
                homePath = [LibraryNavigation.destination(for: filterType, item: item, libraryManager: libraryManager)]
            }
        }
        // A tap on a system-search result (CoreSpotlight). The identifier is
        // routed exactly like `.goToLibraryFilter`: home tab, one pushed
        // destination. A track result opens its album page - no autoplay.
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            guard let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                  let destination = SpotlightRouter.destination(for: identifier, libraryManager: libraryManager) else {
                return
            }
            selectedTab = .home
            homePath = [destination]
        }
        .onReceive(NotificationCenter.default.publisher(for: .showTrackInfo)) { notification in
            if let track = notification.userInfo?["track"] as? Track {
                trackInfoTrack = track
            }
        }
    }

    private var mainInterface: some View {
        TabView(selection: tabSelection) {
            Tab(value: IOSSection.home) {
                homeTab
            } label: {
                Label {
                    Text(String(localized: "Home"))
                } icon: {
                    SymbolImage(Icons.musicNoteHouse)
                }
            }
            Tab(value: IOSSection.discover) {
                discoverTab
            } label: {
                Label {
                    Text(String(localized: "Discover"))
                } icon: {
                    SymbolImage(Icons.sparkles)
                }
            }
            Tab(value: IOSSection.playlists) {
                playlistsTab
            } label: {
                Label {
                    Text(String(localized: "Playlists"))
                } icon: {
                    SymbolImage(Icons.musicNoteList)
                }
            }
            Tab(value: IOSSection.search) {
                searchTab
            } label: {
                Label {
                    Text(String(localized: "Search"))
                } icon: {
                    SymbolImage(Icons.magnifyingGlass)
                }
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory(isEnabled: playbackAvailability.hasCurrentTrack) {
            // Never hidden while the player is up. The full surface is opaque
            // and covers it anyway; hiding it meant a drag revealed an empty
            // accessory and the artwork and title snapped in at unmount.
            MiniPlayerAccessory(
                playbackManager: playbackManager,
                playlistManager: playlistManager,
                showingNowPlaying: $showingNowPlaying,
                zoomNamespace: nowPlayingZoomNamespace
            )
        }
        .environment(\.playerSurfaceCoversContent, showingNowPlaying)
    }

    /// Tapping the tab you are already on still runs the selection setter,
    /// which is the only place a re-tap can be observed.
    private var tabSelection: Binding<IOSSection> {
        Binding(
            get: { selectedTab },
            set: { tab in
                if tab == .search, selectedTab == .search {
                    searchFocusRequest += 1
                }
                selectedTab = tab
            }
        )
    }

    // MARK: - Home Tab

    private var homeTab: some View {
        HomeTabView(
            path: $homePath,
            showingSettings: $showingSettings
        )
    }

    // MARK: - Discover Tab

    private var discoverTab: some View {
        DiscoverTabView(showingSettings: $showingSettings)
    }

    // MARK: - Playlists Tab

    private var playlistsTab: some View {
        PlaylistsTabView(
            playlistManager: playlistManager,
            playbackManager: playbackManager,
            showingPlaylistImporter: $showingPlaylistImporter,
            showingSettings: $showingSettings
        )
    }

    private var createPlaylistPresentedBinding: Binding<Bool> {
        Binding(
            get: { createPlaylistPresentation.isPresented },
            set: { playlistManager.showingCreatePlaylistModal = $0 }
        )
    }

    private var createPlaylistNameBinding: Binding<String> {
        Binding(
            get: { createPlaylistPresentation.playlistName },
            set: { playlistManager.newPlaylistName = $0 }
        )
    }

    // MARK: - Search Tab

    private var searchTab: some View {
        SearchView(
            showingSettings: $showingSettings,
            focusRequest: searchFocusRequest
        )
    }

    /// Where a "Go to..." context-menu item lands in the Home stack, resolved
    /// by the shared `LibraryNavigation` (artists/albums get detail pages,
    /// everything else a filtered track list).
    private func destination(for filterType: LibraryFilterType, item: LibraryFilterItem) -> LibraryDestination {
        LibraryNavigation.destination(for: filterType, item: item, libraryManager: libraryManager)
    }

    // MARK: - Import Summary

    /// One-line digest of a playlist import, mirroring the macOS notification.
    private static func importSummary(for result: BulkImportResult) -> String {
        var parts: [String] = []

        if result.successful > 0 {
            parts.append(String(
                localized: "Successfully imported \(result.successful) playlists (\(result.totalTracksImported) tracks)"
            ))
        }

        if result.withWarnings > 0 {
            parts.append(String(
                localized: "Imported \(result.withWarnings) playlists with \(result.totalTracksMissing) missing tracks"
            ))
        }

        if result.failed > 0 {
            parts.append(String(localized: "Failed to import \(result.failed) playlists"))
        }

        return parts.joined(separator: "\n")
    }
}
