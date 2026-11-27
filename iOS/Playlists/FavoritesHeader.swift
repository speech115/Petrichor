//
// FavoritesHeader (iOS)
//
// The top of Music's Favorite Songs page: the large star, the title with its
// small grey star, and the round Shuffle, black Play and round Download
// buttons, closed by a line across the page. Download is a placeholder: the
// library is already on the phone.
//

import SwiftUI

struct FavoritesHeader: View {
    let title: String
    let subtitle: String
    let scroll: FavoritesHeroScroll
    let playDisabled: Bool
    let onPlay: () -> Void
    let onShuffle: () -> Void

    @Environment(\.displayScale) private var displayScale

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

            HStack(spacing: 14) {
                RoundHeaderButton(systemImage: "shuffle", label: String(localized: "Shuffle"), action: onShuffle)
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
                RoundHeaderButton(systemImage: "arrow.down", label: String(localized: "Download")) {}
            }
            .padding(.top, 20)

            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(height: 1 / displayScale)
                .padding(.horizontal, 20)
                .padding(.top, 24)
        }
    }
}

/// Music's 48 pt round grey button beside Play.
private struct RoundHeaderButton: View {
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
            // The star's own empty margin above it stands in for the gap
            // under the bar.
            .scaleEffect(1.118)
            .padding(.horizontal, -16)
            .padding(.top, -48)
            .accessibilityHidden(true)
    }
}
