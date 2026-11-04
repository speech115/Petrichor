import SwiftUI

/// The player bar's seek bar (time labels + slider), extracted so it alone carries the
/// `playbackProgressState` subscription. That keeps the ~10Hz progress ticks from
/// re-rendering the whole player bar during playback, matching NowPlayingProgressBar.
struct PlayerProgressBar: View {
    /// Fill color for the progress track / handle (the resolved control color).
    let accent: Color

    @EnvironmentObject var playbackManager: PlaybackManager
    @EnvironmentObject var playbackProgressState: PlaybackProgressState

    @State private var isDraggingProgress = false
    @State private var tempProgressValue: Double = 0
    @State private var hoveredOverProgress = false

    var body: some View {
        HStack(spacing: 8) {
            // Current time
            Text(HelperUtils.formattedDuration(isDraggingProgress ? tempProgressValue : playbackProgressState.currentTime))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .monospacedDigit()
                .frame(width: timeLabelWidth, alignment: .trailing)

            // Progress slider
            progressSlider

            // Total duration
            Text(HelperUtils.formattedDuration(playbackManager.currentTrack?.duration ?? 0))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .monospacedDigit()
                .frame(width: timeLabelWidth, alignment: .leading)
        }
        .onChange(of: playbackManager.currentTrack?.id) {
            isDraggingProgress = false
            tempProgressValue = 0
        }
    }

    /// Widens the time labels when the current track is an hour or longer so the
    /// `H:MM:SS` form isn't clipped; otherwise keeps the compact `M:SS` width.
    private var timeLabelWidth: CGFloat {
        (playbackManager.currentTrack?.duration ?? 0) >= 3600 ? 56 : 40
    }

    private var progressSlider: some View {
        ZStack {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background track
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.2))
                        .frame(height: 4)

                    // Progress track
                    RoundedRectangle(cornerRadius: 2)
                        .fill(accent)
                        .frame(
                            width: geometry.size.width * progressPercentage,
                            height: 4
                        )
                        .animation(isDraggingProgress ? .none : .easeInOut(duration: 0.2), value: progressPercentage)

                    // Drag handle
                    Circle()
                        .fill(accent)
                        .frame(width: 12, height: 12)
                        .opacity(isDraggingProgress || hoveredOverProgress ? 1.0 : 0.0)
                        .offset(x: (geometry.size.width * progressPercentage) - 6)
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
        }
        .frame(height: 10)
        .frame(maxWidth: 400)
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
                // Reset dragging state after seek completes
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isDraggingProgress = false
                }
            }
    }

    private func handleProgressTap(at x: CGFloat, in width: CGFloat) {
        playbackManager.seekTo(time: SeekScrub.seekTime(
            position: Double(x),
            width: Double(width),
            duration: playbackManager.currentTrack?.duration ?? 0
        ))
    }
}
