//
// ArtistPage (iOS)
//
// Artist detail page in Apple Music's layout: the page filled with the
// photo's color, photo and name, then Info / Play / Shuffle. The bio (from the
// database cache populated offline-capable by ArtistBioManager) opens from
// Info instead of pushing the songs off screen. "Top Songs" shows the five
// most played and links to all of them; the albums follow as a shelf. Play
// covers the whole discography. Offline there is no error: whatever the cache
// holds is shown, the rest stays empty.
//

import SwiftUI
import UIKit

struct ArtistPage: View {
    @EnvironmentObject private var libraryManager: LibraryManager
    @EnvironmentObject private var playbackManager: PlaybackManager
    @EnvironmentObject private var playlistManager: PlaylistManager

    let artistName: String
    let zoomNamespace: Namespace.ID

    @State private var tracks: [Track] = []
    @State private var albums: [AlbumEntity] = []
    @State private var photoData: Data?
    /// Small photo for the page color, read on its own so the color does not
    /// wait for the discography query that brings the full photo.
    @State private var tintSource: Data?
    @State private var headerTint: Color?
    @State private var bio: String?
    @State private var loadTask: Task<Void, Never>?
    @State private var showingBio = false

    private static let topSongCount = 5

    var body: some View {
        List {
            Section {
                header
                    .frame(maxWidth: .infinity)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            if !tracks.isEmpty {
                Section {
                    ForEach(topSongs) { track in
                        TrackRow(
                            track: track,
                            onPlay: { play(track) },
                            playlistManager: playlistManager,
                            libraryManager: libraryManager,
                            playbackManager: playbackManager
                        )
                        .equatable()
                        // The page fill shows through, as on the album page.
                        .listRowBackground(Color.clear)
                    }
                } header: {
                    topSongsHeader
                }
            }

            if !albums.isEmpty {
                Section {
                    AlbumCarousel(albums: albums, zoomNamespace: zoomNamespace)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                } header: {
                    sectionTitle(Text(String(localized: "Albums")))
                }
            }
        }
        .listStyle(.plain)
        .detailPageFill(headerTint)
        .sheet(isPresented: $showingBio) {
            bioSheet
        }
        .navigationBarTitleDisplayMode(.inline)
        .detailHeaderTint(cacheID: artistName, imageData: tintSource ?? photoData, tint: $headerTint)
        .task(id: artistName) {
            let database = libraryManager.databaseManager
            let name = artistName
            tintSource = await Task.detached(priority: .userInitiated) {
                database.getArtistArtworkThumbnail(name: name)
            }.value
        }
        .task(id: artistName) {
            await load()
        }
        .onChange(of: libraryManager.libraryRevision) { _, _ in
            scheduleLoad()
        }
        .onDisappear {
            loadTask?.cancel()
        }
        .overlay {
            if tracks.isEmpty, albums.isEmpty, libraryManager.shouldShowMainUI {
                ContentUnavailableView(
                    String(localized: "No Tracks"),
                    systemImage: Icons.musicNote
                )
            }
        }
    }

    // MARK: - Header

    private var displayName: String {
        LibraryFilterType.artists.localizedDisplay(artistName)
    }

    private var header: some View {
        VStack(spacing: 0) {
            photo
                .frame(width: 180, height: 180)
                .padding(.top, 8)

            Text(displayName)
                .font(.largeTitle.weight(.bold))
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .multilineTextAlignment(.center)
                .padding(.top, 16)

            HStack(spacing: 28) {
                Button { showingBio = true } label: {
                    HeroCircleLabel(systemImage: "info", side: 48)
                }
                .buttonStyle(.plain)
                .disabled(bio?.isEmpty ?? true)
                .opacity(bio?.isEmpty ?? true ? 0.4 : 1)
                .accessibilityLabel(String(localized: "Biography"))

                HeroPlayButton(shape: .circle, isDisabled: tracks.isEmpty, action: playAll)

                Button(action: shuffleAll) {
                    HeroCircleLabel(systemImage: Icons.shuffleFill, side: 48)
                }
                .buttonStyle(.plain)
                .disabled(tracks.isEmpty)
                .accessibilityLabel(String(localized: "Shuffle"))
            }
            .padding(.top, 16)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
    }

    /// The five most played, in album order while nothing has been played.
    private var topSongs: [Track] {
        guard tracks.contains(where: { $0.playCount > 0 }) else {
            return Array(tracks.prefix(Self.topSongCount))
        }
        return Array(
            tracks.enumerated()
                .sorted { ($0.element.playCount, -$0.offset) > ($1.element.playCount, -$1.offset) }
                .prefix(Self.topSongCount)
                .map(\.element)
        )
    }

    /// "Top Songs ›", opening every song of the artist when there are more.
    @ViewBuilder
    private var topSongsHeader: some View {
        let title = Text(String(localized: "Top Songs"))
        if tracks.count > Self.topSongCount {
            NavigationLink(
                value: LibraryDestination.tracks(
                    LibraryFilterItem(name: artistName, count: tracks.count, filterType: .artists)
                )
            ) {
                HStack(spacing: 4) {
                    sectionTitle(title)
                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.secondaryText)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            sectionTitle(title)
        }
    }

    private func sectionTitle(_ title: Text) -> some View {
        title
            .font(.title3.weight(.bold))
            // Explicit: a list header otherwise dims its text to secondary.
            .foregroundStyle(Color.primary)
            .textCase(nil)
    }

    private var bioSheet: some View {
        NavigationStack {
            ScrollView {
                Text(bio ?? "")
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            .navigationTitle(displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) { showingBio = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var photo: some View {
        Group {
            // The thumbnail fills in while the discography query runs.
            if let photo = photoData ?? tintSource {
                ArtworkTile(
                    data: photo,
                    cacheKey: ArtworkCacheKey.artistDetail(artistName),
                    cornerRadius: 90,
                    maxPixelSize: 720
                )
            } else {
                ZStack {
                    Circle()
                        .fill(Color.secondary.opacity(0.15))
                    Text(artistName.artistInitials)
                        // Inside the fixed 180 pt photo circle, so the
                        // initials scale with Dynamic Type but stay capped.
                        .font(.system(size: min(initialsSize, 120), weight: .medium, design: .rounded))
                        .foregroundColor(.secondary)
                }
            }
        }
        .clipShape(Circle())
        // The artist name sits in the header right below; the photo is
        // decoration for VoiceOver.
        .accessibilityHidden(true)
    }

    @ScaledMetric(relativeTo: .largeTitle) private var initialsSize: CGFloat = 56

    // MARK: - Loading

    private func play(_ track: Track) {
        playlistManager.play(track, source: .library(context: tracks))
    }

    private func playAll() {
        playlistManager.playLibrary(tracks)
    }

    private func shuffleAll() {
        playlistManager.shuffleLibrary(tracks)
    }

    private func scheduleLoad() {
        loadTask?.cancel()
        loadTask = Task {
            await load()
        }
    }

    private func load() async {
        let name = artistName
        let libraryManager = libraryManager

        let loaded = await Task.detached(priority: .userInitiated) {
            let tracks = libraryManager.getTracksForArtist(name)
            // Row thumbnails; the photo header keeps the full artwork.
            let info = libraryManager.getArtistArtworkAndBio(for: name)
            let albums = AlbumCarousel.albums(from: tracks)
            return (tracks: tracks, albums: albums, photo: info.artworkData, bio: info.bio)
        }.value

        guard !Task.isCancelled else { return }
        tracks = loaded.tracks
        albums = loaded.albums
        photoData = loaded.photo
        bio = loaded.bio
    }
}
