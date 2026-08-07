//
// DetailHeader (iOS)
//
// Shared detail-page header: artwork slot, optional title and subtitle, and
// the Play/Shuffle row. Replaces the three per-screen copies (artist photo +
// bio, album artwork + year, playlist mosaic + count).
//

import SwiftUI

struct DetailHeader<Artwork: View>: View {
    let onPlay: () -> Void
    let onShuffle: () -> Void
    var playDisabled = false
    var title: String? = nil
    var subtitle: String? = nil

    @ViewBuilder var artwork: () -> Artwork

    var body: some View {
        VStack(spacing: 12) {
            artwork()
                .padding(.top, 16)

            if let title, !title.isEmpty {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
            }

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            PlayShuffleRow(
                onPlay: onPlay,
                onShuffle: onShuffle,
                playDisabled: playDisabled
            )
            .padding(.top, 4)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }
}
