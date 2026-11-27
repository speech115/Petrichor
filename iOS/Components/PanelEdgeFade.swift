//
// PanelEdgeFade (iOS)
//
// Queue and lyrics sit straight on the player's artwork-tinted surface, as in
// Apple Music: no card behind them. Their scrolling content dissolves at the
// top and bottom edges instead of meeting a hard line above the scrubber.
//

import SwiftUI

extension View {
    func panelEdgeFade(top: CGFloat = 12, bottom: CGFloat = 36) -> some View {
        mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: top)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: bottom)
            }
        }
    }
}
