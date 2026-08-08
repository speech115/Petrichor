//
// SettingsToolbarItem (iOS)
//
// The gear in the top-right of every root tab, where Apple Music keeps the
// account button. One definition so the four tabs cannot drift in icon,
// placement or label.
//

import SwiftUI

struct SettingsToolbarItem: ToolbarContent {
    @Binding var showingSettings: Bool

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showingSettings = true
            } label: {
                Image(systemName: Icons.settings)
            }
            .accessibilityLabel(String(localized: "Settings"))
        }
    }
}
