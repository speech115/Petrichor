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

import SwiftUI
import UniformTypeIdentifiers

enum RightSidebarContent: Equatable {
    case none
    case queue
    case trackDetail(Track)
    case lyrics
}

private enum IOSSection: Hashable {
    case home
    case discover
    case playlists
    case search
}

struct ContentView: View {
    @EnvironmentObject var playbackManager: PlaybackManager
    @EnvironmentObject var libraryManager: LibraryManager
    @EnvironmentObject var playlistManager: PlaylistManager

    @State private var selectedTab: IOSSection = .home
    @State private var homePath: [LibraryDestination] = []

    @State private var showingSettings = false
    @State private var showingNowPlaying = false
    @State private var showingPlaylistImporter = false
    @State private var importSummary: String?
    /// Incremented every time the Search tab is tapped while Search is already
    /// open. SearchView watches it and raises the keyboard.
    @State private var searchFocusRequest = 0

    var body: some View {
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
        .tabViewBottomAccessory(isEnabled: playbackManager.currentTrack != nil) {
            MiniPlayerAccessory(showingNowPlaying: $showingNowPlaying)
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                SettingsScreen()
            }
        }
        // The create-playlist sheet lives here, not in a tab: TrackRow's
        // "New Playlist..." and the Playlists tab's menu both open it.
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
        // Now Playing is an in-hierarchy overlay, not a `.fullScreenCover`. A
        // modal cover keeps a touch-blocking layer over the tab bar for its
        // whole ~0.5s dismiss animation (and ~1s with a zoom transition), so the
        // mini player underneath is dead until it finishes. As a sibling overlay
        // the mini player stays live: `allowsHitTesting(showingNowPlaying)` lets
        // taps fall straight through the moment a dismiss starts, and the
        // spring below is a transition we own rather than the fixed modal one.
        .overlay {
            if showingNowPlaying {
                NowPlayingScreen(isPresented: $showingNowPlaying)
                    .transition(.move(edge: .bottom))
                    .allowsHitTesting(showingNowPlaying)
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.88), value: showingNowPlaying)
        .sheet(item: $libraryManager.pendingMergeRequest) { request in
            NavigationStack {
                MergeEntitySheet(request: request)
                    .environmentObject(libraryManager)
            }
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
                homePath = [destination(for: filterType, item: item)]
            }
        }
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
            showingPlaylistImporter: $showingPlaylistImporter,
            showingSettings: $showingSettings
        )
    }

    // MARK: - Search Tab

    private var searchTab: some View {
        SearchView(
            showingSettings: $showingSettings,
            focusRequest: searchFocusRequest
        )
    }

    /// Where a "Go to..." context-menu item lands in the Home stack. Artists
    /// and albums get their detail pages; everything else (genres, years,
    /// composers, album artists) becomes a plain filtered track list.
    private func destination(for filterType: LibraryFilterType, item: LibraryFilterItem) -> LibraryDestination {
        switch filterType {
        case .artists:
            return .artist(name: item.name)
        case .albums:
            return .album(albumEntity(for: item) ?? AlbumEntity(name: item.name, trackCount: item.count))
        default:
            return .tracks(item)
        }
    }

    private func albumEntity(for item: LibraryFilterItem) -> AlbumEntity? {
        if let albumId = item.albumId {
            return libraryManager.albumEntities.first { $0.albumId == albumId }
        }
        return libraryManager.albumEntities.first { $0.name == item.name }
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

// MARK: - Mini Player Accessory

private struct MiniPlayerAccessory: View {
    @Environment(\.tabViewBottomAccessoryPlacement)
    private var placement
    @EnvironmentObject private var playbackManager: PlaybackManager
    @EnvironmentObject private var playbackProgressState: PlaybackProgressState
    @Binding var showingNowPlaying: Bool

    var body: some View {
        if placement == .expanded {
            expandedRow
        } else {
            compactRow
        }
    }

    private var compactRow: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    showingNowPlaying = true
                } label: {
                    HStack(spacing: 12) {
                        artwork(size: 44)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(playbackManager.currentTrack?.title ?? "")
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text(playbackManager.currentTrack?.displayArtist ?? "")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("MiniPlayer")
                .buttonStyle(.plain)

                Spacer()

                playPauseButton
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            progressLine
        }
    }

    private var expandedRow: some View {
        HStack(spacing: 12) {
            Button {
                showingNowPlaying = true
            } label: {
                HStack(spacing: 12) {
                    artwork(size: 56)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(playbackManager.currentTrack?.title ?? "")
                            .font(.headline)
                            .lineLimit(1)
                        Text(playbackManager.currentTrack?.displayArtist ?? "")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .accessibilityIdentifier("MiniPlayer")
            .buttonStyle(.plain)

            Spacer()

            playPauseButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// Thin non-interactive progress line under the compact row, like Apple
    /// Music's mini player. The expanded row has no line - Now Playing owns
    /// the scrubber there.
    private var progressLine: some View {
        let duration = playbackManager.currentTrack?.duration ?? 0
        let progress = duration > 0
            ? min(max(playbackProgressState.currentTime / duration, 0), 1)
            : 0

        return GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.18))
                Capsule()
                    .fill(Color.accentColor.opacity(0.75))
                    .frame(width: geometry.size.width * progress)
            }
        }
        .frame(height: 3)
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
        .allowsHitTesting(false)
    }

    private var playPauseButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            playbackManager.togglePlayPause()
        } label: {
            Image(systemName: playbackManager.isPlaying ? Icons.pauseFill : Icons.playFill)
                .font(.system(size: 22))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(playbackManager.isPlaying ? String(localized: "Pause") : String(localized: "Play"))
    }

    private func artwork(size: CGFloat) -> some View {
        Group {
            if let data = playbackManager.currentTrack?.artworkData,
               let image = PlatformImage(data: data) {
                Color.clear
                    .overlay {
                        Image(platformImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }
                    .clipped()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.15))
                    Image(systemName: Icons.musicNote)
                        .foregroundColor(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.15))
    }
}
