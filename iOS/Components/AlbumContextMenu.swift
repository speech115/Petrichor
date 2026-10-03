//
// AlbumContextMenu (iOS)
//
// Long press on an album card: the system context menu with a large cover
// preview above Play / Shuffle, the way Apple Music's shelves answer a long
// press. The tracks load only when an action is chosen, so the menu costs
// nothing to attach to every card.
//

import SwiftUI

extension View {
    func albumContextMenu(_ album: AlbumEntity) -> some View {
        modifier(AlbumContextMenu(album: album))
    }
}

private struct AlbumContextMenu: ViewModifier {
    @EnvironmentObject private var libraryManager: LibraryManager
    @EnvironmentObject private var playlistManager: PlaylistManager

    let album: AlbumEntity

    func body(content: Content) -> some View {
        content.contextMenu {
            Button {
                play(shuffled: false)
            } label: {
                Label(String(localized: "Play"), systemImage: Icons.playFill)
            }
            Button {
                play(shuffled: true)
            } label: {
                Label(String(localized: "Shuffle"), systemImage: Icons.shuffleFill)
            }
        } preview: {
            preview
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 10) {
            ArtworkTile(
                data: album.displayArtwork,
                cacheKey: album.albumId.map(ArtworkCacheKey.album),
                cornerRadius: 12,
                iconSize: 60,
                maxPixelSize: 600
            )
            .frame(width: 280, height: 280)

            VStack(alignment: .leading, spacing: 2) {
                Text(album.displayName)
                    .font(.headline)
                    .lineLimit(1)
                if let artist = album.artistName, !artist.isEmpty {
                    Text(artist)
                        .font(.subheadline)
                        .foregroundColor(.secondaryText)
                        .lineLimit(1)
                }
            }
        }
        .frame(width: 280)
        .padding(16)
    }

    private func play(shuffled: Bool) {
        let libraryManager = libraryManager
        let album = album
        Task {
            let tracks = await Task.detached(priority: .userInitiated) {
                libraryManager.getTracksForAlbum(album)
            }.value
            guard !tracks.isEmpty else { return }
            if shuffled {
                playlistManager.shuffleLibrary(tracks)
            } else {
                playlistManager.playLibrary(tracks)
            }
        }
    }
}
