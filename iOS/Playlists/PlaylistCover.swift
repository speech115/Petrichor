//
// PlaylistCover (iOS)
//
// The cover a playlist wears in place of the preview mosaic, so an export that
// arrived as a bare M3U still looks like the playlist it was in the service it
// came from — and so Favorites, which is ours and has no export behind it,
// still looks like something rather than four sampled records.
//
// `likedSongs` and `top2020` are Spotify's own artwork for those playlists,
// pulled from their CDN; `shazam` is Shazam's current mark; `vkMusic` is the
// VK Музыка app icon; `frankieShow` is the show's own order-of-merit mark from
// Серебряный дождь; `yandexLikes` is Yandex Music's `favorit-playlist-cover`,
// the moulded heart every "Мне нравится" wears, off their own avatars CDN.
//
// `appleFavorites` is Apple Music's favorites star, redrawn as a vector so it
// can carry a light and a dark version of itself — the asset catalog swaps
// them, which a bitmap could not do.
//

import SwiftUI

enum PlaylistCover {
    case appleFavorites
    case frankieShow
    case likedSongs
    case shazam
    case top2020
    case vkMusic
    case yandexLikes

    /// The cover for this playlist, if it has one. Favorites is the one smart
    /// playlist with artwork: it is a real destination on both tabs, where Top
    /// 25 is a query the library answers.
    static func of(_ playlist: Playlist) -> PlaylistCover? {
        if playlist.type == .smart {
            return playlist.name == DefaultPlaylists.favorites ? .appleFavorites : nil
        }
        return PlaylistSource.pinnedEntry(for: playlist)?.cover
    }

    /// What the mosaic gets: the first four covers, or only the first when the
    /// playlist was pinned to show one. `ArtworkMosaic` already draws a single
    /// cover full-bleed, so the choice is just how many it is handed.
    static func mosaicCovers(for playlist: Playlist, from tracks: [Track]) -> [Data] {
        let limit = PlaylistSource.pinnedEntry(for: playlist)?.usesFirstTrackCover == true ? 1 : 4
        return Array(tracks.lazy.compactMap { $0.displayArtwork }.prefix(limit))
    }
}

struct PlaylistCoverView: View {
    let cover: PlaylistCover
    var cornerRadius: CGFloat = 8

    var body: some View {
        Group {
            switch cover {
            case .appleFavorites:
                artwork("cover-apple-favorites")
            case .frankieShow:
                artwork("cover-frankie-show")
            case .likedSongs:
                artwork("cover-liked-songs")
            case .top2020:
                artwork("cover-top-2020")
            case .shazam:
                shazam
            case .vkMusic:
                artwork("cover-vk-music")
            case .yandexLikes:
                artwork("cover-yandex-likes")
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    // MARK: - Shazam

    /// The app's own arrangement: the blue disc on white, the S showing
    /// through the mark as the tile behind it.
    private var shazam: some View {
        square { side in
            ZStack {
                Color.white
                Image("logo-shazam")
                    .resizable()
                    .renderingMode(.template)
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(Color(red: 0.0, green: 0.53, blue: 1.0))
                    .frame(width: side * 0.86, height: side * 0.86)
            }
        }
    }

    // MARK: - Layout

    /// Covers are drawn to the shorter side and centred, so a tile that is
    /// handed a non-square frame still shows a square cover instead of a
    /// stretched one.
    private func square<Content: View>(@ViewBuilder _ content: @escaping (CGFloat) -> Content) -> some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)

            content(side)
                .frame(width: side, height: side)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Bundled artwork

    /// Same anchoring as `ArtworkTile.artworkImage`: a `.fill` image reports
    /// its enlarged size, so the frame has to come from something that does not.
    private func artwork(_ name: String) -> some View {
        Color.clear
            .overlay {
                Image(name)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
            .clipped()
    }
}
