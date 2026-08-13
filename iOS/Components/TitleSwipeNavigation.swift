//
// TitleSwipeNavigation (iOS)
//
// Horizontal swipe on a track title switches prev/next, matching Apple
// Music's mini-player and Now Playing title gesture. Vertical movement is
// ignored so Now Playing's dismiss drag stays clean.
//

import SwiftUI

extension View {
    func titleSwipeNavigation(
        onPrevious: @escaping () -> Void,
        onNext: @escaping () -> Void
    ) -> some View {
        modifier(TitleSwipeNavigationModifier(onPrevious: onPrevious, onNext: onNext))
    }
}

private struct TitleSwipeNavigationModifier: ViewModifier {
    let onPrevious: () -> Void
    let onNext: () -> Void

    private let minimumDistance: CGFloat = 28
    private let axisBias: CGFloat = 1.2

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            DragGesture(minimumDistance: minimumDistance)
                .onEnded { value in
                    let dx = value.translation.width
                    let dy = value.translation.height
                    guard abs(dx) > abs(dy) * axisBias else { return }
                    if dx < 0 {
                        onNext()
                    } else {
                        onPrevious()
                    }
                }
        )
    }
}
