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
    @EnvironmentObject var libraryManager: LibraryManager
    let playlistManager: PlaylistManager
    let playbackManager: PlaybackManager
    @ObservedObject private var createPlaylistPresentation: PlaylistCreatePresentationObservation
    @ObservedObject private var playbackAvailability: PlaybackAvailabilityObservation

    @State private var selectedTab: IOSSection = .home
    @State private var homePath: [LibraryDestination] = []

    @State private var showingSettings = false
    @State private var showingNowPlaying = false
    @State private var nowPlayingMounted = false
    @State private var showingPlaylistImporter = false
    @State private var importSummary: String?
    @State private var trackInfoTrack: Track?
    /// Incremented every time the Search tab is tapped while Search is already
    /// open. SearchView watches it and raises the keyboard.
    @State private var searchFocusRequest = 0

    init(playlistManager: PlaylistManager, playbackManager: PlaybackManager) {
        self.playlistManager = playlistManager
        self.playbackManager = playbackManager
        createPlaylistPresentation = playlistManager.createPresentationObservation
        playbackAvailability = playbackManager.availabilityObservation
    }

    var body: some View {
        mainInterface
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                SettingsScreen()
            }
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
        // Keep Now Playing in this hierarchy, but let one presentation layer own
        // mounting, drag progress and dismissal. A conditional `.move`
        // transition used to start after NowPlayingScreen had already moved its
        // content, so the cover and the surface visibly travelled in two steps.
        .overlay {
            NowPlayingPresentationLayer(
                isPresented: $showingNowPlaying,
                isMounted: $nowPlayingMounted,
                playbackManager: playbackManager,
                playlistManager: playlistManager
            )
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
                homePath = [destination(for: filterType, item: item)]
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
                showingNowPlaying: $showingNowPlaying
            )
        }
        .environment(\.playerSurfaceCoversContent, nowPlayingMounted)
        .allowsHitTesting(!nowPlayingMounted)
        .accessibilityHidden(nowPlayingMounted)
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

// MARK: - Now Playing Presentation

/// Mounts the player one run-loop turn below the viewport, then moves the
/// entire composited surface as one layer. The same offset is driven by the
/// interactive drag, so releasing a successful dismissal continues from the
/// user's finger instead of starting a second transition from the top.
private struct NowPlayingPresentationLayer: View {
    @Binding var isPresented: Bool
    @Binding var isMounted: Bool
    let playbackManager: PlaybackManager
    let playlistManager: PlaylistManager

    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    @State private var isVisible = false
    @State private var dragOffset: CGFloat = 0
    @State private var lifecycleTask: Task<Void, Never>?

    private var entranceAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.20)
            : .spring(response: 0.30, dampingFraction: 0.94)
    }

    private var exitDuration: Double {
        reduceMotion ? 0.20 : 0.22
    }

    var body: some View {
        GeometryReader { geometry in
            if isMounted {
                NowPlayingScreen(
                    isPresented: $isPresented,
                    presentationDragOffset: $dragOffset,
                    playbackManager: playbackManager,
                    playlistManager: playlistManager
                )
                .offset(y: reduceMotion ? 0 : verticalOffset(in: geometry))
                .opacity(reduceMotion && !isVisible ? 0 : 1)
                .allowsHitTesting(isVisible)
                .accessibilityHidden(!isVisible)
                .accessibilityAddTraits(.isModal)
            }
        }
        .ignoresSafeArea()
        .onChange(of: isPresented, initial: true) { _, presented in
            updatePresentation(presented)
        }
        .onDisappear {
            lifecycleTask?.cancel()
        }
    }

    private func verticalOffset(in geometry: GeometryProxy) -> CGFloat {
        return isVisible ? max(0, dragOffset) : geometry.size.height
    }

    private func updatePresentation(_ presented: Bool) {
        lifecycleTask?.cancel()
        if presented {
            present()
        } else {
            dismiss()
        }
    }

    private func present() {
        dragOffset = 0

        if !isMounted {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                isVisible = false
                isMounted = true
            }
        }

        // The off-screen mounted frame must commit before the entrance begins;
        // otherwise SwiftUI can insert the cached cover at its final position
        // and animate the surrounding hierarchy one frame later.
        lifecycleTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled, isPresented, isMounted else { return }
            withAnimation(entranceAnimation) {
                isVisible = true
            }
        }
    }

    private func dismiss() {
        guard isMounted else { return }

        let duration = exitDuration
        withAnimation(.easeOut(duration: duration)) {
            isVisible = false
        }

        lifecycleTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled, !isPresented else { return }

            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                isMounted = false
                dragOffset = 0
            }
        }
    }
}

