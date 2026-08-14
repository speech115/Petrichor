//
// AirPlayButton (iOS)
//
// The system AirPlay route picker, matching the tint of the surrounding
// Lyrics / Queue buttons.
//

import AVKit
import SwiftUI
import UIKit

struct AirPlayButton: UIViewRepresentable {
    let tint: UIColor

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView(frame: .zero)
        view.tintColor = tint
        view.activeTintColor = tint
        view.isAccessibilityElement = true
        view.accessibilityLabel = String(localized: "AirPlay")
        view.accessibilityTraits.insert(.button)
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {
        view.tintColor = tint
        view.activeTintColor = tint
        view.accessibilityLabel = String(localized: "AirPlay")
    }
}
