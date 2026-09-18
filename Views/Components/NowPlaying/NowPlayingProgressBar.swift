//
// NowPlayingProgressBar
//
// A compact, self-contained, artwork-tinted seek bar shared by the mini player
// and immersive mode.
//
// The seek math (drag/tap position → time, playhead → fill fraction) lives in
// the shared SeekScrub module, same as the main player's progress slider.
//

import SwiftUI

struct NowPlayingProgressBar: View {
    /// Fill color for the progress track / handle: the host's resolved, legible
    /// control color (or accent when tinting is disabled).
    let accent: Color
    /// Base color for the time labels (white on the mini player's dark scrim;
    /// adaptive in immersive mode).
    var neutral: Color = .white
    var scale: CGFloat = 1

    @EnvironmentObject var playbackManager: PlaybackManager
    @EnvironmentObject var playbackProgressState: PlaybackProgressState

    @State private var isDraggingProgress = false
    @State private var tempProgressValue: Double = 0
    @State private var hoveredOverProgress = false

    var body: some View {
        HStack(spacing: 8 * scale) {
            Text(HelperUtils.formattedDuration(isDraggingProgress ? tempProgressValue : playbackProgressState.currentTime))
                .font(.system(size: 10 * scale, weight: .medium))
                .foregroundColor(neutral.opacity(0.8))
                .monospacedDigit()
                .frame(width: timeLabelWidth, alignment: .trailing)

            progressSlider

            Text(HelperUtils.formattedDuration(playbackManager.currentTrack?.duration ?? 0))
                .font(.system(size: 10 * scale, weight: .medium))
                .foregroundColor(neutral.opacity(0.8))
                .monospacedDigit()
                .frame(width: timeLabelWidth, alignment: .leading)
        }
    }

    private var progressSlider: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Background track
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(0.3))
                    .frame(height: 4 * scale)

                // Progress track
                RoundedRectangle(cornerRadius: 2)
                    .fill(accent)
                    .frame(width: geometry.size.width * progressPercentage, height: 4 * scale)
                    .animation(isDraggingProgress ? .none : .easeInOut(duration: 0.2), value: progressPercentage)

                // Drag handle
                Circle()
                    .fill(accent)
                    .frame(width: 10 * scale, height: 10 * scale)
                    .opacity(isDraggingProgress || hoveredOverProgress ? 1.0 : 0.0)
                    .offset(x: (geometry.size.width * progressPercentage) - (5 * scale))
                    .animation(isDraggingProgress ? .none : .easeInOut(duration: 0.2), value: progressPercentage)
                    .animation(.easeInOut(duration: 0.15), value: hoveredOverProgress)
            }
            .contentShape(Rectangle())
            .gesture(progressDragGesture(in: geometry))
            .onTapGesture { value in
                handleProgressTap(at: value.x, in: geometry.size.width)
            }
            .onHover { hovering in
                hoveredOverProgress = hovering
            }
        }
        .frame(height: 10 * scale)
        .disabled(playbackManager.currentTrack == nil)
    }

    // MARK: - Helpers

    private var timeLabelWidth: CGFloat {
        ((playbackManager.currentTrack?.duration ?? 0) >= 3600 ? 50 : 36) * scale
    }

    private var progressPercentage: Double {
        SeekScrub.fillFraction(
            currentTime: playbackProgressState.currentTime,
            duration: playbackManager.currentTrack?.duration ?? 0,
            scrubbing: isDraggingProgress,
            scrubTime: tempProgressValue
        )
    }

    private func progressDragGesture(in geometry: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if !isDraggingProgress {
                    isDraggingProgress = true
                }
                tempProgressValue = SeekScrub.seekTime(
                    position: Double(value.location.x),
                    width: Double(geometry.size.width),
                    duration: playbackManager.currentTrack?.duration ?? 0
                )
            }
            .onEnded { value in
                playbackManager.seekTo(time: SeekScrub.seekTime(
                    position: Double(value.location.x),
                    width: Double(geometry.size.width),
                    duration: playbackManager.currentTrack?.duration ?? 0
                ))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isDraggingProgress = false
                }
            }
    }

    private func handleProgressTap(at x: CGFloat, in width: CGFloat) {
        guard playbackManager.currentTrack != nil else { return }
        playbackManager.seekTo(time: SeekScrub.seekTime(
            position: Double(x),
            width: Double(width),
            duration: playbackManager.currentTrack?.duration ?? 0
        ))
    }
}
