//
// AlbumPage (iOS)
//
// Album detail page: large artwork, artist and year, and the album's tracks
// in disc/track order with track numbers. One action plays the whole album.
// Below the tracks, as in Apple Music: year, song count and running time,
// then a shelf of the artist's other albums.
//

import SwiftUI
import UIKit

struct AlbumPage: View {
    @EnvironmentObject private var libraryManager: LibraryManager
    @EnvironmentObject private var playbackManager: PlaybackManager
    @EnvironmentObject private var playlistManager: PlaylistManager

    let album: AlbumEntity
    let zoomNamespace: Namespace.ID
    @State private var artworkData: Data?
    @State private var headerTint: Color?
    @State private var moreByArtist: [AlbumEntity] = []

    var body: some View {
        TrackListScreen(
            identity: AnyHashable(album.id),
            load: { [libraryManager, album] in libraryManager.getTracksForAlbum(album) },
            sectioner: { Self.discSections($0) },
            usesPlainStyle: true,
            footer: { tracks in AnyView(footer(tracks: tracks)) },
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
        .detailHeaderTint(cacheID: tintCacheID, imageData: artworkData, tint: $headerTint)
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
        .task(id: album.id) {
            await loadMoreByArtist()
        }
    }

    /// Disc sections with "Disc N" headers, or one headerless section when the
    /// album is a single disc.
    nonisolated private static func discSections(_ tracks: [Track]) -> [IndexedSection<Track>] {
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
            artwork: { artwork.frame(width: 280, height: 280) }
        )
    }

    private var artwork: some View {
        ArtworkTile(
            data: artworkData ?? album.displayArtwork,
            cacheKey: album.albumId.map(ArtworkCacheKey.albumDetail),
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
        if let year = TrackCountText.year(album) {
            parts.append(year)
        }
        parts.append(TrackCountText.songs(album.trackCount))
        return parts.joined(separator: " • ")
    }

    /// Matches the Now Playing color-cache key ("album-<id>") so an album whose
    /// colors were already extracted for the player hits the warm cache here.
    private var tintCacheID: String {
        album.albumId.map(ArtworkCacheKey.album) ?? album.id.uuidString
    }

    // MARK: - Footer

    @ViewBuilder
    private func footer(tracks: [Track]) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 2) {
                if let year = TrackCountText.year(album) {
                    Text(year)
                }
                Text(Self.countAndLength(tracks))
            }
            .font(.subheadline)
            .foregroundColor(.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }

        if let artist = primaryArtist, !moreByArtist.isEmpty {
            Section {
                AlbumCarousel(albums: moreByArtist, zoomNamespace: zoomNamespace)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            } header: {
                Text(String(localized: "More by \(LibraryFilterType.artists.localizedDisplay(artist))"))
                    .foregroundColor(.secondaryText)
            }
        }
    }

    /// "12 songs, 47 minutes", the running time in the locale's own words.
    private static func countAndLength(_ tracks: [Track]) -> String {
        let seconds = Int(tracks.reduce(0) { $0 + $1.duration })
        let length = Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .wide))
        return "\(TrackCountText.songs(tracks.count)), \(length)"
    }

    /// The first credited album artist: a shelf for "A & B" would match no one.
    private var primaryArtist: String? {
        guard let name = album.artistName, !name.isEmpty else { return nil }
        return ArtistParser.parse(
            name,
            unknownPlaceholder: LibraryFilterType.artists.unknownPlaceholder,
            role: LibraryFilterType.artists.artistRole
        ).first
    }

    private func loadMoreByArtist() async {
        guard let artist = primaryArtist else { return }
        let libraryManager = libraryManager
        let current = album
        let albums = await Task.detached(priority: .utility) {
            AlbumCarousel.albums(from: libraryManager.getTracksForArtist(artist))
                .filter { other in
                    if let id = current.albumId { return other.albumId != id }
                    return other.name != current.name
                }
        }.value
        guard !Task.isCancelled else { return }
        moreByArtist = albums
    }

    // MARK: - Track Sections

    private func trackRow(_ track: Track, context: [Track]) -> some View {
        TrackRow(
            track: track,
            onPlay: { play(track, in: context) },
            playlistManager: playlistManager,
            libraryManager: libraryManager,
            playbackManager: playbackManager,
            showsTrackNumber: Track.hasPlausibleTrackNumbers(context)
        )
        .equatable()
        .listRowBackground(Color.clear)
    }

    // MARK: - Playback

    private func play(_ track: Track, in context: [Track]) {
        playlistManager.play(track, source: .library(context: context))
    }

    private func playAll(_ tracks: [Track]) {
        playlistManager.playLibrary(tracks)
    }

    private func shuffleAll(_ tracks: [Track]) {
        playlistManager.shuffleLibrary(tracks)
    }
}
