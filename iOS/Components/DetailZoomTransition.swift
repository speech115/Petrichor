//
// DetailZoomTransition (iOS)
//
// Zoom-navigation helpers for playlist/album detail opens. Callers pass the
// NavigationStack's `@Namespace` directly — storing Namespace.ID? in the
// environment made matchedTransitionSource a silent no-op, so opens fell
// back to the plain slide push.
//

import SwiftUI

enum DetailZoomID: Hashable {
    case playlist(UUID)
    case album(UUID)
}

extension View {
    /// Marks this view as the zoom source for a playlist/album push.
    func detailZoomSource(_ id: DetailZoomID, in namespace: Namespace.ID) -> some View {
        matchedTransitionSource(id: id, in: namespace) { source in
            source
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    /// Zooms the pushed detail screen out of the matching source.
    func detailZoomDestination(_ id: DetailZoomID, in namespace: Namespace.ID) -> some View {
        navigationTransition(.zoom(sourceID: id, in: namespace))
    }
}

/// Applies a detail zoom source only when a parent stack passes a namespace
/// (Home category / Artist). Hosts without zoom leave `namespace` nil.
struct OptionalDetailZoomSource: ViewModifier {
    let id: DetailZoomID
    let namespace: Namespace.ID?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let namespace {
            content.detailZoomSource(id, in: namespace)
        } else {
            content
        }
    }
}
