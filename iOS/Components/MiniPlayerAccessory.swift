//
// MiniPlayerAccessory (iOS)
//
// The tab-bar bottom accessory: artwork and title for the current track, a
// play/pause button, and a swipe gesture (up opens the full player, left/right
// skip). Rasterizes title+artist into one layer so the zoom transition's source
// restore lands them atomically. Extracted from `ContentView` along with the
// zoom source id and the thin progress line.
//

import SwiftUI
import UIKit

/// The zoom source id shared by the mini-player accessory (source) and the full
/// Now Playing surface (destination).
enum NowPlayingZoomID {
    static let player = "now-playing"
}

struct MiniPlayerAccessory: View {
    @Environment(\.tabViewBottomAccessoryPlacement)
    private var placement
    let playbackManager: PlaybackManager
    let playlistManager: PlaylistManager
    @ObservedObject private var playbackPresentation: PlaybackPresentationObservation
    private let playbackProgressState: PlaybackProgressState
    @Binding var showingNowPlaying: Bool
    let zoomNamespace: Namespace.ID

    init(
        playbackManager: PlaybackManager,
        playlistManager: PlaylistManager,
        showingNowPlaying: Binding<Bool>,
        zoomNamespace: Namespace.ID
    ) {
        self.playbackManager = playbackManager
        self.playlistManager = playlistManager
        playbackPresentation = playbackManager.presentationObservation
        playbackProgressState = playbackManager.playbackProgressState
        _showingNowPlaying = showingNowPlaying
        self.zoomNamespace = zoomNamespace
    }

    var body: some View {
        let isCompact = placement == .inline

        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    showingNowPlaying = true
                } label: {
                    HStack(spacing: 12) {
                        artwork(size: isCompact ? 44 : 48)
                            .matchedTransitionSource(id: NowPlayingZoomID.player, in: zoomNamespace)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(playbackPresentation.currentTrack?.title ?? "")
                                .font(isCompact ? .subheadline.weight(.semibold) : .headline)
                                .lineLimit(1)
                            Text(playbackPresentation.currentTrack?.displayArtist ?? "")
                                .font(isCompact ? .caption : .subheadline)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        // Rasterize title+artist into a single layer. They are two
                        // Text nodes, and the zoom transition's source restore
                        // re-registers them in separate passes — the artist line
                        // visibly pops in a beat after the title on collapse. One
                        // Metal texture lands atomically instead (compositingGroup
                        // still drew the two nodes separately, so the artist lag
                        // survived it). The text is a two-line label at most, so
                        // the rasterization cost is negligible.
                        .drawingGroup()
                        // Cross-fade, not a slide: in a 44pt row a horizontal
                        // move reads as a twitch. The track usually changes on
                        // its own at the end of a song, with nobody's finger on
                        // the screen, so the swap needs a bridge more than the
                        // controls need a direction.
                        .id(playbackPresentation.currentTrack?.id)
                        .transition(.opacity)

                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .animation(
                        .easeInOut(duration: AnimationDuration.standardDuration),
                        value: playbackPresentation.currentTrack?.id
                    )
                }
                .accessibilityIdentifier("MiniPlayer")
                .buttonStyle(.plain)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 24)
                        .onEnded { value in
                            let dx = value.translation.width
                            let dy = value.translation.height
                            if abs(dy) > abs(dx), dy < -36 {
                                showingNowPlaying = true
                            } else if abs(dx) > abs(dy) * 1.2, abs(dx) > 28 {
                                if dx < 0 {
                                    playlistManager.playNextTrack()
                                } else {
                                    playlistManager.playPreviousTrack()
                                }
                            }
                        }
                )

                playPauseButton
            }
            .padding(.horizontal, 16)
            .padding(.vertical, isCompact ? 8 : 10)

            if isCompact {
                progressLine
                    .frame(height: 3)
                    .padding(.bottom, 6)
            }
        }
    }

    /// Thin non-interactive progress line under the compact row, like Apple
    /// Music's mini player. The expanded row has no line - Now Playing owns
    /// the scrubber there.
    private var progressLine: some View {
        MiniPlayerProgressLine(
            duration: playbackPresentation.currentTrack?.duration ?? 0,
            playbackProgressState: playbackProgressState
        )
    }

    private var playPauseButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            playbackManager.togglePlayPause()
        } label: {
            // The same morph the full player's transport uses. Without it the
            // icon snapped here and slid there, which shows the moment someone
            // pauses in the mini player and opens the player right after.
            Image(systemName: playbackPresentation.isPlaying ? Icons.pauseFill : Icons.playFill)
                .contentTransition(.symbolEffect(.replace.offUp))
                // The mini player is a fixed 44 pt row: the glyph scales with
                // Dynamic Type but stays inside its button.
                .font(.system(size: min(playPauseIconSize, 30)))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(playbackPresentation.isPlaying ? String(localized: "Pause") : String(localized: "Play"))
    }

    private func artwork(size: CGFloat) -> some View {
        ArtworkTile(
            data: playbackPresentation.currentTrack?.displayArtwork,
            cacheKey: playbackPresentation.currentTrack.map { ArtworkCacheKey.nowPlaying($0.id) },
            cornerRadius: size * 0.15,
            maxPixelSize: 180
        )
        .frame(width: size, height: size)
    }

    @ScaledMetric(relativeTo: .title2) private var playPauseIconSize: CGFloat = 22
}

struct MiniPlayerProgressLine: View {
    let duration: Double
    @ObservedObject var playbackProgressState: PlaybackProgressState

    var body: some View {
        let progress = duration > 0
            ? min(max(playbackProgressState.currentTime / duration, 0), 1)
            : 0

        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.18))
                Capsule()
                    .fill(Color.accentColor.opacity(0.75))
                    .frame(width: geometry.size.width * progress)
                    // Same tween as the player's scrubber: the playhead lands
                    // once per sample, the line has to cross the gap itself.
                    .animation(
                        .linear(duration: playbackProgressState.sampleInterval),
                        value: progress
                    )
            }
        }
        .frame(height: 3)
        .padding(.horizontal, 16)
        .allowsHitTesting(false)
    }
}
