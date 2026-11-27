//
// MusicActionRow (iOS)
//
// Music's playlist actions under the title: a round grey Shuffle, a black
// Play capsule and a round grey Download, closed by a line across the page.
// Shared by Favorite Songs, the other playlists and Discover. Download is a
// placeholder: the library is already on the phone.
//

import SwiftUI

struct MusicActionRow: View {
    var playDisabled = false
    let onPlay: () -> Void
    let onShuffle: () -> Void

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        VStack(spacing: 24) {
            HStack(spacing: 14) {
                RoundActionButton(systemImage: "shuffle", label: String(localized: "Shuffle"), action: onShuffle)
                    .disabled(playDisabled)
                Button(action: onPlay) {
                    Label(String(localized: "Play"), systemImage: Icons.playFill)
                        .font(.headline)
                        .foregroundStyle(Color(.systemBackground))
                        .frame(width: 160, height: 48)
                        .background(Color.primary, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(playDisabled)
                RoundActionButton(systemImage: "arrow.down", label: String(localized: "Download")) {}
            }

            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(height: 1 / displayScale)
                .padding(.horizontal, 20)
        }
    }
}

/// Music's 48 pt round grey button beside Play.
private struct RoundActionButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.primary)
                .frame(width: 48, height: 48)
                .background(Color.primary.opacity(0.09), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
