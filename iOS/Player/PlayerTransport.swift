//
// PlayerTransport (iOS)
//
// The Now Playing transport row: bare glyphs, no button chrome, laid out the
// way Apple Music lays them out — previous / play / next, each centered in an
// equal third of the row. Shuffle and repeat live in the queue panel's
// header, as they do there.
//

import SwiftUI

struct PlayerTransport: View {
    let palette: PlayerPalette
    let playbackManager: PlaybackManager
    let playlistManager: PlaylistManager
    @ObservedObject private var playbackPresentation: PlaybackPresentationObservation

    init(
        palette: PlayerPalette,
        playbackManager: PlaybackManager,
        playlistManager: PlaylistManager
    ) {
        self.palette = palette
        self.playbackManager = playbackManager
        self.playlistManager = playlistManager
        playbackPresentation = playbackManager.presentationObservation
    }

    private var hasTrack: Bool {
        playbackPresentation.currentTrack != nil
    }

    var body: some View {
        HStack(spacing: 0) {
            transportButton(Icons.backwardFill, size: min(transportIconSize, 44)) {
                playlistManager.playPreviousTrack()
            }
            .accessibilityLabel(String(localized: "Previous"))
            .frame(maxWidth: .infinity)

            playPauseButton
                .frame(maxWidth: .infinity)

            transportButton(Icons.forwardFill, size: min(transportIconSize, 44)) {
                playlistManager.playNextTrack()
            }
            .accessibilityLabel(String(localized: "Next"))
            .frame(maxWidth: .infinity)
        }
    }

    /// The transport is a fixed composition: the glyphs scale with Dynamic
    /// Type but each stays inside the frame its button owns (62/44 pt).
    /// The caps below are those frames minus a small margin.
    @ScaledMetric(relativeTo: .title) private var playPauseIconSize: CGFloat = 42
    @ScaledMetric(relativeTo: .title) private var transportIconSize: CGFloat = 32

    // MARK: - Center

    private var playPauseButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            playbackManager.togglePlayPause()
        } label: {
            Image(systemName: playbackPresentation.isPlaying ? Icons.pauseFill : Icons.playFill)
                .font(.system(size: min(playPauseIconSize, 56)))
                .foregroundColor(palette.foreground)
                .contentTransition(.symbolEffect(.replace.offUp))
                .frame(width: 62, height: 62)
                .contentShape(Rectangle())
        }
        .buttonStyle(TransportButtonStyle())
        .disabled(!hasTrack)
        .accessibilityLabel(
            playbackPresentation.isPlaying ? String(localized: "Pause") : String(localized: "Play")
        )
    }

    private func transportButton(_ icon: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: size))
                .foregroundColor(palette.foreground)
                .frame(width: 44, height: 56)
                .contentShape(Rectangle())
        }
        .buttonStyle(TransportButtonStyle())
        .disabled(!hasTrack)
    }
}

/// Press feedback for the bare transport glyphs: they dim and shrink slightly
/// instead of drawing a highlight, since they have no background to highlight.
struct TransportButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
