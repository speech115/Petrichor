//
// PlaylistsTabView (iOS)
//
// Root of the Playlists tab: one section per import source — Spotify, VK,
// Яндекс Музыка — and then everything the library owns itself, Favorites
// first. The source sections exist because the library is a pile of exports
// from three services and a flat alphabetical list buries that; grouping is
// what the names already encode. See `PlaylistSource`.
//
// Of the smart playlists only Favorites appears here. Both Top 25s are
// queries the library answers rather than lists the owner keeps: Recently
// Played is already Home's shelf, and Most Played is already a Home row.
//
// The service's mark rides in the section header, once, next to its name;
// rows carry a 48 pt cover — the playlist's own artwork when it has one,
// otherwise the 2x2 preview mosaic — plus name and track count.
//
// Creating and importing (M3U) share the menu beside the settings gear; the
// top left belongs to the title. A tap opens the playlist's detail screen.
//

import SwiftUI

struct PlaylistsTabView: View {
    @EnvironmentObject private var libraryManager: LibraryManager
    let playlistManager: PlaylistManager
    let playbackManager: PlaybackManager
    @ObservedObject private var playlistCatalog: PlaylistCatalogObservation

    @Binding var showingPlaylistImporter: Bool
    @Binding var showingSettings: Bool

    @State private var playlistPreviews: [UUID: [Track]] = [:]
    @State private var loadTask: Task<Void, Never>?

    init(
        playlistManager: PlaylistManager,
        playbackManager: PlaybackManager,
        showingPlaylistImporter: Binding<Bool>,
        showingSettings: Binding<Bool>
    ) {
        self.playlistManager = playlistManager
        self.playbackManager = playbackManager
        playlistCatalog = playlistManager.catalogObservation
        _showingPlaylistImporter = showingPlaylistImporter
        _showingSettings = showingSettings
    }

    private static let previewLimit = 4

