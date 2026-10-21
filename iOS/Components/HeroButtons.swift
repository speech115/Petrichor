//
// HeroButtons (iOS)
//
// The round and capsule header controls of Apple Music's album and artist
// pages: glass circles around a glyph on either side of a solid Play. Solid
// in the page's primary color with the background color for the glyph, so
// Play stays the strongest mark on a light page and on a filled dark one.
//

import SwiftUI

/// A glass circle around one glyph; the label of a Button or Menu.
struct HeroCircleLabel: View {
    let systemImage: String
    var side: CGFloat = 52

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: side * 0.36, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: side, height: side)
            .glassEffect(.regular.interactive(), in: Circle())
            .contentShape(Circle())
    }
}

/// The solid Play: a capsule with the word, or a large circle with the glyph.
struct HeroPlayButton: View {
    enum Shape { case capsule, circle }

    var shape: Shape = .capsule
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                switch shape {
                case .capsule:
                    Label(String(localized: "Play"), systemImage: Icons.playFill)
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(Color.primary, in: Capsule())
                case .circle:
                    Image(systemName: Icons.playFill)
                        .font(.system(size: 30, weight: .semibold))
                        .frame(width: 72, height: 72)
                        .background(Color.primary, in: Circle())
                        .accessibilityLabel(String(localized: "Play"))
                }
            }
            .foregroundStyle(Color(.systemBackground))
        }
        .buttonStyle(HeroPressStyle())
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.4 : 1)
    }
}

private struct HeroPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
