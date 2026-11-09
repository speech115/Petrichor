//
// ZoomDismissGuard (iOS)
//
// Keeps the zoom transition's interactive dismissal off the controls that are
// themselves dragged. Now Playing is a `fullScreenCover` with the system zoom
// transition, and the system lets a touch grab the presented surface and pull
// it down — including while the opening zoom is still settling, before the
// content's own gestures can claim the touch. A scrub started right after the
// player opened therefore began closing it (seen on device; the simulator's UI
// tests wait for animations to finish and never hit it).
//
// SwiftUI has no API for this; UIKit's zoom options do
// (`interactiveDismissShouldBegin`). The guard installs that callback on the
// presented controller's zoom options and refuses the dismissal when the touch
// starts inside a registered region.
//

import SwiftUI
import UIKit

/// The regions, in the presented screen's coordinates, where a drag belongs to
/// a control and must not start the zoom dismissal.
@MainActor
final class ZoomDismissGuard {
    private var regions: [String: CGRect] = [:]

    func setRegion(_ frame: CGRect?, for id: String) {
        regions[id] = frame
    }

    func allowsDismiss(at location: CGPoint) -> Bool {
        !regions.values.contains { $0.contains(location) }
    }
}

extension View {
    /// Installs `dismissGuard` on the zoom transition that presented this
    /// screen. Apply once, on the presented root.
    func zoomDismissGuard(_ dismissGuard: ZoomDismissGuard) -> some View {
        background {
            ZoomDismissGuardInstaller(dismissGuard: dismissGuard)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    /// Registers this view's frame as a region where the zoom dismissal may
    /// not start.
    func blocksZoomDismiss(_ dismissGuard: ZoomDismissGuard, id: String) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            dismissGuard.setRegion(frame, for: id)
        }
        .onDisappear { dismissGuard.setRegion(nil, for: id) }
    }
}

private struct ZoomDismissGuardInstaller: UIViewControllerRepresentable {
    let dismissGuard: ZoomDismissGuard

    func makeUIViewController(context: Context) -> Controller {
        Controller(dismissGuard: dismissGuard)
    }

    func updateUIViewController(_ uiViewController: Controller, context: Context) {}

    final class Controller: UIViewController {
        private let dismissGuard: ZoomDismissGuard

        init(dismissGuard: ZoomDismissGuard) {
            self.dismissGuard = dismissGuard
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { nil }

        override func loadView() {
            let view = UIView()
            view.isUserInteractionEnabled = false
            self.view = view
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            install()
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            install()
        }

        /// The zoom options hang off the presented controller's
        /// `preferredTransition`; SwiftUI exposes no handle to them, so they
        /// are read by key, the one route that reaches them. `location` is in
        /// the presented view's coordinates, which for a full-screen cover are
        /// the SwiftUI global space the regions were measured in.
        private func install() {
            var candidate = parent
            while let controller = candidate {
                if let options = controller.preferredTransition?.value(forKey: "options")
                    as? UIViewController.Transition.ZoomOptions {
                    let dismissGuard = dismissGuard
                    options.interactiveDismissShouldBegin = { context in
                        context.willBegin && dismissGuard.allowsDismiss(at: context.location)
                    }
                    return
                }
                candidate = controller.parent
            }
        }
    }
}
