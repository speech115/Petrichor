//
// RecentAlbumsShelf (iOS)
//
// The Recently Played section of Home: a horizontal shelf of albums as large
// 130 pt squares - a big square means a container, not a song. Tracks from
// `getRecentlyPlayedTracks` are grouped by album id in memory, first
// occurrence order preserved, capped at ~10 unique albums. A tap opens the
// album's page; the section title links to the full "Top 25 Recently Played"
// smart playlist.
//

import SwiftUI

struct RecentAlbumsShelf: View {
    let albums: [AlbumEntity]
    /// Destination of the section title link (the "Top 25 Recently Played"
    /// smart playlist); nil renders a plain title.
    let headerValue: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let headerValue {
                SectionHeaderLink(title: String(localized: "Recently Played"), value: headerValue)
            } else {
                SectionTitle(title: String(localized: "Recently Played"))
            }

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(albums) { album in
                        NavigationLink(value: LibraryDestination.album(album)) {
                            VStack(alignment: .leading, spacing: 6) {
                                ArtworkTile(
                                    data: album.displayArtwork,
                                    cacheKey: album.albumId.map(String.init),
                                    cornerRadius: 10,
                                    iconSize: 28
                                )
                                .frame(width: 130, height: 130)

                                // The combine modifier sits on this text
                                // group alone, not the card: combined with
                                // the artwork above, the audit's contrast
                                // check samples the merged element's frame
                                // center — which lands inside the artwork
                                // square, not on any text — and calls it a
                                // failure. The artwork stays reachable via
                                // its own accessibilityHidden; VoiceOver
                                // still reads the card as one "name, artist"
                                // stop.
                                VStack(alignment: .leading, spacing: 6) {
                                    // 130 pt is fixed (it matches the artwork
                                    // above): any line limit reads as clipped
                                    // at the largest accessibility sizes,
                                    // where a short title alone can need more
                                    // than two lines to fit that width. No
                                    // limit lets the text wrap instead of
                                    // truncating, and `fixedSize` makes it
                                    // actually claim that height — inside a
                                    // `LazyHStack` a `Text` otherwise gets
                                    // compressed to the row's pre-scaling
                                    // height instead of growing.
                                    Text(album.displayName)
                                        .font(.subheadline.weight(.semibold))
                                        .fixedSize(horizontal: false, vertical: true)

                                    // `.secondary` measures ~3.4:1 at caption
                                    // size; the shared color clears 4.5:1.
                                    Text(album.artistName ?? "")
                                        .font(.caption)
                                        .foregroundColor(.secondaryText)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .accessibilityElement(children: .combine)
                            }
                            .frame(width: 130, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }
}

// MARK: - Grouping

extension RecentAlbumsShelf {
    /// Groups recently played tracks by album id, preserving first-occurrence
    /// order and skipping tracks without an album. The first `limit` albums
    /// come back as entities carrying thumbnails and the artist name. Counts
    /// from the library's entity cache win over the grouped subset, so an
    /// album opened from the shelf shows its real track count.
    static nonisolated func albums(
        from tracks: [Track],
        limit: Int,
        trackCountsByAlbumID: [Int64: Int] = [:]
    ) -> [AlbumEntity] {
        var order: [Int64] = []
        var grouped: [Int64: [Track]] = [:]
        for track in tracks {
            guard let albumId = track.albumId else { continue }
            if grouped[albumId] == nil {
                order.append(albumId)
            }
            grouped[albumId, default: []].append(track)
        }
        return order.prefix(limit).compactMap { albumId in
            guard let tracks = grouped[albumId], let first = tracks.first else { return nil }
            return AlbumEntity(
                name: first.album,
                trackCount: trackCountsByAlbumID[albumId] ?? tracks.count,
                artworkData: tracks.first { $0.albumArtworkData != nil }?.albumArtworkData,
                artworkThumbnail: tracks.first { $0.albumArtworkThumbnail != nil }?.albumArtworkThumbnail,
                albumId: albumId,
                year: first.year,
                artistName: first.albumArtist
            )
        }
    }
}
