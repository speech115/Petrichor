import SwiftUI

/// A shelf tile for an album or artist: square artwork (round for artists)
/// with the name and a subtitle under it. Clicking it calls `onOpen`.
///
/// Entities carry no artwork, so the tile reads its own thumbnail off the
/// main thread once it is on screen.
struct EntityTile: View {
    let entity: any Entity
    let subtitle: String?
    var size: CGFloat = 160
    let onOpen: () -> Void

    @EnvironmentObject private var libraryManager: LibraryManager
    @State private var image: PlatformImage?

    private var isArtist: Bool { entity is ArtistEntity }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: isArtist ? .center : .leading, spacing: 6) {
                artwork
                    .frame(width: size, height: size)
                    .clipShape(isArtist ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 10)))
                    .shadow(color: .black.opacity(0.15), radius: 6, y: 3)

                VStack(alignment: isArtist ? .center : .leading, spacing: 2) {
                    Text(entity.displayName)
                        .font(.system(size: 13, weight: .semibold))
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
            }
            .frame(width: size, alignment: isArtist ? .center : .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .task(id: entity.id) {
            image = await loadThumbnail().flatMap(PlatformImage.init(data:))
        }
    }

    private func loadThumbnail() async -> Data? {
        if let data = entity.displayArtwork { return data }
        let database = libraryManager.databaseManager
        let name = entity.name
        let albumId = (entity as? AlbumEntity)?.albumId
        let isArtist = isArtist
        return await Task.detached(priority: .userInitiated) {
            if isArtist { return database.getArtistArtworkThumbnail(name: name) }
            guard let albumId else { return nil }
            return database.getAlbumArtworkThumbnail(albumId: albumId)
                ?? database.getArtworkData(albumId: albumId, trackId: nil)
        }.value
    }

    @ViewBuilder private var artwork: some View {
        if let image {
            Image(platformImage: image)
                .resizable()
                .scaledToFill()
        } else {
            Rectangle()
                .fill(Color.secondary.opacity(0.2))
                .overlay {
                    if isArtist {
                        Text(entity.name.artistInitials)
                            .font(.system(size: size * 0.3, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: Icons.opticalDiscFill)
                            .font(.system(size: size * 0.22))
                            .foregroundStyle(.secondary)
                    }
                }
        }
    }
}

/// A titled horizontal row of tiles, as the iPhone's shelves.
struct EntityShelf<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title2.bold())
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    content()
                }
            }
        }
    }
}
