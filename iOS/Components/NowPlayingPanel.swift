//
// NowPlayingPanel (iOS)
//
// Queue/lyrics surface between the compact track header and player controls.
// Its content scrolls independently; the header closes on a downward swipe.
//

import SwiftUI

struct NowPlayingPanel<Content: View>: View {
    let title: String
    let onDismiss: () -> Void
    private let content: Content

    init(
        title: String,
        onDismiss: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.onDismiss = onDismiss
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .background(.ultraThinMaterial)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24))
        .shadow(color: .black.opacity(0.25), radius: 20, y: -4)
    }

    // MARK: - Header

    private var header: some View {
        // No grabber of its own: the player's grabber sits right above this
        // panel and two handles in a row read as one broken control.
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                Button(action: onDismiss) {
                    Image(systemName: Icons.chevronDown)
                        .font(.system(size: min(closeIconSize, 20), weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(String(localized: "Close"))
            }
            .padding(.horizontal, 20)
            .padding(.top, 6)
            .padding(.bottom, 12)
        }
        .contentShape(Rectangle())
        .gesture(dismissGesture)
        .accessibilityAddTraits(.isHeader)
    }

    /// The close glyph scales with Dynamic Type inside its fixed 44 pt button.
    @ScaledMetric(relativeTo: .subheadline) private var closeIconSize: CGFloat = 14

    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onEnded { value in
                if value.translation.height > 80 || value.predictedEndTranslation.height > 160 {
                    onDismiss()
                }
            }
    }
}
