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

#if !os(macOS)
extension UIColor {
    static var windowBackgroundColor: UIColor { .systemBackground }
}
#endif
