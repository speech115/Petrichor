//
// ArtistPage (iOS)
//
// Artist detail page: photo and bio from the database cache (populated
// offline-capable by ArtistBioManager), the artist's albums, and all of their
// tracks. One action plays the whole discography. Offline there is no error:
// whatever the cache holds is shown, the rest stays empty.
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
    @State private var headerTint: Color?
    @State private var bio: String?
    @State private var loadTask: Task<Void, Never>?

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
                Section(String(localized: "Tracks")) {
                    ForEach(tracks) { track in
                        TrackRow(
                            track: track,
                            onPlay: { play(track) },
                            playlistManager: playlistManager,
                            libraryManager: libraryManager,
                            playbackManager: playbackManager
                        )
                        .equatable()
                    }
                }
            }

            if !albums.isEmpty {
                Section(String(localized: "Albums")) {
                    AlbumCarousel(albums: albums, zoomNamespace: zoomNamespace)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.plain)
        .detailPageWash(headerTint)
        .navigationBarTitleDisplayMode(.inline)
        .detailHeaderTint(cacheID: artistName, imageData: photoData, tint: $headerTint)
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

    private var header: some View {
        DetailHeader(
            onPlay: playAll,
            onShuffle: shuffleAll,
            playDisabled: tracks.isEmpty,
            title: LibraryFilterType.artists.localizedDisplay(artistName),
            subtitle: bio,
            artwork: { photo.frame(width: 180, height: 180) }
        )
    }

    private var photo: some View {
        Group {
            if let photoData {
                ArtworkTile(
                    data: photoData,
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
