//
// ContinueListeningCard (iOS)
//
// Top of Home: the track the app was on when it was last closed, with the
// position it stopped at, and a tap to carry on from there.
//
// The card does not re-read anything — `AppCoordinator.restorePlaybackState()`
// already primes `PlaybackManager` with the saved track and offset on launch,
// so resuming is the ordinary play toggle and the progress shown is the
// player's own.
//

import SwiftUI

struct ContinueListeningCard: View {
    @EnvironmentObject private var playbackManager: PlaybackManager
    @EnvironmentObject private var playbackProgressState: PlaybackProgressState

    private var track: Track? {
        playbackManager.currentTrack
    }

    private var duration: Double {
        track?.duration ?? 0
    }

    private var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(playbackProgressState.currentTime / duration, 0), 1)
    }

    var body: some View {
        if let track {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: String(localized: "Continue Listening"))

                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    playbackManager.togglePlayPause()
                } label: {
                    card(track)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
            }
        }
    }

    private func card(_ track: Track) -> some View {
        HStack(spacing: 14) {
            ArtworkTile(
                data: track.displayArtwork,
                cacheKey: track.albumId.map { "album-\($0)" },
                cornerRadius: 8,
                iconSize: 22
            )
            .frame(width: 64, height: 64)

            VStack(alignment: .leading, spacing: 6) {
                Text(track.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text(track.displayArtist)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                progressLine
            }

            Image(systemName: playbackManager.isPlaying ? Icons.pauseFill : Icons.playFill)
                .font(.system(size: 24))
                .frame(width: 44, height: 44)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemGroupedBackground)))
        .contentShape(Rectangle())
        .accessibilityLabel(String(localized: "Continue \(track.title)"))
    }

    private var progressLine: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.22))
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: geometry.size.width * progress)
            }
        }
        .frame(height: 3)
        .padding(.top, 2)
    }
}
