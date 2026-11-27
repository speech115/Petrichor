//
// DetailHeader (iOS)
//
// Shared detail-page header: artwork slot, title and subtitle, and Music's
// action row (Shuffle, Play, Download). Replaces the three per-screen copies (artist photo +
// bio, album artwork + year, playlist mosaic + count).
//
// The screen owns the continuous artwork tint through detailPageWash.
// The title lives here, under the artwork, not in the navigation bar.
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
                .padding(.top, 8)

            if let title, !title.isEmpty {
                Text(title)
                    .font(.title2.weight(.bold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundColor(.secondaryText)
                    .multilineTextAlignment(.center)
            }

            MusicActionRow(playDisabled: playDisabled, onPlay: onPlay, onShuffle: onShuffle)
                .padding(.top, 8)
                // The line under the buttons runs 20 pt from the page edges,
                // not from this header's 16 pt padding.
                .padding(.horizontal, -16)
        }
        .padding(.horizontal, 16)
    }
}
