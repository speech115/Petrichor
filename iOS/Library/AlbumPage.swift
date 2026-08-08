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

    var body: some View {
        TrackListScreen(
            identity: AnyHashable(album.id),
            load: { libraryManager.getTracksForAlbum(album) },
            sectioner: Self.discSections,
            header: { tracks in
                header(tracks: tracks)
                    .frame(maxWidth: .infinity)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
            },
            row: { track, context in trackRow(track, context: context) }
        )
        .navigationBarTitleDisplayMode(.inline)
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
            artwork: { artwork.frame(width: 240, height: 240) }
        )
    }

    private var artwork: some View {
        Group {
            if let artworkData = album.artworkData, let image = UIImage(data: artworkData) {
                Color.clear
                    .overlay {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }
                    .clipped()
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
            forDominantColor: album.dominantColors.first,
            enabled: useArtworkColors
        )
    }

    // MARK: - Track Sections

    private func trackRow(_ track: Track, context: [Track]) -> some View {
        HStack(spacing: 12) {
            trackNumber(track)
                .frame(width: 28, alignment: .trailing)

            TrackRow(
                track: track,
                isCurrent: playlistManager.isCurrent(track),
                isPlaying: playlistManager.isCurrent(track) && playbackManager.isPlaying,
                onPlay: { play(track, in: context) }
            )
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
