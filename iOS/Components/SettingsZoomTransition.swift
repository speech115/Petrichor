//
// SettingsZoomTransition (iOS)
//
// Zoom-morph Settings out of the toolbar gear — the iOS 26 sheet-from-button
// pattern. ContentView owns the namespace and the sheet destination; each
// tab's SettingsToolbarItem marks the gear as the source.
//

import SwiftUI

enum SettingsZoomID {
    static let settings = "settings"
}

private struct SettingsZoomNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    var settingsZoomNamespace: Namespace.ID? {
        get { self[SettingsZoomNamespaceKey.self] }
        set { self[SettingsZoomNamespaceKey.self] = newValue }
    }
}

extension View {
    func settingsZoomSource() -> some View {
        modifier(SettingsZoomSourceModifier())
    }

    func settingsZoomDestination() -> some View {
        modifier(SettingsZoomDestinationModifier())
    }
}

private struct SettingsZoomSourceModifier: ViewModifier {
    @Environment(\.settingsZoomNamespace) private var settingsZoomNamespace

    @ViewBuilder
    func body(content: Content) -> some View {
        if let settingsZoomNamespace {
            content.matchedTransitionSource(id: SettingsZoomID.settings, in: settingsZoomNamespace)
        } else {
            content
        }
    }
}

private struct SettingsZoomDestinationModifier: ViewModifier {
    @Environment(\.settingsZoomNamespace) private var settingsZoomNamespace

    @ViewBuilder
    func body(content: Content) -> some View {
        if let settingsZoomNamespace {
            content.navigationTransition(
                .zoom(sourceID: SettingsZoomID.settings, in: settingsZoomNamespace)
            )
        } else {
            content
        }
    }
}
