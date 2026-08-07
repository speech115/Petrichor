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
                            isCurrent: isCurrent(track),
                            isPlaying: isCurrent(track) && playbackManager.isPlaying,
                            onPlay: { play(track) }
                        )
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(LibraryFilterType.artists.localizedDisplay(artistName))
        .navigationBarTitleDisplayMode(.large)
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
        VStack(spacing: 12) {
            photo
                .frame(width: 180, height: 180)
                .padding(.top, 16)

            if let bio, !bio.isEmpty {
                Text(bio)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            PlayShuffleRow(
                onPlay: playAll,
                onShuffle: shuffleAll,
                playDisabled: tracks.isEmpty
            )
            .padding(.top, 4)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    private var photo: some View {
        Group {
            if let photoData, let image = UIImage(data: photoData) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
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
        Group {
            if let artworkData = album.artworkThumbnail ?? album.artworkData, let image = UIImage(data: artworkData) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.12))
                    Image(systemName: Icons.musicNote)
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func albumSubtitle(_ album: AlbumEntity) -> String {
        let year = LibraryFilterType.years.localizedDisplay(album.year ?? "")
        if !year.isEmpty, year != LibraryFilterType.years.localizedUnknownPlaceholder {
            return "\(year) • \(String(localized: "\(album.trackCount) songs"))"
        }
        return String(localized: "\(album.trackCount) songs")
    }

    // MARK: - Loading

    private func isCurrent(_ track: Track) -> Bool {
        guard let currentTrack = playbackManager.currentTrack else { return false }
        if let currentId = currentTrack.trackId, let trackId = track.trackId {
            return currentId == trackId
        }
        return currentTrack.url.path == track.url.path
    }

    private func play(_ track: Track) {
        playlistManager.playTrack(track, fromTracks: tracks)
        playlistManager.currentQueueSource = .library
    }

    private func playAll() {
        guard let first = tracks.first else { return }
        playlistManager.playTrack(first, fromTracks: tracks)
        playlistManager.currentQueueSource = .library
    }

    private func shuffleAll() {
        let shuffled = tracks.shuffled()
        guard let first = shuffled.first else { return }
        playlistManager.playTrack(first, fromTracks: shuffled)
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
        let databaseManager = libraryManager.databaseManager

        let loaded = await Task.detached(priority: .userInitiated) {
            var tracks = libraryManager.databaseManager.getTracksForArtistEntity(name)
            // Row thumbnails; the photo header keeps the full artwork.
            databaseManager.populateAlbumArtworkThumbnailsForTracks(&tracks)
            let info = libraryManager.databaseManager.getArtistArtworkAndBio(for: name)
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
