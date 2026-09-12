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
    let playbackManager: PlaybackManager
    @ObservedObject private var playbackPresentation: PlaybackPresentationObservation
    @ObservedObject private var playbackProgressState: PlaybackProgressState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isScrubbing = false
    @State private var scrubTime: Double = 0
    @State private var dragStartTime: Double?
    @State private var releaseTask: Task<Void, Never>?
    /// Wall-clock of the last live seek, so a fast drag seeks the engine at a
    /// bounded rate instead of once per touch frame.
    @State private var lastLiveSeekAt: TimeInterval = 0

    init(palette: PlayerPalette, playbackManager: PlaybackManager) {
        self.palette = palette
        self.playbackManager = playbackManager
        playbackPresentation = playbackManager.presentationObservation
        playbackProgressState = playbackManager.playbackProgressState
    }

    private var duration: Double {
        playbackPresentation.currentTrack?.duration ?? 0
    }

    private var elapsed: Double {
        isScrubbing ? scrubTime : playbackProgressState.currentTime
    }

    /// The scrubber reads to VoiceOver as one element: "Playback position,
    /// 1:23 of 3:45, adjustable". Swiping up or down seeks by a fixed step;
    /// the visible bar and the times are presentation for the same value.
    private static let accessibilitySeekStep: Double = 15

    /// Throttle between live seeks while the finger is down (~8/sec).
    private static let liveSeekInterval: TimeInterval = 0.12

    /// How long the bar stays in "scrubbing" after release so the playhead can
    /// catch up with the seek instead of snapping back for one frame.
    private static let releaseDelay: TimeInterval = 0.12

    var body: some View {
        VStack(spacing: 6) {
            track

            HStack {
                Text(HelperUtils.formattedDuration(elapsed))
                Spacer(minLength: 8)
                Text("-" + HelperUtils.formattedDuration(max(0, duration - elapsed)))
            }
            // A real text style, not a scaled raw size: the audit's Dynamic
            // Type check only recognises fonts linked to a text style, and
            // caption (12 pt) matches the fixed size it replaces. The row
            // grows with the type size; the player layout absorbs it.
            .font(.caption.weight(.medium))
            .monospacedDigit()
            .foregroundColor(palette.secondary)
        }
        .disabled(playbackPresentation.currentTrack == nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Playback position"))
        .accessibilityValue(accessibilityValue)
        // `.accessibilityAdjustableAction` itself adds the adjustable trait.
        .accessibilityAdjustableAction { direction in
            let step = Self.accessibilitySeekStep
            let target: Double
            switch direction {
            case .increment:
                target = min(duration, elapsed + step)
            case .decrement:
                target = max(0, elapsed - step)
            @unknown default:
                return
            }
            scrubTime = target
            playbackManager.seekTo(time: target)
        }
        .onDisappear {
            releaseTask?.cancel()
        }
    }

    private var accessibilityValue: String {
        String(
            localized: "\(HelperUtils.formattedDuration(elapsed)) of \(HelperUtils.formattedDuration(duration))"
        )
    }

    private var track: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.22))
                Capsule()
                    .fill(palette.control)
                    // No minimum width: a floor here left a stub of fill sitting
                    // at 0:00, so the bar never read as being at the very start.
                    .frame(width: geometry.size.width * fraction)
                    .animation(fillAnimation, value: fraction)
            }
            .frame(height: 12)
            .scaleEffect(y: isScrubbing ? 1 : 7 / 12)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(scrubGesture(width: geometry.size.width))
            .animation(
                reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.88),
                value: isScrubbing
            )
        }
        .frame(height: 20)
    }

    /// The playhead arrives once per sample, not once per frame, so the fill
    /// would step half a second at a time. Tweening linearly across exactly one
    /// sampling interval lands each new value just as the next one arrives,
    /// which is what makes the bar move continuously. Off while scrubbing: there
    /// the fill must sit under the finger, not chase it.
    private var fillAnimation: Animation? {
        isScrubbing ? nil : .linear(duration: playbackProgressState.sampleInterval)
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
        // The standard movement threshold ignores taps and stationary touches.
        DragGesture()
            .onChanged { value in
                releaseTask?.cancel()
                if dragStartTime == nil {
                    dragStartTime = elapsed
                    isScrubbing = true
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                }
                guard let dragStartTime else { return }
                let time = SeekScrub.dragTime(
                    startTime: dragStartTime,
                    translation: Double(value.translation.width),
                    width: Double(width),
                    duration: duration
                )
                scrubTime = time
                // Live scrub: the audio follows the finger the way the lock
                // screen's does, not just the bar. Throttled to one seek per
                // interval so a fast drag doesn't flood the engine; the exact
                // final position is still sought on release.
                let now = Date().timeIntervalSinceReferenceDate
                if now - lastLiveSeekAt >= Self.liveSeekInterval {
                    lastLiveSeekAt = now
                    playbackManager.seekTo(time: time)
                }
            }
            .onEnded { value in
                guard let dragStartTime else { return }
                let time = SeekScrub.dragTime(
                    startTime: dragStartTime,
                    translation: Double(value.translation.width),
                    width: Double(width),
                    duration: duration
                )
                scrubTime = time
                playbackManager.seekTo(time: time)
                self.dragStartTime = nil
                lastLiveSeekAt = 0
                // The playhead needs a beat to catch up with the seek; ending
                // the scrub immediately would snap the bar back to the old
                // position for one frame.
                releaseTask?.cancel()
                releaseTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(Int(Self.releaseDelay * 1000)))
                    guard !Task.isCancelled else { return }
                    isScrubbing = false
                }
            }
    }
}
