//
// ContentView (iOS)
//
// iPhone main window: four tabs per the design spec — Home, Playlists,
// Folders, Search — with the system bottom tab accessory as the mini player.
// The tab bar minimizes on scroll down and the accessory expands with it.
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
    case media
    case folders
    case search
}

struct ContentView: View {
    @EnvironmentObject var playbackManager: PlaybackManager
    @EnvironmentObject var libraryManager: LibraryManager
    @EnvironmentObject var playlistManager: PlaylistManager

    @AppStorage("useArtworkColors")
    private var useArtworkColors = true
    @AppStorage("tintPlaybackControls")
    private var tintPlaybackControls = true

    @Environment(\.colorScheme)
    private var colorScheme

    @State private var selectedTab: IOSSection = .home
    @State private var mediaPath: [LibraryDestination] = []

    @Namespace private var miniPlayerArtworkNamespace
    @State private var nowPlayingDragOffset: CGFloat = 0

    @State private var showingSettings = false
    @State private var showingNowPlaying = false
    @State private var showingQueue = false
    @State private var showingLyrics = false
    @State private var showingFileImporter = false
    @State private var showingPlaylistImporter = false
    @State private var importSummary: String?

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab(value: IOSSection.home) {
                homeTab
            } label: {
                Label {
                    Text(String(localized: "Home"))
                } icon: {
                    SymbolImage(Icons.musicNoteHouse)
                }
            }
            Tab(value: IOSSection.media) {
                mediaTab
            } label: {
                Label {
                    Text(String(localized: "Media"))
                } icon: {
                    SymbolImage(Icons.musicNoteList)
                }
            }
            Tab(String(localized: "Folders"), systemImage: Icons.folder, value: IOSSection.folders) {
                foldersTab
            }
            Tab(String(localized: "Search"), systemImage: Icons.magnifyingGlass, value: IOSSection.search, role: .search) {
                searchTab
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory(isEnabled: playbackManager.currentTrack != nil) {
            MiniPlayerAccessory(
                showingNowPlaying: $showingNowPlaying,
                artworkNamespace: miniPlayerArtworkNamespace
            )
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                SettingsScreen()
            }
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
                nowPlayingCover
                    .background(Color(.systemBackground).ignoresSafeArea())
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(showingNowPlaying)
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.88), value: showingNowPlaying)
        .animation(.spring(response: 0.32, dampingFraction: 0.92), value: nowPlayingDragOffset)
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
        .onReceive(NotificationCenter.default.publisher(for: .showFolderImporter)) { _ in
            showingFileImporter = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .goToLibraryFilter)) { notification in
            if let filterType = notification.userInfo?["filterType"] as? LibraryFilterType,
               let filterValue = notification.userInfo?["filterValue"] as? String {
                selectedTab = .media
                if let item = libraryManager.getLibraryFilterItems(for: filterType)
                    .first(where: { $0.name == filterValue }) {
                    mediaPath = [LibraryDestination.tracks(item)]
                }
            }
        }
    }

    // MARK: - Home Tab

    private var homeTab: some View {
        HomeTabView(showingPlaylistImporter: $showingPlaylistImporter)
    }

    // MARK: - Media Tab

    private var mediaTab: some View {
        MediaLibraryView(
            path: $mediaPath,
            showingSettings: $showingSettings
        )
    }

    // MARK: - Folders Tab

    private var foldersTab: some View {
        FoldersTabView(showingFileImporter: $showingFileImporter)
    }

    // MARK: - Search Tab

    private var searchTab: some View {
        SearchView()
    }

    // MARK: - Now Playing Cover

    private var nowPlayingCover: some View {
        NavigationStack {
            GeometryReader { geometry in
                let artworkSize = min(geometry.size.width - 48, geometry.size.height * 0.44)

                ZStack {
                    nowPlayingContent(artworkSize: artworkSize)

                    if showingQueue || showingLyrics {
                        panelDismissOverlay
                            .transition(.opacity)
                    }

                    if showingQueue {
                        NowPlayingQueuePanel(
                            accentColor: controlAccent,
                            onDismiss: { showingQueue = false }
                        )
                        .environmentObject(playbackManager)
                        .environmentObject(playlistManager)
                        .frame(height: geometry.size.height * 0.7)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    if showingLyrics {
                        NowPlayingLyricsPanel {
                            showingLyrics = false
                        }
                        .environmentObject(playbackManager)
                        .environmentObject(playlistManager)
                        .frame(height: geometry.size.height * 0.72)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .offset(y: max(0, nowPlayingDragOffset))
                .gesture(nowPlayingDismissGesture)
                .animation(.spring(response: 0.38, dampingFraction: 0.86), value: showingQueue)
                .animation(.spring(response: 0.38, dampingFraction: 0.86), value: showingLyrics)
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
        .onAppear {
            playbackManager.setFineProgressSampling(true)
        }
        .onDisappear {
            playbackManager.setFineProgressSampling(false)
        }
    }

    /// Pulling the Now Playing overlay down collapses it. The cover follows
    /// the finger; past the threshold it dismisses, otherwise it springs back.
    private var nowPlayingDismissGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard !showingQueue, !showingLyrics else { return }
                nowPlayingDragOffset = max(0, value.translation.height)
            }
            .onEnded { value in
                if value.translation.height > 80 || value.predictedEndTranslation.height > 160 {
                    showingNowPlaying = false
                }
                nowPlayingDragOffset = 0
            }
    }

    private func nowPlayingContent(artworkSize: CGFloat) -> some View {
        VStack(spacing: 16) {
            Spacer(minLength: 8)

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
                    SymbolImage(Icons.customLyrics)
                        .font(.system(size: 18))
                        .foregroundColor(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .disabled(playbackManager.currentTrack == nil)
                .accessibilityLabel(String(localized: "Lyrics"))

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
                .accessibilityLabel(String(localized: "Queue"))
            }
            .padding(.top, 2)

            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 8)
    }

    /// Transparent layer over the Now Playing content while a panel is up: a
    /// tap anywhere on the artwork area dismisses the panel.
    private var panelDismissOverlay: some View {
        Color.black.opacity(0.0001)
            .contentShape(Rectangle())
            .onTapGesture {
                showingQueue = false
                showingLyrics = false
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
        .matchedGeometryEffect(id: MiniPlayerArtwork.morphID, in: miniPlayerArtworkNamespace, isSource: false)
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

/// The artwork identity shared between the mini player row and the Now
/// Playing cover, so the cover can morph out of the row.
private enum MiniPlayerArtwork {
    static let morphID = "miniPlayerArtwork"
}

private struct MiniPlayerAccessory: View {
    @Environment(\.tabViewBottomAccessoryPlacement)
    private var placement
    @EnvironmentObject private var playbackManager: PlaybackManager
    @EnvironmentObject private var playbackProgressState: PlaybackProgressState
    @Binding var showingNowPlaying: Bool
    var artworkNamespace: Namespace.ID

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
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.15))
        .matchedGeometryEffect(
            id: MiniPlayerArtwork.morphID,
            in: artworkNamespace,
            isSource: !showingNowPlaying
        )
    }
}
