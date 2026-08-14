//
// AppearanceApplier
//
// Sixth platform seam: applying the color scheme to the platform chrome.
// `ColorMode` stays a pure setting; the platform-specific application lives
// here (`NSApp.appearance` on macOS, `UIWindow.overrideUserInterfaceStyle` on
// iOS), not in an inline `#if` at the call site.
//

import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum AppearanceApplier {
    @MainActor
    static func apply(_ mode: ColorMode) {
        #if os(macOS)
        switch mode {
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        case .auto:
            NSApp.appearance = nil
        }
        #else
        let style: UIUserInterfaceStyle
        switch mode {
        case .light: style = .light
        case .dark: style = .dark
        case .auto: style = .unspecified
        }
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.overrideUserInterfaceStyle = style
            }
        }
        #endif
    }
}
