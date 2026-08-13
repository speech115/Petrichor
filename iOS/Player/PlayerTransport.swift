//
// PlayerTransport (iOS)
//
// The Now Playing transport row: bare glyphs, no button chrome, sized the way
// Apple Music sizes them — previous / play / next centered and large, shuffle
// and repeat small and dim at the flanks.
//
// The flanking buttons sit in fixed-width slots so the centered trio stays
// optically centered whichever repeat glyph is showing.
//

import SwiftUI

struct PlayerTransport: View {
    let palette: PlayerPalette
    let playbackManager: PlaybackManager
    let playlistManager: PlaylistManager
    @ObservedObject private var playbackPresentation: PlaybackPresentationObservation
    @ObservedObject private var playlistTransport: PlaylistTransportObservation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        palette: PlayerPalette,
        playbackManager: PlaybackManager,
        playlistManager: PlaylistManager
    ) {
        self.palette = palette
        self.playbackManager = playbackManager
        self.playlistManager = playlistManager
        playbackPresentation = playbackManager.presentationObservation
        playlistTransport = playlistManager.transportObservation
    }

    private var hasTrack: Bool {
        playbackPresentation.currentTrack != nil
    }

    var body: some View {
        HStack(spacing: 0) {
            shuffleButton
                .frame(width: 56)

            Spacer(minLength: 0)

            HStack(spacing: 34) {
                transportButton(Icons.backwardFill, size: min(transportIconSize, 44)) {
                    playlistManager.playPreviousTrack()
                }
                .accessibilityLabel(String(localized: "Previous"))

                playPauseButton

                transportButton(Icons.forwardFill, size: min(transportIconSize, 44)) {
                    playlistManager.playNextTrack()
                }
                .accessibilityLabel(String(localized: "Next"))
            }

            Spacer(minLength: 0)

            repeatButton
                .frame(width: 56)
        }
    }

    /// The transport is a fixed composition: the glyphs scale with Dynamic
    /// Type but each stays inside the frame its button owns (62/56/34 pt).
    /// The caps below are those frames minus a small margin.
    @ScaledMetric(relativeTo: .title) private var playPauseIconSize: CGFloat = 42
    @ScaledMetric(relativeTo: .title) private var transportIconSize: CGFloat = 32
    @ScaledMetric(relativeTo: .subheadline) private var flankIconSize: CGFloat = 17

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
                .frame(width: 56, height: 56)
                .contentShape(Rectangle())
        }
        .buttonStyle(TransportButtonStyle())
        .disabled(!hasTrack)
    }

    // MARK: - Flanks

    private var shuffleButton: some View {
        modeButton(
            icon: Icons.shuffleFill,
            isActive: playlistTransport.isShuffleEnabled,
            label: String(localized: "Shuffle")
        ) {
            playlistManager.toggleShuffle()
        }
    }

    private var repeatButton: some View {
        modeButton(
            icon: Icons.repeatIcon(for: playlistTransport.repeatMode),
            isActive: playlistTransport.repeatMode != .off,
            label: String(localized: "Repeat")
        ) {
            playlistManager.toggleRepeatMode()
        }
    }

    /// Shuffle and repeat read as toggles: the active state fills a soft
    /// rounded chip behind the glyph instead of only recoloring it, so the
    /// state survives a glance.
    private func modeButton(
        icon: String,
        isActive: Bool,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            UISelectionFeedbackGenerator().selectionChanged()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: min(flankIconSize, 24), weight: .medium))
                .foregroundColor(isActive ? palette.foreground : palette.secondary)
                .contentTransition(.symbolEffect(.replace.offUp))
                .frame(width: 44, height: 44)
                .background {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(palette.chip)
                        .opacity(isActive ? 1 : 0)
                        .animation(
                            reduceMotion ? nil : .easeOut(duration: 0.16),
                            value: isActive
                        )
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(TransportButtonStyle())
        .disabled(!hasTrack)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

/// Press feedback for the bare transport glyphs: they dim and shrink slightly
/// instead of drawing a highlight, since they have no background to highlight.
private struct TransportButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
