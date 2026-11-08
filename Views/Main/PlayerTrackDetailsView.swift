import SwiftUI

struct FavoriteButtonView: View, Equatable {
    let trackId: String
    let isFavorite: Bool
    let onToggle: () -> Void

    static func == (lhs: FavoriteButtonView, rhs: FavoriteButtonView) -> Bool {
        lhs.trackId == rhs.trackId &&
        lhs.isFavorite == rhs.isFavorite
    }

    var body: some View {
        Button(action: onToggle) {
            Image(systemName: isFavorite ? Icons.starFill : Icons.star)
                .font(.system(size: 12))
                .foregroundColor(isFavorite ? .yellow : .secondary)
                .animation(.easeInOut(duration: 0.2), value: isFavorite)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .hoverEffect(scale: 1.15)
        .help(isFavorite ? String(localized: "Remove from Favorites") : String(localized: "Add to Favorites"))
    }
}
