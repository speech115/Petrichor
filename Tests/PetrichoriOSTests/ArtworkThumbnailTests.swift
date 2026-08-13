import CoreGraphics
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Petrichor

// MARK: - Helpers

private func makeTestImage(
    width: Int,
    height: Int,
    backgroundColor: CGColor = CGColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 1),
    accentColor: CGColor = CGColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 1)
) -> Data {
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    context.setFillColor(backgroundColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(accentColor)
    context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))

    let image = context.makeImage()!
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(
        data,
        UTType.png.identifier as CFString,
        1,
        nil
    )!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

private func imageSize(of data: Data) -> (width: Int, height: Int)? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int else {
        return nil
    }
    return (width, height)
}

private func imageType(of data: Data) -> String? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return CGImageSourceGetType(source) as String?
}

// MARK: - Tests

@Test func thumbnailIsGeneratedFromArtwork() {
    let thumbnail = ImageUtils.makeThumbnail(from: makeTestImage(width: 1200, height: 900))

    #expect(thumbnail != nil)
    guard let thumbnail else { return }
    #expect(imageSize(of: thumbnail) != nil)
}

@Test func thumbnailFitsWithinMaxDimension() {
    let thumbnail = ImageUtils.makeThumbnail(from: makeTestImage(width: 1200, height: 900))

    guard let thumbnail, let size = imageSize(of: thumbnail) else {
        Issue.record("Thumbnail is missing or undecodable")
        return
    }
    #expect(max(size.width, size.height) <= 420)
}

@Test func thumbnailPreservesAspectRatio() {
    let thumbnail = ImageUtils.makeThumbnail(from: makeTestImage(width: 1200, height: 900))

    guard let thumbnail, let size = imageSize(of: thumbnail) else {
        Issue.record("Thumbnail is missing or undecodable")
        return
    }
    // 1200x900 (4:3) scales down to exactly 420x315.
    #expect(size == (420, 315))
}

@Test func thumbnailIsEncodedAsHEIC() {
    let thumbnail = ImageUtils.makeThumbnail(from: makeTestImage(width: 1200, height: 900))

    guard let thumbnail else {
        Issue.record("Thumbnail is missing")
        return
    }
    #expect(imageType(of: thumbnail) == UTType.heic.identifier)
}

