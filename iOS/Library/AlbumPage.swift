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

    @AppStorage("useArtworkColors")
    private var useArtworkColors = true

    let album: AlbumEntity
    @State private var artworkData: Data?
    @State private var headerDominantColor: PlatformColor?

    var body: some View {
        TrackListScreen(
            identity: AnyHashable(album.id),
            load: { [libraryManager, album] in libraryManager.getTracksForAlbum(album) },
            sectioner: Self.discSections,
            header: { tracks in
                header(tracks: tracks)
                    .frame(maxWidth: .infinity)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            },
            row: { track, context in trackRow(track, context: context) }
        )
        .detailPageWash(headerTint)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: album.albumId) {
            if let existing = album.artworkData {
                artworkData = existing
                return
            }
            let database = libraryManager.databaseManager
            let albumId = album.albumId
            artworkData = await Task.detached(priority: .utility) {
                database.getArtworkData(albumId: albumId, trackId: nil)
            }.value
        }
        .task(id: tintTaskID) {
            await updateHeaderTint()
        }
    }

    /// Disc sections with "Disc N" headers, or one headerless section when the
    /// album is a single disc.
    private static func discSections(_ tracks: [Track]) -> [IndexedSection<Track>] {
        let discs = Dictionary(grouping: tracks, by: { $0.discNumber ?? 1 })
            .sorted { $0.key < $1.key }
        if discs.count > 1 {
            return discs.map { IndexedSection(key: String(localized: "Disc \($0.key)"), items: $0.value) }
        }
        return [IndexedSection(key: "", items: tracks)]
    }

    // MARK: - Header

    private func header(tracks: [Track]) -> some View {
        DetailHeader(
            onPlay: { playAll(tracks) },
            onShuffle: { shuffleAll(tracks) },
            playDisabled: tracks.isEmpty,
            title: album.displayName,
            subtitle: subtitle,
            tint: headerTint,
            artwork: { artwork.frame(width: 280, height: 280) }
        )
    }

    private var artwork: some View {
        ArtworkTile(
            data: artworkData ?? album.displayArtwork,
            cacheKey: album.albumId.map { "album-detail-\($0)" },
            cornerRadius: 12,
            iconSize: 60,
            maxPixelSize: 720,
            // The header names the album under the cover; decoration only.
        )
        .shadow(color: .black.opacity(0.2), radius: 16, y: 6)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let artistName = album.artistName, !artistName.isEmpty {
            parts.append(LibraryFilterType.artists.localizedDisplay(artistName))
        }
        let year = LibraryFilterType.years.localizedDisplay(album.year ?? "")
        if !year.isEmpty, year != LibraryFilterType.years.localizedUnknownPlaceholder {
            parts.append(year)
        }
        parts.append(String(localized: "\(album.trackCount) songs"))
        return parts.joined(separator: " • ")
    }

    private var headerTint: Color? {
        NowPlayingArtwork.headerTint(
            forDominantColor: headerDominantColor,
            enabled: useArtworkColors
        )
    }

    private var tintTaskID: String {
        "\(album.id)-\(artworkData?.count ?? 0)-\(useArtworkColors)"
    }

    private func updateHeaderTint() async {
        guard useArtworkColors, let artworkData else {
            headerDominantColor = nil
            return
        }
        let cacheID = album.id.uuidString
        if let cached = ImageUtils.cachedDominantColorsIfAvailable(id: cacheID, imageData: artworkData)?.first {
            headerDominantColor = cached
            return
        }
        try? await Task.sleep(for: .milliseconds(320))
        guard !Task.isCancelled else { return }
        let dominant = await ImageUtils.cachedDominantColors(id: cacheID, imageData: artworkData).first
        guard !Task.isCancelled else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            headerDominantColor = dominant
        }
    }

    // MARK: - Track Sections

    private func trackRow(_ track: Track, context: [Track]) -> some View {
        HStack(spacing: 12) {
            trackNumber(track)
                .frame(width: 28, alignment: .trailing)

            TrackRow(
                track: track,
                onPlay: { play(track, in: context) },
                playlistManager: playlistManager,
                libraryManager: libraryManager,
                playbackManager: playbackManager
            )
            .equatable()
        }
    }

    private func trackNumber(_ track: Track) -> some View {
        Text(track.trackNumber.map(String.init) ?? "")
            .font(.body)
            .monospacedDigit()
            .foregroundColor(.secondary)
    }

    // MARK: - Playback

    private func play(_ track: Track, in context: [Track]) {
        playlistManager.play(track, source: .library(context: context))
    }

    private func playAll(_ tracks: [Track]) {
        guard let first = tracks.first else { return }
        playlistManager.play(first, source: .library(context: tracks))
    }

    private func shuffleAll(_ tracks: [Track]) {
        playlistManager.playTrackShuffled(tracks)
        playlistManager.currentQueueSource = .library
    }
}
