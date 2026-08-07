//
// AlbumPage (iOS)
//
// Album detail page: large artwork, artist and year, and the album's tracks
// in disc/track order with track numbers. One action plays the whole album.
//

import SwiftUI
import UIKit

struct AlbumPage: View {
    @EnvironmentObject private var libraryManager: LibraryManager
    @EnvironmentObject private var playbackManager: PlaybackManager
    @EnvironmentObject private var playlistManager: PlaylistManager

    let album: AlbumEntity

    @State private var tracks: [Track] = []
    @State private var loadTask: Task<Void, Never>?

    var body: some View {
        List {
            Section {
                header
                    .frame(maxWidth: .infinity)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
            }

            ForEach(trackSections) { section in
                Section {
                    ForEach(section.tracks) { track in
                        trackRow(track)
                    }
                } header: {
                    if let title = section.title {
                        Text(title)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(album.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: album.id) {
            await load()
        }
        .onChange(of: libraryManager.tracks.count) { _, _ in
            scheduleLoad()
        }
        .onDisappear {
            loadTask?.cancel()
        }
        .overlay {
            if tracks.isEmpty, libraryManager.shouldShowMainUI {
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
            artwork
                .frame(width: 240, height: 240)
                .padding(.top, 16)

            Text(album.displayName)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)

            if let artistName = album.artistName, !artistName.isEmpty {
                Text(artistName)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Text(subtitle)
                .font(.subheadline)
                .foregroundColor(.secondary)

            Button(action: playAll) {
                Label(String(localized: "Play"), systemImage: Icons.playFill)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(tracks.isEmpty)
            .padding(.top, 4)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    private var artwork: some View {
        Group {
            if let artworkData = album.artworkData, let image = UIImage(data: artworkData) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.secondary.opacity(0.15))
                    Image(systemName: Icons.musicNote)
                        .font(.system(size: 60, weight: .light))
                        .foregroundColor(.secondary)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.2), radius: 16, y: 6)
    }

    private var subtitle: String {
        let year = LibraryFilterType.years.localizedDisplay(album.year ?? "")
        if !year.isEmpty, year != LibraryFilterType.years.localizedUnknownPlaceholder {
            return "\(year) • \(String(localized: "\(album.trackCount) songs"))"
        }
        return String(localized: "\(album.trackCount) songs")
    }

    // MARK: - Track Sections

    private func trackRow(_ track: Track) -> some View {
        HStack(spacing: 12) {
            trackNumber(track)
                .frame(width: 28, alignment: .trailing)

            TrackRow(
                track: track,
                isCurrent: isCurrent(track),
                isPlaying: isCurrent(track) && playbackManager.isPlaying,
                onPlay: { play(track) }
            )
        }
    }

    private func trackNumber(_ track: Track) -> some View {
        Text(track.trackNumber.map(String.init) ?? "")
            .font(.body)
            .monospacedDigit()
            .foregroundColor(.secondary)
    }

    private var trackSections: [TrackSection] {
        let discs = Dictionary(grouping: tracks, by: { $0.discNumber ?? 1 })
            .map { TrackSection(disc: $0.key, tracks: $0.value) }
            .sorted { ($0.disc ?? 1) < ($1.disc ?? 1) }
        if discs.count > 1 {
            return discs
        }
        return [TrackSection(disc: nil, tracks: tracks)]
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

    private func scheduleLoad() {
        loadTask?.cancel()
        loadTask = Task {
            await load()
        }
    }

    private func load() async {
        let album = album
        let libraryManager = libraryManager
        let databaseManager = libraryManager.databaseManager

        let loaded = await Task.detached(priority: .userInitiated) {
            var tracks = libraryManager.databaseManager.getTracksForAlbumEntity(album)
            // Row thumbnails; the header keeps the full artwork from `album`.
            databaseManager.populateAlbumArtworkThumbnailsForTracks(&tracks)
            return tracks
        }.value

        guard !Task.isCancelled else { return }
        tracks = loaded
    }
}

private struct TrackSection: Identifiable {
    let disc: Int?
    let tracks: [Track]

    var id: String { disc.map { "disc-\($0)" } ?? "tracks" }

    var title: String? {
        disc.map { String(localized: "Disc \($0)") }
    }
}
