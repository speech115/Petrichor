//
// DetailHeader (iOS)
//
// Shared detail-page header: artwork slot, title and subtitle, and the
// Play/Shuffle row. Replaces the three per-screen copies (artist photo +
// bio, album artwork + year, playlist mosaic + count).
//
// The background picks up the artwork's dominant color as a vertical
// gradient from the top of the header deep into the page so the cover
// reads continuous with the track list (Music iOS 26.4). The screen
// resolves the color and passes it in (nil renders a plain background).
// The title lives here, under the artwork, not in the navigation bar.
//

import SwiftUI

struct DetailHeader<Artwork: View>: View {
    let onPlay: () -> Void
    let onShuffle: () -> Void
    var playDisabled = false
    var title: String? = nil
    var subtitle: String? = nil
    /// Artwork-derived tint; nil when artwork colors are disabled or the
    /// artwork has no dominant color.
    var tint: Color? = nil

    @ViewBuilder var artwork: () -> Artwork

    var body: some View {
        ZStack(alignment: .top) {
            if let tint {
                LinearGradient(
                    colors: [
                        tint.opacity(0.55),
                        tint.opacity(0.28),
                        tint.opacity(0.08),
                        .clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 520)
                .allowsHitTesting(false)
            }

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
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }
}
