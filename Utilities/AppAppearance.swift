//
// AppAppearance
//
// The app-wide color scheme setting. Views only store and switch the mode;
// applying it to the platform chrome happens in one place, so both macOS and
// iOS read the same `colorMode` preference and behave identically.
//

import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum ColorMode: String, CaseIterable {
    case light = "Light"
    case dark = "Dark"
    case auto = "Auto"

    var displayName: String {
        switch self {
        case .light: return String(localized: "Light")
        case .dark: return String(localized: "Dark")
        case .auto: return String(localized: "Auto")
        }
    }

    var icon: String {
        switch self {
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        case .auto: return "circle.lefthalf.filled"
        }
    }

    /// The mode stored in defaults, or `.auto` when unset.
    static var current: ColorMode {
        ColorMode(rawValue: UserDefaults.standard.string(forKey: "colorMode") ?? "") ?? .auto
    }

    /// Applies the mode to the whole app immediately.
    @MainActor
    func apply() {
        #if os(macOS)
        switch self {
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        case .auto:
            NSApp.appearance = nil
        }
        #else
        let style: UIUserInterfaceStyle
        switch self {
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
