//
// SecondaryTextColor (iOS)
//
// The secondary-text color that still clears the WCAG AA bar for normal text
// (4.5:1) in light mode. SwiftUI's `.secondary` resolves to
// `UIColor.secondaryLabel`, which measures ~3.4:1 against a white or grouped
// background — the accessibility audit flags every normal-size label using
// it. Dark mode keeps the system secondary label, which already clears 4.5:1
// there. The light-mode value is the system secondary's own hue, darkened
// until it passes on both white and grouped backgrounds.
//

import SwiftUI

extension Color {
    static let secondaryText = Color(uiColor: UIColor { traits in
        guard traits.userInterfaceStyle != .dark else { return .secondaryLabel }
        return UIColor(red: 0.42, green: 0.42, blue: 0.44, alpha: 1)
    })
}
