//
// FavoritesHeader (iOS)
//
// The top of Music's Favorite Songs page: the large star, the title with its
// small grey star, and Music's action row (`MusicActionRow`).
//

import SwiftUI

struct FavoritesHeader: View {
    let title: String
    let subtitle: String
    let scroll: FavoritesHeroScroll
    let playDisabled: Bool
    let onPlay: () -> Void
    let onShuffle: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Same frame as in DetailHeader, whose 16 pt side padding the
            // star's own overhang is measured against.
            FavoritesHeroStar(scroll: scroll)
                .padding(.top, 8)
                .padding(.horizontal, 16)

            VStack(spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(title)
                        .font(.title2.weight(.bold))
                    Image(systemName: "star.fill")
                        .font(.footnote)
                        .foregroundStyle(Color.secondaryText)
                        .accessibilityHidden(true)
                }
                .multilineTextAlignment(.center)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Color.secondaryText)
            }
            .padding(.top, 12)
            .padding(.horizontal, 16)

            MusicActionRow(playDisabled: playDisabled, onPlay: onPlay, onShuffle: onShuffle)
                .padding(.top, 20)
        }
    }
}

// MARK: - Favorites Hero

/// The list's scroll position, read only by the hero star, so scrolling
/// redraws the star and never the screen around it.
@Observable
final class FavoritesHeroScroll {
    /// Points scrolled past the top: negative while the list is pulled down.
    var offset: CGFloat = 0
}

/// Music's large favorites star. Pulled down, it stretches from its bottom
/// edge so its top stays put; scrolled up, it trails the list and softens
/// into a blur as it goes under the bar.
struct FavoritesHeroStar: View {
    let scroll: FavoritesHeroScroll

    var body: some View {
        let offset = scroll.offset
        Image(decorative: "cover-apple-favorites")
            .resizable()
            .aspectRatio(1, contentMode: .fit)
            .visualEffect { content, proxy in
                let side = max(proxy.size.height, 1)
                let pull = max(-offset, 0)
                let push = max(offset, 0)
                return content
                    .scaleEffect(1 + pull / side, anchor: .bottom)
                    .offset(y: push * 0.4)
                    .blur(radius: min(push / 14, 18))
                    .opacity(1 - min(push / side, 1) * 0.6)
            }
            // Music draws the star at 0.589 of the screen width and the star
            // fills 0.527 of its square: the square is drawn 1.118 screens
            // wide. Scaled, not framed — a width read from the container
            // inside a List row sends the collection view into a layout loop.
            // Music runs the page up under the bar: on an iPhone 17 Pro Max
            // with the search field out, the star's top sits at 146 pt and
            // the title at 518 pt. The square's own empty margin above the
            // star is pulled up under the bar to match.
            .scaleEffect(1.118)
            .padding(.horizontal, -16)
            .padding(.top, -124)
            .accessibilityHidden(true)
    }
}