    var body: some View {
        NavigationStack {
            List {
                ForEach(PlaylistSource.allCases, id: \.title) { source in
                    let playlists = sourcePlaylists[source] ?? []
                    if !playlists.isEmpty {
                        Section {
                            playlistRows(playlists)
                        } header: {
                            sourceHeader(source)
                        }
                    }
                }
                if !ownPlaylists.isEmpty {
                    Section(String(localized: "My Playlists")) {
                        playlistRows(ownPlaylists)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .rootTitle(String(localized: "Playlists"))
            .navigationDestination(for: UUID.self) { playlistID in
                PlaylistDetailScreen(
                    playlistID: playlistID,
                    playlistManager: playlistManager,
                    playbackManager: playbackManager,
                    playlistCatalog: playlistCatalog
                )
            }
            // The top-left is the title's, as it is in every other tab, so
            // creating and importing share one menu on the right beside the
            // gear rather than each claiming a corner.
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            playlistManager.showCreatePlaylistModal()
                        } label: {
                            Label(String(localized: "New Playlist"), systemImage: "plus")
                        }
                        Button {
                            showingPlaylistImporter = true
                        } label: {
                            Label(String(localized: "Import Playlists"), systemImage: "square.and.arrow.down")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel(String(localized: "Playlist menu"))
                }
                SettingsToolbarItem(showingSettings: $showingSettings)
            }
            .overlay {
                if isEmpty, libraryManager.shouldShowMainUI {
                    ContentUnavailableView(
                        String(localized: "No Music"),
                        systemImage: Icons.musicNoteList,
                        description: Text(String(localized: "Add music files to the Petrichor folder in the Files app"))
                    )
                }
            }
            .onAppear(perform: scheduleLoad)
            .onChange(of: playlistCatalog.playlists.count) { _, _ in
                scheduleLoad()
            }
            .onDisappear {
                loadTask?.cancel()
            }
        }
    }

    private var isEmpty: Bool {
        playlistCatalog.playlists.isEmpty
    }

    /// Smart playlists in the manager's order, then user playlists sorted by
    /// their stored name — which keeps the export numbering as the order
    /// inside each source section even though the numbers are not shown.
    private var displayPlaylists: [Playlist] {
        let smart = playlistCatalog.playlists.filter { $0.type == .smart }
        let regular = playlistCatalog.playlists
            .filter { $0.type == .regular && !PlaylistSource.isHidden($0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return smart + regular
    }

    /// Favorites, the one smart playlist this tab shows.
    private var favorites: [Playlist] {
        displayPlaylists.filter { $0.type == .smart && $0.name == DefaultPlaylists.favorites }
    }

    /// Each source's playlists: the pinned ones first in their pinned order,
    /// then whatever else matched the service by name, in the name order
    /// `displayPlaylists` already established. Unpinned exports are appended
    /// rather than dropped — a playlist that fell out of the pinned list is
    /// still in the library and still has to be reachable.
    private var sourcePlaylists: [PlaylistSource: [Playlist]] {
        Dictionary(grouping: displayPlaylists.compactMap { playlist in
            PlaylistSource.of(playlist).map { (source: $0, playlist: playlist) }
        }, by: \.source).mapValues { pairs in
            pairs.map(\.playlist).enumerated().sorted { lhs, rhs in
                let source = PlaylistSource.of(lhs.element)
                let left = source?.pinnedIndex(of: lhs.element) ?? Int.max
                let right = source?.pinnedIndex(of: rhs.element) ?? Int.max
                return left == right ? lhs.offset < rhs.offset : left < right
            }
            .map(\.element)
        }
    }

    /// What the library owns rather than imported: Favorites, then the regular
    /// playlists that belong to no import source. Favorites leads because it is
    /// the one list here that fills itself and the only one worth reaching for
    /// twice a day; the exports sit above because they are what the sections
    /// are for.
    private var ownPlaylists: [Playlist] {
        favorites + displayPlaylists.filter { $0.type == .regular && PlaylistSource.of($0) == nil }
    }

    /// The service's mark belongs to the section, not to its rows: repeated
    /// down a list under a header that already names the service it is pure
    /// noise, and it costs every row the cover mosaic that tells them apart.
    private func sourceHeader(_ source: PlaylistSource) -> some View {
        HStack(spacing: 7) {
            PlaylistSourceLogo(source: source, cornerRadius: 5)
                .frame(width: 20, height: 20)
            Text(source.title)
        }
        .accessibilityElement(children: .combine)
    }

    private func playlistRows(_ playlists: [Playlist]) -> some View {
        ForEach(playlists) { playlist in
            NavigationLink(value: playlist.id) {
                PlaylistRowView(
                    playlist: playlist,
                    previewTracks: playlistPreviews[playlist.id] ?? []
                )
            }
            // Vertical insets are not decoration: at zero the covers of
            // consecutive rows touch, and a column of identical service marks
            // reads as one tall block instead of three rows.
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        }
    }

    // MARK: - Loading

    private func scheduleLoad() {
        loadTask?.cancel()
        loadTask = Task {
            await load()
        }
    }

    private func load() async {
        if playlistManager.playlists.isEmpty {
            playlistManager.loadPlaylists()
        }

        let libraryManager = libraryManager
        let playlists = displayPlaylists
        let previewLimit = Self.previewLimit

        let previews = await Task.detached(priority: .userInitiated) {
            Dictionary(
                uniqueKeysWithValues: playlists.map {
                    ($0.id, libraryManager.getPlaylistPreviewTracks($0, limit: previewLimit))
                }
            )
        }.value

        guard !Task.isCancelled else { return }
        playlistPreviews = previews
    }
}

// MARK: - Playlist Row

/// The row: cover (own artwork, service mark or preview mosaic), name, count.
private struct PlaylistRowView: View {
    let playlist: Playlist
    let previewTracks: [Track]

    var body: some View {
        HStack(spacing: 12) {
            artwork
                .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 2) {
                Text(PlaylistDisplay.name(for: playlist))
                    .font(.body)
                    .lineLimit(1)
                Text(String(localized: "\(playlist.trackCount) songs"))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(height: 48)
    }

    /// Cover precedence: the playlist's own artwork, then the cover its pinned
    /// entry gives it, then the 2x2 preview mosaic. Which service a row came
    /// from is the section header's job, not the row's.
    @ViewBuilder
    private var artwork: some View {
        Group {
            if playlist.coverArtworkData != nil {
                ArtworkTile(data: playlist.coverArtworkData, cacheKey: "playlist-\(playlist.id)", cornerRadius: 8, iconSize: 20)
            } else if let cover = PlaylistCover.of(playlist) {
                PlaylistCoverView(cover: cover)
            } else {
                ArtworkMosaic(covers: PlaylistCover.mosaicCovers(from: previewTracks))
            }
        }
        // The row's name and count read it; the cover is decoration.
        .accessibilityHidden(true)
    }
}
