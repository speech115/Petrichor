//
// PlatformShims
//
// Cross-platform type aliases so shared code can reference image and color
// types without #if at every call site. Compiles for both macOS and iOS.
//

import SwiftUI

#if os(macOS)
import AppKit
public typealias PlatformImage = NSImage
public typealias PlatformColor = NSColor
public typealias PlatformFont = NSFont
#else
import UIKit
public typealias PlatformImage = UIImage
public typealias PlatformColor = UIColor
public typealias PlatformFont = UIFont
#endif

#if os(macOS)
extension NSImage {
    /// В UIKit это свойство, в AppKit — метод. Общий код обращается к нему
    /// одинаково на обеих платформах.
    var cgImage: CGImage? {
        cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
#endif

extension Color {
    init(platformColor: PlatformColor) {
        #if os(macOS)
        self.init(nsColor: platformColor)
        #else
        self.init(uiColor: platformColor)
        #endif
    }
}

extension Image {
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}

extension PlatformColor {
    /// SwiftUI `Color` → platform color. The reverse of
    /// `Color.init(platformColor:)`.
    static func from(_ color: Color) -> PlatformColor {
        #if os(macOS)
        NSColor(color)
        #else
        UIColor(color)
        #endif
    }

    /// An RGB-space copy of the color. `NSColor` may carry a non-RGB color
    /// space and needs the conversion; `UIColor` is already RGB-backed.
    func rgb() -> PlatformColor? {
        #if os(macOS)
        usingColorSpace(.deviceRGB)
        #else
        self
        #endif
    }
}

extension PlatformFont {
    static func systemFont(ofSize size: CGFloat, bold: Bool) -> PlatformFont {
        #if os(macOS)
        NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
        #else
        UIFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
        #endif
    }
}

extension PlatformImage {
    /// Encode a `CGImage` as JPEG platform data.
    static func jpegData(from cgImage: CGImage, quality: CGFloat) -> Data? {
        #if os(macOS)
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .jpeg, properties: [.compressionFactor: quality])
        #else
        return UIImage(cgImage: cgImage).jpegData(compressionQuality: quality)
        #endif
    }
}

#if !os(macOS)
extension UIColor {
    static var windowBackgroundColor: UIColor { .systemBackground }
}
#endif
