//
// AppAppearance
//
// The app-wide color scheme setting. Views only store and switch the mode;
// applying it to the platform chrome happens in one place, so both macOS and
// iOS read the same `colorMode` preference and behave identically.
//

import SwiftUI

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
        AppearanceApplier.apply(self)
    }
}
