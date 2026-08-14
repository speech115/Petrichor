//
// SystemVolumeSlider (iOS)
//
// The system volume control: a UIKit `MPVolumeView` stripped to its slider.
// It reflects the hardware buttons' volume and moves with them, which no
// custom control can do.
//
// The knob is a clear 1×1 image so only the bar shows (Apple Music style).
// An empty `UIImage()` leaves an unlabeled AX element; a clear pixel does not.
//

import MediaPlayer
import SwiftUI
import UIKit

struct SystemVolumeSlider: UIViewRepresentable {
    let tint: UIColor

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        // `showsRouteButton` is deprecated (iOS 13) and a no-op since: `MPVolumeView`
        // has not shown a route button on its own since AirPlay routing moved to
        // `AVRoutePickerView` (see `AirPlayButton`).
        view.showsVolumeSlider = true
        view.tintColor = tint
        let thumb = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { renderer in
            UIColor.clear.setFill()
            renderer.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        view.setVolumeThumbImage(thumb, for: .normal)
        view.setVolumeThumbImage(thumb, for: .highlighted)
        view.isAccessibilityElement = true
        view.accessibilityLabel = String(localized: "Volume")
        view.accessibilityTraits.insert(.adjustable)
        return view
    }

    func updateUIView(_ view: MPVolumeView, context: Context) {
        view.tintColor = tint
        view.accessibilityLabel = String(localized: "Volume")
    }
}
