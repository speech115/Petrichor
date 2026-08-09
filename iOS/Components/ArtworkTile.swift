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
import ImageIO

/// Database-backed artwork reads are safe to move to a detached task because
/// GRDB serializes access through its pool. The wrapper makes that guarantee
/// explicit instead of converting arbitrary view closures to `@Sendable`.
struct ArtworkDataLoader: @unchecked Sendable {
    private let load: () -> Data?

    init(_ load: @escaping () -> Data?) {
        self.load = load
    }

    func callAsFunction() -> Data? {
        load()
    }
}

struct ArtworkTile: View {
    let data: Data?
    /// Stable cache key (album id for list rows). Rows without one decode
    /// per appearance and are not cached.
    var cacheKey: String? = nil
    var cornerRadius: CGFloat = 6
    var iconSize: CGFloat = 16
    var placeholderIcon: String = Icons.musicNote
    /// Largest decoded edge in physical pixels. A 44-point row needs about
    /// 132 pixels on a 3x phone, not the source image's full dimensions.
    var maxPixelSize: CGFloat = 180
    /// An already-decoded smaller rendition that can be shown on the first
    /// frame while this tile prepares its larger image. Now Playing uses the
    /// mini player's cached rendition so artwork moves with the screen instead
    /// of popping in after the opening transition.
    var fallbackMaxPixelSize: CGFloat? = nil
    /// Fetches the artwork for rows that arrive without any, called at most
    /// once per appearance and never on the main thread.
    var loader: ArtworkDataLoader? = nil

    @State private var decodedImage: UIImage?
    @State private var decodedImageKey: String?
    @State private var loadedData: Data?
    @State private var loadedDataKey: String?

    private var sizedCacheKey: String? {
        versionedCacheKey(maxPixelSize: maxPixelSize)
    }

    private var fallbackCacheKey: String? {
        fallbackMaxPixelSize.flatMap { versionedCacheKey(maxPixelSize: $0) }
    }

    private func versionedCacheKey(maxPixelSize: CGFloat) -> String? {
        cacheKey.map {
            // The current track first arrives with a thumbnail and is enriched
            // with full artwork after audio starts. Keep those decoded images
            // distinct so the larger view cannot remain stuck on the thumbnail.
            let dataVersion = data.map { "#\($0.count)" } ?? ""
            return "\($0)\(dataVersion)@\(Int(maxPixelSize.rounded(.up)))"
        }
    }

    var body: some View {
        let currentKey = sizedCacheKey
        let resolvedData = data ?? (loadedDataKey == currentKey ? loadedData : nil)
        let fallbackImage = fallbackCacheKey.flatMap { RowArtworkCache.shared.image(forKey: $0) }

        Group {
            if let currentKey, let cached = RowArtworkCache.shared.image(forKey: currentKey) {
                artworkImage(cached)
            } else if let resolvedData {
                decodeView(data: resolvedData, cacheKey: currentKey, fallbackImage: fallbackImage)
            } else if let loader {
                placeholder.task(id: sizedCacheKey) {
                    // Visible rows can start several reads at once. Utility
                    // priority keeps those reads from stealing interaction and
                    // animation time from the main thread.
                    let fetched = await Task.detached(priority: .utility) { loader() }.value
                    guard !Task.isCancelled else { return }
                    loadedData = fetched
                    loadedDataKey = currentKey
                }
            } else {
                placeholder
            }
        }
        // Reuse protection: when the row is re-bound to different artwork,
        // the state below resets to the placeholder instead of flashing the
        // previous track's image. Rows without a cacheKey (rare) key on the
        // data hash.
        .id(currentKey ?? data.map { "\($0.hashValue)@\(Int(maxPixelSize))" })
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    /// The decoded image cross-fades over the placeholder it replaces. Only on
    /// this branch: a cache hit is drawn on the first frame by the caller above
    /// and never changes state, so a scrolled-back row shows its cover outright
    /// instead of blinking. The fade belongs to the decode, not to the tile.
    private func decodeView(data: Data, cacheKey: String?, fallbackImage: UIImage?) -> some View {
        Group {
            if decodedImageKey == cacheKey, let decodedImage {
                artworkImage(decodedImage)
                    .transition(.opacity)
            } else if let fallbackImage {
                artworkImage(fallbackImage)
                    .transition(.opacity)
                    .task(id: cacheKey) {
                        await decode(data, cacheKey: cacheKey)
                    }
            } else {
                placeholder
                    .transition(.opacity)
                    .task(id: cacheKey) {
                        await decode(data, cacheKey: cacheKey)
                    }
            }
        }
    }

    private func decode(_ data: Data, cacheKey: String?) async {
        guard !Task.isCancelled else { return }
        let maxPixelSize = maxPixelSize
        let image = await Task.detached(priority: .utility) {
            Self.downsample(data, maxPixelSize: maxPixelSize)
        }.value
        guard !Task.isCancelled, let image else { return }
        if let cacheKey {
            RowArtworkCache.shared.setImage(image, forKey: cacheKey)
        }
        withAnimation(.easeOut(duration: 0.18)) {
            decodedImage = image
            decodedImageKey = cacheKey
        }
    }

    private static nonisolated func downsample(_ data: Data, maxPixelSize: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxPixelSize.rounded(.up))),
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: image)
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
