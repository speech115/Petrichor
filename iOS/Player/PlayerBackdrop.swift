//
// PlayerBackdrop (iOS)
//
// The picture Apple Music paints its player with: the cover itself, shrunk to
// a few dozen pixels, blurred until no shape is left, its colors kept as they
// are and its exposure pulled to one level so a white sleeve and a black one both end
// up as a mid-dark wash. `PlayerBackground` turns copies of it slowly over
// one another. There is no public API for Apple Music's own background, so
// this rebuilds it from the same source rather than from a derived color.
//

import CoreImage
import ImageIO
import UIKit

enum PlayerBackdrop {
    @MainActor
    private static let cache = NSCache<NSString, UIImage>()

    @MainActor
    static func cached(for track: Track) -> UIImage? {
        guard let key = cacheKey(for: track) else { return nil }
        return cache.object(forKey: key)
    }

    @MainActor
    static func load(for track: Track) async -> UIImage? {
        guard let key = cacheKey(for: track), let data = track.displayArtwork else { return nil }
        if let cached = cache.object(forKey: key) { return cached }
        let image = await Task.detached(priority: .userInitiated) {
            render(from: data)
        }.value
        guard let image else { return nil }
        let backdrop = UIImage(cgImage: image)
        cache.setObject(backdrop, forKey: key)
        return backdrop
    }

    /// Built from the thumbnail, which a track has from the moment it becomes
    /// current. Keyed on it too, so the full artwork arriving a moment later
    /// changes nothing on screen: the wash is the same picture either way.
    @MainActor
    private static func cacheKey(for track: Track) -> NSString? {
        guard let data = track.displayArtwork else { return nil }
        return "\(track.albumId ?? -1)|\(track.id)|\(data.count)" as NSString
    }

    /// Average luminance the wash is exposed to. Apple Music's player sits
    /// around this level on both pale and near-black covers.
    private static let targetLuminance = 0.40

    nonisolated private static func render(from data: Data) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 96
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        let context = CIContext(options: [.workingColorSpace: NSNull()])
        let input = CIImage(cgImage: thumbnail)
        let extent = input.extent

        let blurred = input
            .clampedToExtent()
            .applyingGaussianBlur(sigma: Double(extent.width) / 10)
            .cropped(to: extent)

        let luminance = averageLuminance(of: blurred, in: context)
        let exposure = log2(targetLuminance / max(luminance, 0.02))
        let exposed = blurred.applyingFilter(
            "CIExposureAdjust",
            parameters: [kCIInputEVKey: min(max(exposure, -2), 1.5)]
        )
        return context.createCGImage(exposed, from: extent)
    }

    nonisolated private static func averageLuminance(of image: CIImage, in context: CIContext) -> Double {
        let average = image.applyingFilter(
            "CIAreaAverage",
            parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent)]
        )
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(
            average,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return (0.2126 * Double(pixel[0]) + 0.7152 * Double(pixel[1]) + 0.0722 * Double(pixel[2])) / 255
    }
}
