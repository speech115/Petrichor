import SwiftUI

/// The capsule's seek line: a thin bar under the title, as in the Music app.
/// Hovering thickens it and shows elapsed and remaining time at its ends.
/// Kept apart so it alone carries the `playbackProgressState` subscription:
/// the ~10 Hz progress ticks re-render this line, not the whole capsule.
struct PlayerProgressBar: View {
    @EnvironmentObject var playbackManager: PlaybackManager
    @EnvironmentObject var playbackProgressState: PlaybackProgressState

    @State private var isDragging = false
    @State private var scrubTime: Double = 0
    @State private var isHovered = false

    private var isExpanded: Bool { isDragging || isHovered }

    var body: some View {
        HStack(spacing: 6) {
            if isExpanded, duration > 0 {
                timeLabel(HelperUtils.formattedDuration(displayedTime))
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.15))
                    Capsule()
                        .fill(Color.primary.opacity(isExpanded ? 0.75 : 0.5))
                        .frame(width: geometry.size.width * fraction)
                }
                .frame(height: isExpanded ? 4 : 2)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(dragGesture(width: geometry.size.width))
                .onTapGesture { location in
                    seek(to: location.x, width: geometry.size.width)
                }
            }

            if isExpanded, duration > 0 {
                timeLabel("-" + HelperUtils.formattedDuration(max(duration - displayedTime, 0)))
            }
        }
        // A taller hit area than the line itself, so the line is easy to grab.
        .frame(height: 10)
        .padding(.bottom, 3)
        .animation(.easeInOut(duration: 0.15), value: isExpanded)
        .onHover { isHovered = $0 }
        .disabled(playbackManager.currentTrack == nil)
        .onChange(of: playbackManager.currentTrack?.id) {
            isDragging = false
            scrubTime = 0
        }
    }

    private func timeLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .fixedSize()
            .transition(.opacity)
    }

    private var duration: Double {
        playbackManager.currentTrack?.duration ?? 0
    }

    private var displayedTime: Double {
        isDragging ? scrubTime : playbackProgressState.currentTime
    }

    private var fraction: Double {
        SeekScrub.fillFraction(
            currentTime: playbackProgressState.currentTime,
            duration: duration,
            scrubbing: isDragging,
            scrubTime: scrubTime
        )
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                isDragging = true
                scrubTime = SeekScrub.seekTime(position: Double(value.location.x), width: Double(width), duration: duration)
            }
            .onEnded { value in
                seek(to: value.location.x, width: width)
                // Hold the scrub position until the player reports the seek.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isDragging = false
                }
            }
    }

    private func seek(to x: CGFloat, width: CGFloat) {
        playbackManager.seekTo(time: SeekScrub.seekTime(position: Double(x), width: Double(width), duration: duration))
    }
}
