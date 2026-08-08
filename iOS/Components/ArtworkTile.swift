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

    @State private var decodedImage: UIImage?

    var body: some View {
        Group {
            if let cacheKey, let cached = RowArtworkCache.shared.image(forKey: cacheKey) {
                artworkImage(cached)
            } else if let data {
                decodeView(data: data, cacheKey: cacheKey)
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

    private func artworkImage(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
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
