//
// HeroButtons (iOS)
//
// The round and capsule header controls of Apple Music's album and artist
// pages: glass circles around a glyph on either side of a solid Play. Solid
// white with a black glyph on a dark page and the reverse on a light one, so
// Play stays the strongest mark either way.
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

    /// Black and white from the SwiftUI scheme itself, not semantic UIKit
    /// colors: a filled page overrides the scheme only on the SwiftUI side.
    @Environment(\.colorScheme) private var colorScheme
    private var fill: Color { colorScheme == .dark ? .white : .black }
    private var glyph: Color { colorScheme == .dark ? .black : .white }

    var body: some View {
        Button(action: action) {
            Group {
                switch shape {
                case .capsule:
                    Label(String(localized: "Play"), systemImage: Icons.playFill)
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(fill, in: Capsule())
                case .circle:
                    Image(systemName: Icons.playFill)
                        .font(.system(size: 30, weight: .semibold))
                        .frame(width: 72, height: 72)
                        .background(fill, in: Circle())
                        .accessibilityLabel(String(localized: "Play"))
                }
            }
            .foregroundStyle(glyph)
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
