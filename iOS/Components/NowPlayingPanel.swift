//
// NowPlayingPanel (iOS)
//
// Queue/lyrics surface between the compact track header and player controls.
// Its content scrolls independently.
//
// No header and no close chevron, as in Apple Music: the panel closes from
// the lit Lyrics / Queue button that opened it, or from the small cover above
// it. The chevron used to promise a downward swipe that the player's own
// dismiss gesture had already claimed, so the swipe never closed anything.
//

import SwiftUI

struct NowPlayingPanel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.top, 8)
            .background(.ultraThinMaterial)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24))
            .shadow(color: .black.opacity(0.25), radius: 20, y: -4)
    }
}
