//
// TrackRow (iOS)
//
// The shared track row: artwork, title, artist, and a distinguishable playing
// state. Reused by the library, search, playlists, folders and the queue.
//
// Gestures live here so they work identically everywhere the row appears:
// swipe right to add to a playlist, swipe left to play next (with a
// confirmation haptic at gesture completion), long-press for the full
// context menu. VoiceOver exposes the same two actions as custom actions.
//
// Artwork loads lazily: rows already carrying a thumbnail (list queries
// populate the small `albumArtworkThumbnail`, detail screens the full
// artwork) render it directly, everything else falls back to an
// address-fetched thumbnail (single-album query, never a full scan), cached
// per track.
//

import SwiftUI
import UIKit

struct TrackRow: View {
    let track: Track
    let isCurrent: Bool
    let isPlaying: Bool
    let onPlay: () -> Void
    var menuContext: TrackContextMenu.MenuContext = .library

    @EnvironmentObject private var libraryManager: LibraryManager
    @EnvironmentObject private var playlistManager: PlaylistManager

    @State private var artworkImage: UIImage?
    @State private var showingPlaylistPicker = false

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 12) {
                artworkView
                    .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.body.weight(isCurrent ? .semibold : .regular))
                        .lineLimit(1)
                    Text(track.displayArtist)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Image(systemName: isPlaying ? Icons.pauseFill : Icons.playFill)
                    .font(.system(size: 14))
                    .foregroundColor(isCurrent ? .accentColor : .clear)
                    .frame(width: 18)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Menu {
                ForEach(playlistMenuItems, id: \.id) { item in
                    ContextMenuItemView(item: item)
                }
            } label: {
                Label(String(localized: "Add to Playlist"), systemImage: "text.badge.plus")
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                playNextWithConfirmation()
            } label: {
                Label(String(localized: "Play Next"), systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            .tint(.green)
        }
        .contextMenu {
            ForEach(menuItems, id: \.id) { item in
                ContextMenuItemView(item: item)
            }
        }
        .confirmationDialog(
            String(localized: "Add to Playlist"),
            isPresented: $showingPlaylistPicker,
            titleVisibility: .visible
        ) {
            ForEach(regularPlaylists) { playlist in
                Button(DefaultPlaylists.displayName(for: playlist)) {
                    playlistManager.updateTrackInPlaylist(track: track, playlist: playlist, add: true)
                }
            }
            Button(String(localized: "New Playlist...")) {
                playlistManager.showCreatePlaylistModal(with: [track])
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        }
        .accessibilityAction(named: String(localized: "Play Next")) {
            playNextWithConfirmation()
        }
        .accessibilityAction(named: String(localized: "Add to Playlist")) {
            showingPlaylistPicker = true
        }
        .task(id: track.trackId) {
            await loadArtwork()
        }
    }

    // MARK: - Gesture Actions

    private func playNextWithConfirmation() {
        playlistManager.playNext(track)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private var menuItems: [ContextMenuItem] {
        TrackContextMenu.createMenuItems(
            for: track,
            playlistManager: playlistManager,
            currentContext: menuContext
        )
    }

    private var playlistMenuItems: [ContextMenuItem] {
        TrackContextMenu.createPlaylistItems(for: track, playlistManager: playlistManager)
    }

    private var regularPlaylists: [Playlist] {
        playlistManager.playlists.filter { $0.type == .regular }
    }

    // MARK: - Artwork

    private var artworkView: some View {
        Group {
            if let artworkImage {
                Image(uiImage: artworkImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ArtworkTile(data: nil)
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @MainActor
    private func loadArtwork() async {
        if let cached = TrackRowArtworkStore.shared.cachedImage(for: track) {
            artworkImage = cached
            return
        }

        // List rows carry the album thumbnail (populated by the thumbnail
        // queries); fall back to whatever full artwork the row already has.
        if let data = track.displayArtwork,
           let image = UIImage(data: data) {
            artworkImage = image
            TrackRowArtworkStore.shared.cache(image, for: track)
            return
        }

        guard track.trackId != nil else { return }

        let databaseManager = libraryManager.databaseManager
        let albumId = track.albumId
        let trackId = track.trackId

        let image = await Task.detached(priority: .utility) {
            // Thumbnail first; rows without one (album-less tracks) fall back
            // to the track's own full artwork, as before the seam.
            let data = databaseManager.getArtworkThumbnail(albumId: albumId, trackId: trackId)
                ?? databaseManager.getArtworkData(albumId: albumId, trackId: trackId)
            return data.flatMap(UIImage.init(data:))
        }.value

        guard !Task.isCancelled, let image else { return }

        artworkImage = image
        TrackRowArtworkStore.shared.cache(image, for: track)
    }
}

@MainActor
private final class TrackRowArtworkStore {
    static let shared = TrackRowArtworkStore()

    private let cache = NSCache<NSNumber, UIImage>()

    init() {
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    func cachedImage(for track: Track) -> UIImage? {
        guard let trackId = track.trackId else { return nil }
        return cache.object(forKey: NSNumber(value: trackId))
    }

    func cache(_ image: UIImage, for track: Track) {
        guard let trackId = track.trackId else { return }
        cache.setObject(image, forKey: NSNumber(value: trackId))
    }
}
