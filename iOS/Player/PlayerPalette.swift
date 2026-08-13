//
// PlayerPalette (iOS)
//
// The colors the Now Playing screen paints itself with, derived from the
// track's dominant artwork colors.
//
// The screen is a single dark surface, the way Apple Music's player is: the
// artwork colors set the hue, but brightness is clamped into a narrow dark
// band so white text and controls stay legible over any cover, in either
// color scheme. That is why nothing here takes a `colorScheme` — the player
// deliberately does not follow it.
//

import SwiftUI
import UIKit

struct PlayerPalette: Equatable {
    /// Top-to-bottom background gradient.
    let gradient: [Color]

    /// Primary text and active controls.
    let foreground = Color.white

    /// Titles' secondary line, inactive controls.
    var secondary: Color { .white.opacity(0.55) }

    /// Filled tracks (scrubber, volume) and the active shuffle/repeat state.
    var control: Color { .white.opacity(0.85) }

    /// Backdrop of the round glyph buttons in the title row.
    var chip: Color { .white.opacity(0.16) }

    static let neutral = PlayerPalette(gradient: [
        Color(white: 0.20),
        Color(white: 0.12),
        Color(white: 0.06)
    ])

    @MainActor
    static func make(for track: Track?, useArtworkColors: Bool) async -> PlayerPalette {
        guard useArtworkColors, let track else { return neutral }

        let dominant = Array((await track.loadDominantColors()).prefix(2))
        guard let top = dominant.first else { return neutral }

        let second = dominant.count > 1 ? dominant[1] : top
        return PlayerPalette(gradient: [
            surface(top, brightness: 0.52),
            surface(second, brightness: 0.30),
            surface(second, brightness: 0.12)
        ])
    }

    /// Keeps the artwork's hue, tames its saturation and pins its brightness,
    /// so a washed-out cover and a neon one both land on the same dark surface.
    private static func surface(_ color: UIColor, brightness: CGFloat) -> Color {
        var hue: CGFloat = 0, saturation: CGFloat = 0, value: CGFloat = 0, alpha: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &value, alpha: &alpha)
        return Color(
            hue: Double(hue),
            saturation: Double(min(saturation, 0.72)),
            brightness: Double(brightness)
        )
    }
}
