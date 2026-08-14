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
    /// Marks this view as the zoom source for a playlist/album push. `cornerRadius`
    /// clips the source to match the detail cover during the morph; pass `0` for
    /// text rows that have no cover.
    func detailZoomSource(_ id: DetailZoomID, in namespace: Namespace.ID, cornerRadius: CGFloat = 12) -> some View {
        matchedTransitionSource(id: id, in: namespace) { source in
            source.clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    /// Zooms the pushed detail screen out of the matching source.
    func detailZoomDestination(_ id: DetailZoomID, in namespace: Namespace.ID) -> some View {
        navigationTransition(.zoom(sourceID: id, in: namespace))
    }
}
