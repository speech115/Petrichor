//
// HorizontalPanGesture (iOS)
//
// A sideways drag that never takes a vertical one. A SwiftUI `DragGesture`
// claims every pan it sees, even when added simultaneously, and starves the
// zoom transition's pull-down dismissal; this UIKit pan declines to begin
// unless the finger moves mostly sideways, so a downward pull goes straight
// to the system.
//

import SwiftUI
import UIKit

struct HorizontalPanGesture: UIGestureRecognizerRepresentable {
    /// Horizontal travel since the touch began.
    var onChanged: (CGFloat) -> Void
    /// Final travel and horizontal velocity, in points per second.
    var onEnded: (_ translation: CGFloat, _ velocity: CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let translation = recognizer.translation(in: recognizer.view).x
        switch recognizer.state {
        case .changed:
            onChanged(translation)
        case .ended, .cancelled, .failed:
            onEnded(translation, recognizer.velocity(in: recognizer.view).x)
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y) * 1.2
        }
    }
}
