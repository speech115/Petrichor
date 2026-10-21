//
// AlbumCarousel (iOS)
//
// A horizontal shelf of album cards that push the album page with a zoom.
// Shared by the artist page ("Albums") and the album page ("More by").
//

import SwiftUI

struct AlbumCarousel: View {
    @EnvironmentObject private var libraryManager: LibraryManager

    let albums: [AlbumEntity]
    let zoomNamespace: Namespace.ID

    private static let cardSide: CGFloat = 170

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(albums) { album in
                    NavigationLink(value: LibraryDestination.album(album)) {
                        VStack(alignment: .leading, spacing: 6) {
                            artwork(album)
                                .frame(width: Self.cardSide, height: Self.cardSide)
                                .detailZoomSource(.album(album.id), in: zoomNamespace, cornerRadius: 10)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(album.displayName)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(2)
                                Text(TrackCountText.albumSubtitle(album))
                                    .font(.caption)
                                    .foregroundColor(.secondaryText)
                                    .lineLimit(1)
                            }
                            .accessibilityElement(children: .combine)
                        }
                        .frame(width: Self.cardSide, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .albumContextMenu(album)
                }
            }
            .scrollTargetLayout()
        }
        // Cards rest on the leading margin instead of half off screen.
        .contentMargins(.horizontal, 16, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
    }

    private func artwork(_ album: AlbumEntity) -> some View {
        ArtworkTile(
            data: album.displayArtwork,
            cacheKey: album.albumId.map(ArtworkCacheKey.album),
            cornerRadius: 10,
            iconSize: 36,
            loader: artworkLoader(for: album.albumId)
        )
    }

    private func artworkLoader(for albumId: Int64?) -> ArtworkDataLoader? {
        guard let albumId else { return nil }
        let database = libraryManager.databaseManager
        return ArtworkDataLoader { database.getAlbumArtworkThumbnail(albumId: albumId) }
    }

    /// The albums an artist's tracks belong to, by name.
    nonisolated static func albums(from tracks: [Track]) -> [AlbumEntity] {
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
