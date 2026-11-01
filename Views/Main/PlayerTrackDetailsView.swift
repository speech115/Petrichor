import SwiftUI

struct PlayerTrackDetailsView: View, Equatable {
    let track: Track?
    let contextMenuItems: [ContextMenuItem]
    let playlistManager: PlaylistManager

    static func == (lhs: PlayerTrackDetailsView, rhs: PlayerTrackDetailsView) -> Bool {
        lhs.track?.id == rhs.track?.id &&
        lhs.track?.isFavorite == rhs.track?.isFavorite
    }

    // Three rows spread to stay vertically balanced against the album artwork.
    private let titleFontSize: CGFloat = 16
    private let artistFontSize: CGFloat = 14
    private let albumFontSize: CGFloat = 13
    private let rowSpacing: CGFloat = 10
    private let titleRowHeight: CGFloat = 20
    private let textRowHeight: CGFloat = 18

    var body: some View {
        VStack(alignment: .leading, spacing: rowSpacing) {
            // Title row with favorite button
            HStack(alignment: .center, spacing: 8) {
                Text(track?.title ?? "")
                    .font(.system(size: titleFontSize, weight: .medium))
                    .lineLimit(1)
                    .foregroundColor(.primary)
                    .truncationMode(.tail)
                    .help(track?.title ?? "")
                    .contextMenu {
                        TrackContextMenuContent(items: contextMenuItems)
                    }

                if let track = track {
                    FavoriteButtonView(
                        trackId: track.id,
                        isFavorite: track.isFavorite
                    ) { playlistManager.toggleFavorite(for: track) }
                }
            }
            .frame(height: titleRowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)

            // Artist with marquee
            MarqueeText(
                text: track?.displayArtist ?? "",
                font: .system(size: artistFontSize),
                color: .secondary
            )
            .frame(height: textRowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .link { if let track { TrackContextMenu.goToArtist(of: track) } }
            .contextMenu {
                TrackContextMenuContent(items: contextMenuItems)
            }

            // Album with marquee
            MarqueeText(
                text: track?.displayAlbum ?? "",
                font: .system(size: albumFontSize),
                color: .secondary
            )
            .frame(height: textRowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .link { if let track { TrackContextMenu.goToAlbum(of: track) } }
            .contextMenu {
                TrackContextMenuContent(items: contextMenuItems)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct FavoriteButtonView: View, Equatable {
    let trackId: String
    let isFavorite: Bool
    let onToggle: () -> Void

    static func == (lhs: FavoriteButtonView, rhs: FavoriteButtonView) -> Bool {
        lhs.trackId == rhs.trackId &&
        lhs.isFavorite == rhs.isFavorite
    }

    var body: some View {
        Button(action: onToggle) {
            Image(systemName: isFavorite ? Icons.starFill : Icons.star)
                .font(.system(size: 12))
                .foregroundColor(isFavorite ? .yellow : .secondary)
                .animation(.easeInOut(duration: 0.2), value: isFavorite)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .hoverEffect(scale: 1.15)
        .help(isFavorite ? String(localized: "Remove from Favorites") : String(localized: "Add to Favorites"))
    }
}

struct TrackArtworkInfo: Equatable {
    let id: String
    let artworkData: Data?

    static func == (lhs: TrackArtworkInfo, rhs: TrackArtworkInfo) -> Bool {
        lhs.id == rhs.id && lhs.artworkData?.count == rhs.artworkData?.count
    }
}

struct PlayerAlbumArtView: View, Equatable {
    let trackInfo: TrackArtworkInfo?
    let contextMenuItems: [ContextMenuItem]
    let onTap: (() -> Void)?

    static func == (lhs: PlayerAlbumArtView, rhs: PlayerAlbumArtView) -> Bool {
        lhs.trackInfo == rhs.trackInfo
    }

    var body: some View {
        AlbumArtworkImage(trackInfo: trackInfo)
            .onTapGesture {
                onTap?()
            }
            .contextMenu {
                TrackContextMenuContent(items: contextMenuItems)
            }
    }
}

private struct AlbumArtworkImage: View {
    let trackInfo: TrackArtworkInfo?
    @State private var isHovered = false

    var body: some View {
        ZStack {
            // Static image content
            AlbumArtworkContent(trackInfo: trackInfo)
        }
        .frame(width: 76, height: 76)
        .shadow(
            color: .black.opacity(isHovered ? 0.4 : 0.2),
            radius: isHovered ? 6 : 2,
            x: 0,
            y: isHovered ? 3 : 1
        )
        .scaleEffect(isHovered ? 1.05 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: isHovered)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

private struct AlbumArtworkContent: View {
    let trackInfo: TrackArtworkInfo?

    var body: some View {
        if let artworkData = trackInfo?.artworkData,
           let platformImage = PlatformImage(data: artworkData) {
            Image(platformImage: platformImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 76, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        } else {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.secondary.opacity(0.15))
                .overlay(
                    Image(systemName: Icons.musicNote)
                        .font(.system(size: 22, weight: .light))
                        .foregroundColor(.secondary)
                )
        }
    }
}
