//
// PlayerBackground (iOS)
//
// The Now Playing surface, built the way Apple Music builds its own: the
// cover, blurred past recognition (`PlayerBackdrop`), drawn three times at
// different sizes and turned slowly in different directions, so its colors
// swirl into one another behind the controls. Each copy is larger than the
// screen's diagonal, so no edge ever shows while it turns. A soft darkening
// towards the bottom keeps the controls legible. Without a cover the
// palette's own tones stand in.
//
// It turns only while the music plays and stands still under Reduce Motion.
// A separate view, so the per-frame timeline redraws the backdrop alone.
//

import SwiftUI

struct PlayerBackground: View {
    let palette: PlayerPalette
    let isPlaying: Bool

    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    /// The cover being faded out after a track change. Apple Music lets the
    /// old wash melt into the new one in place: the new one rises over the
    /// old at full strength underneath, so the surface never dips through a
    /// half-transparent mix of the two.
    @State private var outgoing: UIImage?
    @State private var incomingOpacity: Double = 1

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || !isPlaying)) { timeline in
            let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            GeometryReader { geometry in
                ZStack {
                    tones
                    if let outgoing {
                        // In and out at once: a default fade here would ride
                        // the incoming wash's animation and dim both together.
                        swirl(outgoing, in: geometry.size, at: time)
                            .transition(.identity)
                    }
                    if let backdrop = palette.backdrop {
                        swirl(backdrop, in: geometry.size, at: time)
                            .opacity(incomingOpacity)
                    }
                    LinearGradient(
                        colors: [.black.opacity(0), .black.opacity(0.08), .black.opacity(0.3)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
            }
        }
        .ignoresSafeArea()
        .onChange(of: palette.backdrop) { previous, _ in
            // Start from the old wash at once, outside whatever animation
            // carried the palette change, then fade the new one in.
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) {
                outgoing = previous
                incomingOpacity = 0
            }
            withAnimation(.easeInOut(duration: 1.0)) {
                incomingOpacity = 1
            } completion: {
                outgoing = nil
            }
        }
    }

    private var tones: some View {
        LinearGradient(colors: palette.gradient, startPoint: .top, endPoint: .bottom)
    }

    /// Three copies of the blurred cover, each turning at its own unrelated
    /// pace and direction around a point that drifts a little off centre.
    private func swirl(_ backdrop: UIImage, in size: CGSize, at time: TimeInterval) -> some View {
        let diagonal = hypot(size.width, size.height)

        func angle(_ period: Double, _ phase: Double) -> Angle {
            .radians(time * 2 * .pi / period + phase)
        }

        func layer(scale: CGFloat, period: Double, phase: Double, wander: CGFloat) -> some View {
            Image(uiImage: backdrop)
                .resizable()
                .interpolation(.high)
                .frame(width: diagonal * scale, height: diagonal * scale)
                .rotationEffect(angle(period, phase))
                .offset(
                    x: wander * diagonal * CGFloat(sin(time * 2 * .pi / (period * 0.7))),
                    y: wander * diagonal * CGFloat(cos(time * 2 * .pi / (period * 0.9)))
                )
        }

        return ZStack {
            layer(scale: 1.6, period: 70, phase: 0, wander: 0.05)
            layer(scale: 1.3, period: -53, phase: .pi * 0.6, wander: 0.06)
                .opacity(0.6)
            layer(scale: 1.15, period: 41, phase: .pi * 1.3, wander: 0.04)
                .opacity(0.4)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }
}
