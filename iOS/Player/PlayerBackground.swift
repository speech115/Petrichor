//
// PlayerBackground (iOS)
//
// The Now Playing surface as a slowly drifting mesh of the artwork's colors,
// the way Apple Music's player background breathes behind the controls. The
// palette's three tones keep their top-to-bottom order; only the inner mesh
// points wander, so the colors pool and flow without ever swapping places.
//
// It drifts only while the music plays and stands still under Reduce Motion.
// A separate view, so the per-frame timeline redraws the backdrop alone.
//

import SwiftUI

struct PlayerBackground: View {
    let palette: PlayerPalette
    let isPlaying: Bool

    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || !isPlaying)) { timeline in
            mesh(at: reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate)
        }
        .ignoresSafeArea()
    }

    private func mesh(at time: TimeInterval) -> some View {
        let tones = palette.gradient
        let top = tones.first ?? .black
        let middle = tones.count > 1 ? tones[1] : top
        let bottom = tones.last ?? middle

        // Slow, unrelated periods, so the drift never reads as a loop.
        func drift(_ period: Double, _ amount: Double) -> Float {
            Float(sin(time * 2 * .pi / period) * amount)
        }

        return MeshGradient(
            width: 3,
            height: 3,
            points: [
                [0, 0], [0.5 + drift(23, 0.12), 0], [1, 0],
                [0, 0.45 + drift(19, 0.10)], [0.5 + drift(29, 0.18), 0.45 + drift(17, 0.12)], [1, 0.45 + drift(31, 0.10)],
                [0, 1], [0.5 + drift(37, 0.12), 1], [1, 1]
            ],
            colors: [
                top, top, top,
                middle, top, middle,
                bottom, middle, bottom
            ]
        )
    }
}
