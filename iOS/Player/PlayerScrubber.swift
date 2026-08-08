//
// PlayerScrubber (iOS)
//
// The Now Playing seek bar. A flat capsule with no visible handle: it grows
// under the finger while scrubbing and settles back when released, the way
// Apple Music's does. Times sit under the ends — elapsed on the left,
// remaining on the right.
//
// The seek math is the shared SeekScrub module; only the presentation is
// local to iOS.
//

import SwiftUI

struct PlayerScrubber: View {
    let palette: PlayerPalette

    @EnvironmentObject private var playbackManager: PlaybackManager
    @EnvironmentObject private var playbackProgressState: PlaybackProgressState

    @State private var isScrubbing = false
    @State private var scrubTime: Double = 0

    private var duration: Double {
        playbackManager.currentTrack?.duration ?? 0
    }

    private var elapsed: Double {
        isScrubbing ? scrubTime : playbackProgressState.currentTime
    }

    var body: some View {
        VStack(spacing: 6) {
            track

            HStack {
                Text(HelperUtils.formattedDuration(elapsed))
                Spacer(minLength: 8)
                Text("-" + HelperUtils.formattedDuration(max(0, duration - elapsed)))
            }
            .font(.system(size: 12, weight: .medium))
            .monospacedDigit()
            .foregroundColor(palette.secondary)
        }
        .disabled(playbackManager.currentTrack == nil)
    }

    private var track: some View {
        GeometryReader { geometry in
            let height: CGFloat = isScrubbing ? 12 : 7

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.22))
                Capsule()
                    .fill(palette.control)
                    .frame(width: max(height, geometry.size.width * fraction))
            }
            .frame(height: height)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(scrubGesture(width: geometry.size.width))
            .animation(.spring(response: 0.28, dampingFraction: 0.8), value: isScrubbing)
        }
        .frame(height: 20)
    }

    private var fraction: Double {
        SeekScrub.fillFraction(
            currentTime: playbackProgressState.currentTime,
            duration: duration,
            scrubbing: isScrubbing,
            scrubTime: scrubTime
        )
    }

    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !isScrubbing {
                    isScrubbing = true
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                }
                scrubTime = SeekScrub.seekTime(
                    position: Double(value.location.x),
                    width: Double(width),
                    duration: duration
                )
            }
            .onEnded { value in
                let time = SeekScrub.seekTime(
                    position: Double(value.location.x),
                    width: Double(width),
                    duration: duration
                )
                scrubTime = time
                playbackManager.seekTo(time: time)
                // The playhead needs a beat to catch up with the seek; ending
                // the scrub immediately would snap the bar back to the old
                // position for one frame.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    isScrubbing = false
                }
            }
    }
}
