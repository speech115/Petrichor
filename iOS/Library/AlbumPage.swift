//
// AlbumPage (iOS)
//
// Album detail page in Apple Music's layout: the page filled with the cover's
// color, the cover, title, the album artist as a link, "genre · year ·
// Lossless", then Shuffle / Play / more. The tracks follow in disc/track
// order; below them year, song count and running time, then a shelf of the
// artist's other albums. Once the header scrolls away, Play moves into the
// navigation bar.
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
    @State private var tracks: [Track] = []
    @State private var headerScrolledAway = false

    /// Roughly where the header's Play row passes under the navigation bar.
    private static let headerScrollAway: CGFloat = 420

    var body: some View {
        TrackListScreen(
            identity: AnyHashable(album.id),
            load: { [libraryManager, album] in libraryManager.getTracksForAlbum(album) },
            sectioner: { Self.discSections($0) },
            usesPlainStyle: true,
            onRowsChange: { tracks = $0 },
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
        .detailPageFill(headerTint)
        .navigationBarTitleDisplayMode(.inline)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top > Self.headerScrollAway
        } action: { _, isAway in
            withAnimation(.snappy) { headerScrolledAway = isAway }
        }
        .toolbar {
            if headerScrolledAway {
                ToolbarItem(placement: .principal) {
                    Button { playAll(tracks) } label: {
                        Label(String(localized: "Play"), systemImage: Icons.playFill)
                            .labelStyle(.titleAndIcon)
                            .font(.subheadline.weight(.semibold))
                    }
                    .disabled(tracks.isEmpty)
                }
            }
        }
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
        VStack(spacing: 0) {
            artwork
                .frame(width: 280, height: 280)
                .padding(.top, 8)

            Text(album.displayName)
                .font(.title2.weight(.bold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.top, 20)

            if let name = album.artistName, !name.isEmpty {
                artistLink(name)
            }

            if let meta = Self.meta(album: album, tracks: tracks) {
                Text(meta)
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)
            }

            actionRow(tracks: tracks)
                .padding(.top, 18)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    /// The whole credit as written, opening the first album artist's page.
    @ViewBuilder
    private func artistLink(_ name: String) -> some View {
        let label = Text(LibraryFilterType.albumArtists.localizedDisplay(name))
            .font(.title2)
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .padding(.top, 2)
        if let artist = primaryArtist {
            NavigationLink(value: LibraryDestination.artist(name: artist)) {
                // Accent on the plain page, as Apple Music; on a filled page
                // the accent loses to the fill, so the text stays primary.
                label.foregroundStyle(headerTint == nil ? Color.accentColor : Color.primary)
            }
            .buttonStyle(.plain)
        } else {
            label.foregroundStyle(Color.secondaryText)
        }
    }

    private func actionRow(tracks: [Track]) -> some View {
        HStack(spacing: 16) {
            Button { shuffleAll(tracks) } label: {
                HeroCircleLabel(systemImage: Icons.shuffleFill)
            }
            .buttonStyle(.plain)
            .disabled(tracks.isEmpty)
            .accessibilityLabel(String(localized: "Shuffle"))

            HeroPlayButton(isDisabled: tracks.isEmpty) { playAll(tracks) }

            Menu {
                Button {
                    ToastCenter.shared.enqueue(tracks, playNext: true, playlistManager: playlistManager)
                } label: {
                    Label(String(localized: "Play Next"), systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                Button {
                    ToastCenter.shared.enqueue(tracks, playNext: false, playlistManager: playlistManager)
                } label: {
                    Label(String(localized: "Add to Queue"), systemImage: "text.append")
                }
            } label: {
                HeroCircleLabel(systemImage: "ellipsis")
            }
            .disabled(tracks.isEmpty)
            .accessibilityLabel(String(localized: "More"))
        }
        .frame(maxWidth: 360)
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

    /// "Electronic · 2010 · Lossless": the album's most common genre, its
    /// year, and Lossless when every track is. Nil when none is known.
    private static func meta(album: AlbumEntity, tracks: [Track]) -> String? {
        var parts: [String] = []
        let unknownGenre = LibraryFilterType.genres.localizedUnknownPlaceholder
        let genres = tracks.map(\.displayGenre).filter { !$0.isEmpty && $0 != unknownGenre }
        if let genre = Dictionary(grouping: genres, by: { $0 }).max(by: { $0.value.count < $1.value.count })?.key {
            parts.append(genre)
        }
        if let year = TrackCountText.year(album) {
            parts.append(year)
        }
        if !tracks.isEmpty, tracks.allSatisfy({ $0.lossless == true }) {
            parts.append(String(localized: "Lossless"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
                Text(String(localized: "More by \(LibraryFilterType.albumArtists.localizedDisplay(artist))"))
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
    /// Album artist, not track performer: a compilation credited to "Various
    /// Artists" must not list albums where some guest merely appears.
    private var primaryArtist: String? {
        let unknown = LibraryFilterType.albumArtists.unknownPlaceholder
        guard let name = album.artistName, !name.isEmpty, name != unknown else { return nil }
        return ArtistParser.parse(
            name,
            unknownPlaceholder: unknown,
            role: LibraryFilterType.albumArtists.artistRole
        ).first
    }

    private func loadMoreByArtist() async {
        guard let artist = primaryArtist else { return }
        let libraryManager = libraryManager
        let current = album
        let albums = await Task.detached(priority: .utility) {
            AlbumCarousel.albums(from: libraryManager.getTracksBy(filterType: .albumArtists, value: artist))
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
