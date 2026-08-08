//
// PlaylistCover (iOS)
//
// The cover a pinned playlist wears in place of the preview mosaic, so an
// export that arrived as a bare M3U still looks like the playlist it was in
// the service it came from.
//
// `likedSongs` and `top2020` are Spotify's own artwork for those playlists,
// pulled from their CDN; `shazam` is Shazam's current mark; `yandexLikes` is
// Yandex Music's heart glyph, taken from their own icon sprite, on the dark
// tile their liked-tracks cover uses.
//

import SwiftUI

enum PlaylistCover {
    case likedSongs
    case shazam
    case top2020
    case yandexLikes

    /// The pinned cover for this playlist, if it has one.
    static func of(_ playlist: Playlist) -> PlaylistCover? {
        PlaylistSource.pinnedEntry(for: playlist)?.cover
    }
}

struct PlaylistCoverView: View {
    let cover: PlaylistCover
    var cornerRadius: CGFloat = 8

    var body: some View {
        Group {
            switch cover {
            case .likedSongs:
                artwork("cover-liked-songs")
            case .top2020:
                artwork("cover-top-2020")
            case .shazam:
                shazam
            case .yandexLikes:
                yandexLikes
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    // MARK: - Shazam

    /// The app's own arrangement: the blue disc on white, the S showing
    /// through the mark as the tile behind it.
    private var shazam: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)

            ZStack {
                Color.white
                Image("logo-shazam")
                    .resizable()
                    .renderingMode(.template)
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(Color(red: 0.0, green: 0.53, blue: 1.0))
                    .frame(width: side * 0.86, height: side * 0.86)
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Yandex Music likes

    /// Their heart on their dark tile. The glyph is Yandex Music's own, lifted
    /// from the icon sprite the web player serves, so the silhouette matches
    /// the app rather than approximating it.
    private var yandexLikes: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)

            ZStack {
                Color(red: 0.09, green: 0.06, blue: 0.07)
                Image("logo-yandex-heart")
                    .resizable()
                    .renderingMode(.template)
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(Color(red: 0.937, green: 0.176, blue: 0.235))
                    .frame(width: side * 0.62, height: side * 0.62)
            }
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
