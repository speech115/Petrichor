//
// DetailZoomTransition (iOS)
//
// Shared zoom-navigation helpers for playlist/album detail opens — the
// Apple Music hero transition via matchedTransitionSource + zoom.
// Each NavigationStack installs a Namespace into the environment; sources
// and destinations read it. Missing namespace is a no-op so nested previews
// and non-zooming links stay safe.
//

import SwiftUI

enum DetailZoomID: Hashable {
    case playlist(UUID)
    case album(UUID)
}

private struct ZoomNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    var zoomNamespace: Namespace.ID? {
        get { self[ZoomNamespaceKey.self] }
        set { self[ZoomNamespaceKey.self] = newValue }
    }
}

extension View {
    /// Marks this view as the zoom source for a playlist/album push.
    func detailZoomSource(_ id: DetailZoomID) -> some View {
        modifier(DetailZoomSourceModifier(id: id))
    }

    /// Zooms the pushed detail screen out of the matching source.
    func detailZoomDestination(_ id: DetailZoomID) -> some View {
        modifier(DetailZoomDestinationModifier(id: id))
    }
}

private struct DetailZoomSourceModifier: ViewModifier {
    let id: DetailZoomID
    @Environment(\.zoomNamespace) private var zoomNamespace

    @ViewBuilder
    func body(content: Content) -> some View {
        if let zoomNamespace {
            content.matchedTransitionSource(id: id, in: zoomNamespace)
        } else {
            content
        }
    }
}

private struct DetailZoomDestinationModifier: ViewModifier {
    let id: DetailZoomID
    @Environment(\.zoomNamespace) private var zoomNamespace

    @ViewBuilder
    func body(content: Content) -> some View {
        if let zoomNamespace {
            content.navigationTransition(.zoom(sourceID: id, in: zoomNamespace))
        } else {
            content
        }
    }
}
