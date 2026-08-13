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
