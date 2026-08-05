//
// TrackRow (iOS)
//
// The shared track row: artwork, title, artist, and a distinguishable playing
// state. Reused by the library, search, playlists, folders and the queue;
// swipe and context-menu gestures land on it in ticket 05.
//
// Artwork loads lazily: rows already carrying artwork data render it directly,
// everything else falls back to an address-fetched cover (single-track query,
// never a full scan), cached per track.
//

import SwiftUI
import UIKit

struct TrackRow: View {
    let track: Track
    let isCurrent: Bool
    let isPlaying: Bool
    let onPlay: () -> Void

    @EnvironmentObject private var libraryManager: LibraryManager

    @State private var artworkImage: UIImage?

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
        .task(id: track.trackId) {
            await loadArtwork()
        }
    }

    private var artworkView: some View {
        Group {
            if let artworkImage {
                Image(uiImage: artworkImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.12))
                    Image(systemName: Icons.musicNote)
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                }
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

        if let data = track.artworkData, let image = UIImage(data: data) {
            artworkImage = image
            TrackRowArtworkStore.shared.cache(image, for: track)
            return
        }

        guard track.trackId != nil else { return }

        let databaseManager = libraryManager.databaseManager
        let albumId = track.albumId
        let trackId = track.trackId

        let image = await Task.detached(priority: .utility) {
            databaseManager
                .getArtworkData(albumId: albumId, trackId: trackId)
                .flatMap(UIImage.init(data:))
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
