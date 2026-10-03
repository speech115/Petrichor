//
// MiniPlayerAccessory (iOS)
//
// The tab-bar bottom accessory: artwork and title for the current track, a
// play/pause button, and a swipe gesture (up opens the full player, left/right
// skip). Rasterizes title+artist into one layer so the zoom transition's source
// restore lands them atomically. No progress line, like Apple Music's: Now
// Playing owns the scrubber.
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

        HStack(spacing: 12) {
            Button {
                showingNowPlaying = true
            } label: {
                HStack(spacing: 12) {
                    // One size in both placements: the system accessory is a
                // ~48 pt capsule either way, and a bigger cover was cropped.
                artwork(size: 36)
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

            // Apple Music's transport: bare fill glyphs of one size and
            // weight, no backgrounds, packed close on the trailing side.
            HStack(spacing: 0) {
                playPauseButton
                transportButton(Icons.forwardFill, label: String(localized: "Next")) {
                    playlistManager.playNextTrack()
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private var playPauseButton: some View {
        transportButton(
            playbackPresentation.isPlaying ? Icons.pauseFill : Icons.playFill,
            label: playbackPresentation.isPlaying ? String(localized: "Pause") : String(localized: "Play")
        ) {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            playbackManager.togglePlayPause()
        }
    }

    /// One glyph style for both buttons. The symbol morph on play/pause
    /// is the same one the full player's transport uses, so the icon does not
    /// snap here and slide there. The glyph scales with Dynamic Type but stays
    /// inside its fixed 44 pt row.
    private func transportButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .contentTransition(.symbolEffect(.replace.offUp))
                .font(.system(size: min(transportIconSize, 26), weight: .medium))
                .frame(width: placement == .inline ? 38 : 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
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

    @ScaledMetric(relativeTo: .title2) private var transportIconSize: CGFloat = 22
}
