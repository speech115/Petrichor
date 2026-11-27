//
// ArtworkPlayingIndicator (iOS)
//
// Music's playing mark over a row's cover: five white dots across the middle
// of the artwork. Paused, they sit still as dots; playing, they stretch into
// bars that rise and fall. Reduce Motion keeps them as dots.
//
// The phase is a function of wall-clock time, so a row scrolled back into
// view joins the motion where it is instead of restarting it.
//

import SwiftUI

struct ArtworkPlayingIndicator: View {
    let track: Track
    @ObservedObject var playbackManager: PlaybackManager

    var body: some View {
        if playbackManager.isCurrent(track) {
            // A light dim, so white dots read on a pale cover too.
            ZStack {
                Color.black.opacity(0.25)
                PlayingDots(animating: playbackManager.isPlaying)
            }
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
    }
}

private struct PlayingDots: View {
    var animating: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.playerSurfaceCoversContent) private var playerSurfaceCoversContent

    private static let dot: CGFloat = 4
    private static let tallest: CGFloat = 16
    private static let speeds: [Double] = [6.1, 4.7, 7.3, 5.2, 6.7]
    private static let phases: [Double] = [0, 2.1, 4.3, 1.2, 3.4]

    private var moving: Bool {
        animating && !reduceMotion && !playerSurfaceCoversContent
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !moving)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.5) {
                ForEach(0..<5, id: \.self) { index in
                    Capsule()
                        .fill(.white)
                        .frame(width: Self.dot, height: moving ? height(index, time) : Self.dot)
                }
            }
            .frame(height: Self.tallest)
            .animation(.easeOut(duration: 0.2), value: moving)
        }
        .shadow(color: .black.opacity(0.35), radius: 2)
        .accessibilityHidden(true)
    }

    private func height(_ index: Int, _ time: TimeInterval) -> CGFloat {
        let wave = (sin(time * Self.speeds[index] + Self.phases[index]) + 1) / 2
        return Self.dot + (Self.tallest - Self.dot) * wave
    }
}

extension PlaybackManager {
    /// Whether `track` is the one loaded in the player, matched by database
    /// id and, for tracks without one, by file path.
    func isCurrent(_ track: Track) -> Bool {
        guard let current = currentTrack else { return false }
        if let currentID = current.trackId, let trackID = track.trackId {
            return currentID == trackID
        }
        return current.url.path == track.url.path
    }
}
