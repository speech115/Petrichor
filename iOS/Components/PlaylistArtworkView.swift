//
// PlaylistArtworkView (iOS)
//
// The cover a playlist wears everywhere: its own artwork, then the cover its
// pinned source entry gives it, then the 2x2 preview mosaic. One component for
// the list row (48 pt) and the detail header (280 pt) — only the frame differs.
//

import SwiftUI

struct PlaylistArtworkView: View {
    let playlist: Playlist
    let tracks: [Track]
    var cornerRadius: CGFloat = 8
    var iconSize: CGFloat = 20

    var body: some View {
        Group {
            if playlist.coverArtworkData != nil {
                ArtworkTile(
                    data: playlist.coverArtworkData,
                    cacheKey: ArtworkCacheKey.playlist(playlist.id),
                    cornerRadius: cornerRadius,
                    iconSize: iconSize
                )
            } else if let cover = PlaylistCover.of(playlist) {
                PlaylistCoverView(cover: cover, cornerRadius: cornerRadius)
            } else {
                ArtworkMosaic(covers: PlaylistCover.mosaicCovers(from: tracks))
            }
        }
        // The name and count beside/under it read it; the cover is decoration.
        .accessibilityHidden(true)
    }
}
