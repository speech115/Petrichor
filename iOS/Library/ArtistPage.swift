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

    @AppStorage("useArtworkColors")
    private var useArtworkColors = true

    let artistName: String

    @State private var tracks: [Track] = []
    @State private var albums: [AlbumEntity] = []
    @State private var photoData: Data?
    @State private var bio: String?
    @State private var loadTask: Task<Void, Never>?

    var body: some View {
        List {
            Section {
                header
                    .frame(maxWidth: .infinity)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
            }

            if !albums.isEmpty {
                Section(String(localized: "Albums")) {
                    ForEach(albums) { album in
                        NavigationLink(value: LibraryDestination.album(album)) {
                            albumRow(album)
                        }
                    }
                }
            }

            if !tracks.isEmpty {
                Section(String(localized: "Tracks")) {
                    ForEach(tracks) { track in
                        TrackRow(
                            track: track,
                            isCurrent: playlistManager.isCurrent(track),
                            isPlaying: playlistManager.isCurrent(track) && playbackManager.isPlaying,
                            onPlay: { play(track) }
                        )
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: artistName) {
            await load()
        }
        .onChange(of: libraryManager.tracks.count) { _, _ in
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
            tint: headerTint,
            artwork: { photo.frame(width: 180, height: 180) }
        )
    }

    private var headerTint: Color? {
        NowPlayingArtwork.headerTint(
            forDominantColor: photoData.flatMap {
                ImageUtils.cachedDominantColors(id: artistName, imageData: $0).first
            },
            enabled: useArtworkColors
        )
    }

    private var photo: some View {
        Group {
            if let photoData, let image = UIImage(data: photoData) {
                Color.clear
                    .overlay {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }
                    .clipped()
            } else {
                ZStack {
                    Circle()
                        .fill(Color.secondary.opacity(0.15))
                    Text(artistName.artistInitials)
                        .font(.system(size: 56, weight: .medium, design: .rounded))
                        .foregroundColor(.secondary)
                }
            }
        }
        .clipShape(Circle())
    }

    // MARK: - Album Row

    private func albumRow(_ album: AlbumEntity) -> some View {
        HStack(spacing: 12) {
            albumArtwork(album)
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(album.displayName)
                    .lineLimit(1)
                Text(albumSubtitle(album))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func albumArtwork(_ album: AlbumEntity) -> some View {
        ArtworkTile(data: album.displayArtwork, cacheKey: album.albumId.map(String.init))
            .frame(width: 44, height: 44)
    }

    private func albumSubtitle(_ album: AlbumEntity) -> String {
        let year = LibraryFilterType.years.localizedDisplay(album.year ?? "")
        if !year.isEmpty, year != LibraryFilterType.years.localizedUnknownPlaceholder {
            return "\(year) • \(String(localized: "\(album.trackCount) songs"))"
        }
        return String(localized: "\(album.trackCount) songs")
    }

    // MARK: - Loading

    private func play(_ track: Track) {
        playlistManager.play(track, source: .library(context: tracks))
    }

    private func playAll() {
        guard let first = tracks.first else { return }
        playlistManager.play(first, source: .library(context: tracks))
    }

    private func shuffleAll() {
        playlistManager.playTrackShuffled(tracks)
        playlistManager.currentQueueSource = .library
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
            let albums = Self.albums(from: tracks)
            return (tracks: tracks, albums: albums, photo: info.artworkData, bio: info.bio)
        }.value

        guard !Task.isCancelled else { return }
        tracks = loaded.tracks
        albums = loaded.albums
        photoData = loaded.photo
        bio = loaded.bio
    }

    private static nonisolated func albums(from tracks: [Track]) -> [AlbumEntity] {
        let grouped = Dictionary(grouping: tracks) { track in
            track.albumId.map { "album:\($0)" } ?? "name:\(track.album)|\(track.albumArtist ?? "")"
        }
        return grouped.values
            .map { groupedTracks in
                guard let first = groupedTracks.first else {
                    return AlbumEntity(name: "", trackCount: 0)
                }
                return AlbumEntity(
                    name: first.album,
                    trackCount: groupedTracks.count,
                    artworkData: groupedTracks.first { $0.albumArtworkData != nil }?.albumArtworkData,
                    artworkThumbnail: groupedTracks.first { $0.albumArtworkThumbnail != nil }?.albumArtworkThumbnail,
                    albumId: first.albumId,
                    year: first.year,
                    artistName: first.albumArtist
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
