//
// DetailPageWash (iOS)
//
// Full-bleed artwork wash behind playlist/album detail lists — the Music
// iOS 26.4 look: color from the cover fills the page while text stays
// system primary/secondary (black or white). Honors a nil tint when
// useArtworkColors is off or no dominant color exists.
//

import SwiftUI

extension View {
    func detailPageWash(_ tint: Color?) -> some View {
        modifier(DetailPageWashModifier(tint: tint))
    }
}

private struct DetailPageWashModifier: ViewModifier {
    let tint: Color?

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background {
                ZStack {
                    Color(.systemBackground)
                    if let tint {
                        LinearGradient(
                            colors: [
                                tint.opacity(0.55),
                                tint.opacity(0.28),
                                tint.opacity(0.12),
                                tint.opacity(0.04),
                                .clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                }
                .ignoresSafeArea()
            }
    }
}

// MARK: - Fill

extension View {
    /// Apple Music's album and artist pages: the whole page in the cover's
    /// color, text white on a dark color and black on a light one.
    func detailPageFill(_ tint: Color?) -> some View {
        modifier(DetailPageFillModifier(tint: tint))
    }
}

private struct DetailPageFillModifier: ViewModifier {
    let tint: Color?
    @Environment(\.colorScheme) private var systemScheme

    func body(content: Content) -> some View {
        let fill = tint.map(PageFill.init)
        content
            .scrollContentBackground(.hidden)
            .background {
                (fill?.color ?? Color(.systemBackground))
                    .ignoresSafeArea()
            }
            // Always set, never branched: the tint arrives after the first
            // frame and a branch would rebuild the list under the reader.
            .environment(\.colorScheme, fill?.scheme ?? systemScheme)
    }
}

/// The cover color pushed away from the middle so text on it clears 4.5:1:
/// darker under white text, lighter under black.
struct PageFill {
    let color: Color
    let scheme: ColorScheme

    init(tint: Color) {
        let isLight = Self.luminance(of: tint) > 0.5
        scheme = isLight ? .light : .dark
        color = tint.mix(with: isLight ? .white : .black, by: 0.4)
    }

    /// WCAG relative luminance of the color's sRGB components.
    static func luminance(of color: Color) -> Double {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: nil)
        func linear(_ value: CGFloat) -> Double {
            let value = Double(value)
            return value <= 0.039_28 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}
