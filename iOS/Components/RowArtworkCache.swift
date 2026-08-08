//
// RowArtworkCache (iOS)
//
// Decoded-image cache for list row artwork (ticket 07). Rows key on the
// album id: list thumbnails are album art, and the id is stable across
// reloads, so the cache survives list rebuilds. Tracks without an albumId
// are not cached (rare; such rows fall back to a per-row decode).
//

import UIKit

final class RowArtworkCache {
    static let shared = RowArtworkCache()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 500
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    func image(forKey key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func setImage(_ image: UIImage, forKey key: String) {
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }
}