// MARK: - Mini Player Accessory

private struct MiniPlayerAccessory: View {
    @Environment(\.tabViewBottomAccessoryPlacement)
    private var placement
    let playbackManager: PlaybackManager
    @ObservedObject private var playbackPresentation: PlaybackPresentationObservation
    private let playbackProgressState: PlaybackProgressState
    @Binding var showingNowPlaying: Bool

    init(playbackManager: PlaybackManager, showingNowPlaying: Binding<Bool>) {
        self.playbackManager = playbackManager
        playbackPresentation = playbackManager.presentationObservation
        playbackProgressState = playbackManager.playbackProgressState
        _showingNowPlaying = showingNowPlaying
    }

    var body: some View {
        let isCompact = placement == .inline

        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    showingNowPlaying = true
                } label: {
                    HStack(spacing: 12) {
                        artwork(size: isCompact ? 44 : 56)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(playbackPresentation.currentTrack?.title ?? "")
                                .font(isCompact ? .subheadline.weight(.semibold) : .headline)
                                .lineLimit(1)
                            Text(playbackPresentation.currentTrack?.displayArtist ?? "")
                                .font(isCompact ? .caption : .subheadline)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        // Cross-fade, not a slide: in a 44pt row a horizontal
                        // move reads as a twitch. The track usually changes on
                        // its own at the end of a song, with nobody's finger on
                        // the screen, so the swap needs a bridge more than the
                        // controls need a direction.
                        .id(playbackPresentation.currentTrack?.id)
                        .transition(.opacity)

                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .animation(
                        .easeInOut(duration: AnimationDuration.standardDuration),
                        value: playbackPresentation.currentTrack?.id
                    )
                }
                .accessibilityIdentifier("MiniPlayer")
                .buttonStyle(.plain)

                playPauseButton
            }
            .padding(.horizontal, 16)
            .padding(.vertical, isCompact ? 8 : 10)

            if isCompact {
                progressLine
                    .frame(height: 3)
                    .padding(.bottom, 6)
            }
        }
    }

    /// Thin non-interactive progress line under the compact row, like Apple
    /// Music's mini player. The expanded row has no line - Now Playing owns
    /// the scrubber there.
    private var progressLine: some View {
        MiniPlayerProgressLine(
            duration: playbackPresentation.currentTrack?.duration ?? 0,
            playbackProgressState: playbackProgressState
        )
    }

    private var playPauseButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            playbackManager.togglePlayPause()
        } label: {
            // The same morph the full player's transport uses. Without it the
            // icon snapped here and slid there, which shows the moment someone
            // pauses in the mini player and opens the player right after.
            Image(systemName: playbackPresentation.isPlaying ? Icons.pauseFill : Icons.playFill)
                .contentTransition(.symbolEffect(.replace.offUp))
                // The mini player is a fixed 44 pt row: the glyph scales with
                // Dynamic Type but stays inside its button.
                .font(.system(size: min(playPauseIconSize, 30)))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(playbackPresentation.isPlaying ? String(localized: "Pause") : String(localized: "Play"))
    }

    private func artwork(size: CGFloat) -> some View {
        ArtworkTile(
            data: playbackPresentation.currentTrack?.displayArtwork,
            cacheKey: playbackPresentation.currentTrack.map { "now-playing-\($0.id)" },
            cornerRadius: size * 0.15,
            maxPixelSize: 180,
            // The title and artist texts in the same row name the track; the
            // cover is decoration for VoiceOver.
            isDecorative: true
        )
        .frame(width: size, height: size)
    }

    @ScaledMetric(relativeTo: .title2) private var playPauseIconSize: CGFloat = 22
}

private struct MiniPlayerProgressLine: View {
    let duration: Double
    @ObservedObject var playbackProgressState: PlaybackProgressState

    var body: some View {
        let progress = duration > 0
            ? min(max(playbackProgressState.currentTime / duration, 0), 1)
            : 0

        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.18))
                Capsule()
                    .fill(Color.accentColor.opacity(0.75))
                    .frame(width: geometry.size.width * progress)
                    // Same tween as the player's scrubber: the playhead lands
                    // once per sample, the line has to cross the gap itself.
                    .animation(
                        .linear(duration: playbackProgressState.sampleInterval),
                        value: progress
                    )
            }
        }
        .frame(height: 3)
        .padding(.horizontal, 16)
        .allowsHitTesting(false)
    }
}
