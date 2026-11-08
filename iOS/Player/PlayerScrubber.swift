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
import UIKit

struct PlayerScrubber: View {
    let palette: PlayerPalette
    let playbackManager: PlaybackManager
    @ObservedObject private var playbackPresentation: PlaybackPresentationObservation
    @ObservedObject private var playbackProgressState: PlaybackProgressState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isScrubbing = false
    @State private var scrubTime: Double = 0
    @State private var dragAnchor: DragAnchor?
    @State private var releaseTask: Task<Void, Never>?
    /// The fill's drawn fraction. Follows `fraction`, tweening only ordinary
    /// playback samples (see `followFraction`).
    @State private var shownFraction: Double = 0

    /// Where a drag started, and on which queue entry. The track keeps playing
    /// under the finger, so it can end mid-drag; the release must not seek the
    /// next play to a position computed for this one. Keyed by entry, not by
    /// song: Repeat One and a duplicate queue row replay the same song.
    private struct DragAnchor {
        let entryID: AudioEntryId?
        let startTime: Double
    }

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
                // A plain rectangle clipped by the track's capsule, the way
                // the system's linear ProgressView draws its fill: near 0:00
                // the sliver follows the track's rounded end instead of being
                // a capsule of its own, which at a few points wide was a hard
                // square stub at the start of a round bar.
                Rectangle()
                    .fill(palette.control)
                    .frame(width: geometry.size.width * shownFraction)
            }
            .frame(height: 12)
            .clipShape(Capsule())
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
        .sensoryFeedback(.impact(flexibility: .soft), trigger: isScrubbing) { _, scrubbing in scrubbing }
        .onAppear { shownFraction = fraction }
        .onChange(of: fraction) { old, new in followFraction(from: old, to: new) }
    }

    /// The playhead arrives once per sample, not once per frame, so the fill
    /// would step half a second at a time. Tweening linearly across exactly one
    /// sampling interval lands each new value just as the next one arrives,
    /// which is what makes the bar move continuously. Everything else lands at
    /// once: under the finger while scrubbing, and on a skip or a seek — a
    /// one-second slide back to 0:00 there kept the bar a beat behind the tap.
    private func followFraction(from old: Double, to new: Double) {
        let interval = playbackProgressState.sampleInterval
        guard !isScrubbing,
              SeekScrub.isPlaybackTick(from: old * duration, to: new * duration, sampleInterval: interval) else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { shownFraction = new }
            return
        }
        withAnimation(.linear(duration: interval)) { shownFraction = new }
    }

    private var fraction: Double {
        SeekScrub.fillFraction(
            currentTime: playbackProgressState.currentTime,
            duration: duration,
            scrubbing: isScrubbing,
            scrubTime: scrubTime
        )
    }

    /// The bar's own pan, not a SwiftUI `DragGesture`: the full player is a
    /// zoom-transition cover whose interactive dismissal is a UIKit pan, and a
    /// SwiftUI drag could not make it wait. With a slight downward drift the
    /// dismiss pan won and the player started closing instead of seeking. A
    /// drag that starts on the bar is a seek, as on the lock screen.
    private func scrubGesture(width: CGFloat) -> ScrubPanGesture {
        ScrubPanGesture(
            onChanged: { dragChanged(translation: $0, width: width) },
            onEnded: { dragEnded(translation: $0, width: width) },
            onCancelled: endCancelledDrag
        )
    }

    private func dragChanged(translation: CGFloat, width: CGFloat) {
        releaseTask?.cancel()
        let entryID = playbackManager.currentEntryId
        if dragAnchor == nil {
            dragAnchor = DragAnchor(entryID: entryID, startTime: elapsed)
            isScrubbing = true
        }
        guard let dragAnchor, dragAnchor.entryID == entryID else {
            isScrubbing = false
            return
        }
        // Only the bar follows the finger; the audio seeks once on release,
        // as on the lock screen. Seeking while dragging replayed audio
        // fragments.
        scrubTime = SeekScrub.dragTime(
            startTime: dragAnchor.startTime,
            translation: Double(translation),
            width: Double(width),
            duration: duration
        )
    }

    private func dragEnded(translation: CGFloat, width: CGFloat) {
        guard let dragAnchor else { return }
        self.dragAnchor = nil
        guard dragAnchor.entryID == playbackManager.currentEntryId else {
            isScrubbing = false
            return
        }
        let time = SeekScrub.dragTime(
            startTime: dragAnchor.startTime,
            translation: Double(translation),
            width: Double(width),
            duration: duration
        )
        scrubTime = time
        playbackManager.seekTo(time: time)
        // The playhead needs a beat to catch up with the seek; ending the
        // scrub immediately would snap the bar back to the old position for
        // one frame.
        releaseTask?.cancel()
        releaseTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Int(Self.releaseDelay * 1000)))
            guard !Task.isCancelled else { return }
            isScrubbing = false
        }
    }

    /// A drag that ended normally has already cleared its anchor in
    /// `dragEnded`. One still anchored was cancelled: the bar returns to the playhead and
    /// the audio stays where it is.
    private func endCancelledDrag() {
        guard dragAnchor != nil else { return }
        dragAnchor = nil
        releaseTask?.cancel()
        isScrubbing = false
    }
}

/// A one-finger pan that every other recognizer touching the bar must wait on,
/// above all the zoom transition's dismiss pan. A pan fails only when the
/// finger lifts without moving, so once a touch on the bar moves, it scrubs;
/// a tap still passes through. Reports the horizontal translation.
private struct ScrubPanGesture: UIGestureRecognizerRepresentable {
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat) -> Void
    let onCancelled: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let translation = recognizer.translation(in: recognizer.view).x
        switch recognizer.state {
        case .began, .changed:
            onChanged(translation)
        case .ended:
            onEnded(translation)
        case .cancelled, .failed:
            onCancelled()
        default:
            break
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            otherGestureRecognizer !== gestureRecognizer
        }
    }
}
