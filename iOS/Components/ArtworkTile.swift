//
// ArtworkTile (iOS)
//
// The artwork slot every list row and card shares: the image when the row
// carries artwork data, a rounded placeholder with a music note otherwise.
// Rows only differ in size and corner radius, so those are the parameters.
//
// Decoding happens off the main thread and the decoded image is cached by
// `cacheKey` (album id for list rows) so a row that scrolls back into view
// does not re-decode its JPEG/HEIC.
//
// A row with no artwork in hand can name a `loader`: it runs off the main
// thread only for the rows actually on screen. That is the path for tracks
// whose cover hangs off the track rather than an album — pulling those blobs
// into every list up front would carry tens of megabytes the list never shows.
//

import SwiftUI
import UIKit

struct ArtworkTile: View {
    let data: Data?
    /// Stable cache key (album id for list rows). Rows without one decode
    /// per appearance and are not cached.
    var cacheKey: String? = nil
    var cornerRadius: CGFloat = 6
    var iconSize: CGFloat = 16
    var placeholderIcon: String = Icons.musicNote
    /// Fetches the artwork for rows that arrive without any, called at most
    /// once per appearance and never on the main thread.
    var loader: (@Sendable () -> Data?)? = nil

    @State private var decodedImage: UIImage?
    @State private var loadedData: Data?

    var body: some View {
        Group {
            if let cacheKey, let cached = RowArtworkCache.shared.image(forKey: cacheKey) {
                artworkImage(cached)
            } else if let data = data ?? loadedData {
                decodeView(data: data, cacheKey: cacheKey)
            } else if let loader {
                placeholder.task(id: cacheKey) {
                    let fetched = await Task.detached(priority: .utility) { loader() }.value
                    guard !Task.isCancelled else { return }
                    loadedData = fetched
                }
            } else {
                placeholder
            }
        }
        // Reuse protection: when the row is re-bound to different artwork,
        // the state below resets to the placeholder instead of flashing the
        // previous track's image. Rows without a cacheKey (rare) key on the
        // data hash.
        .id(cacheKey ?? data.map { "\($0.hashValue)" })
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    private func decodeView(data: Data, cacheKey: String?) -> some View {
        Group {
            if let decodedImage {
                artworkImage(decodedImage)
            } else {
                placeholder
                    .task(id: cacheKey) {
                        guard !Task.isCancelled else { return }
                        let image = await Task.detached(priority: .utility) {
                            UIImage(data: data)?.preparingForDisplay()
                        }.value
                        guard !Task.isCancelled else { return }
                        if let image {
                            if let cacheKey {
                                RowArtworkCache.shared.setImage(image, forKey: cacheKey)
                            }
                            decodedImage = image
                        }
                    }
            }
        }
    }

    /// `Image.resizable().aspectRatio(contentMode: .fill)` does not just draw
    /// past its frame — it *reports* the enlarged size as its own, so every
    /// clip and frame above it lands on the wrong rectangle and a wide cover
    /// spills over the row beside it. Anchoring the layout on `Color.clear`
    /// pins the reported size to whatever was proposed and clips the image to
    /// that, which is the only arrangement where the caller's frame holds.
    private func artworkImage(_ image: UIImage) -> some View {
        Color.clear
            .overlay {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
            .clipped()
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color.secondary.opacity(0.12))
            Image(systemName: placeholderIcon)
                .font(.system(size: iconSize))
                .foregroundColor(.secondary)
        }
    }
}
