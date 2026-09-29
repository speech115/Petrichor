//
// KeyboardDismissOnTap (iOS)
//
// Puts the keyboard away when the user taps outside a text field. It is a tap
// recognizer on the window that never cancels or blocks touches, so rows and
// buttons keep working: a SwiftUI tap gesture on the list, or on its parent,
// stopped rows from opening. Taps inside text inputs are ignored so tapping
// the search field does not flicker the keyboard.
//

import SwiftUI
import UIKit

extension View {
    /// Dismisses the keyboard on any tap outside a text input while `isActive`.
    /// `onDismiss` clears the view's own focus state, which would otherwise put
    /// focus back on the field right after UIKit resigns it.
    func dismissKeyboardOnTap(isActive: Bool, onDismiss: @escaping () -> Void) -> some View {
        background(KeyboardDismissOnTap(isActive: isActive, onDismiss: onDismiss))
    }
}

private struct KeyboardDismissOnTap: UIViewRepresentable {
    let isActive: Bool
    let onDismiss: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WindowObserverView {
        let view = WindowObserverView()
        view.isUserInteractionEnabled = false
        view.onWindowChange = { [weak coordinator = context.coordinator] window in
            coordinator?.window = window
        }
        return view
    }

    func updateUIView(_ view: WindowObserverView, context: Context) {
        context.coordinator.isActive = isActive
        context.coordinator.onDismiss = onDismiss
    }

    static func dismantleUIView(_ view: WindowObserverView, coordinator: Coordinator) {
        coordinator.isActive = false
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private let recognizer = UITapGestureRecognizer()
        private weak var installedWindow: UIWindow?

        var onDismiss: () -> Void = {}
        var isActive = false { didSet { install() } }
        weak var window: UIWindow? { didSet { install() } }

        override init() {
            super.init()
            recognizer.addTarget(self, action: #selector(tapped))
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
        }

        private func install() {
            let target = isActive ? window : nil
            guard target !== installedWindow else { return }
            installedWindow?.removeGestureRecognizer(recognizer)
            target?.addGestureRecognizer(recognizer)
            installedWindow = target
        }

        @objc private func tapped() {
            installedWindow?.endEditing(true)
            onDismiss()
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            !sequence(first: touch.view, next: { $0?.superview }).contains {
                $0 is UITextField || $0 is UITextView
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

private final class WindowObserverView: UIView {
    var onWindowChange: ((UIWindow?) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowChange?(window)
    }
}
