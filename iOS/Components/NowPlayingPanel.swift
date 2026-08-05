//
// NowPlayingPanel (iOS)
//
// Bottom panel that lifts over the Now Playing artwork: translucent material,
// rounded top corners and a grabber header. The artwork stays the screen's
// primary element — the panel covers only the lower part. Dismissed by
// swiping down on the header, tapping the artwork area above the panel, or
// the close button; the list content inside scrolls with its own gesture.
//

import SwiftUI

struct NowPlayingPanel<Content: View>: View {
    let title: String
    let onDismiss: () -> Void
    private let content: Content

    @State private var dragOffset: CGFloat = 0

    init(title: String, onDismiss: @escaping () -> Void, @ViewBuilder content: () -> Content) {
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
        .offset(y: max(0, dragOffset))
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 10) {
            Capsule()
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 36, height: 5)
                .padding(.top, 10)

            HStack(spacing: 12) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                Button(action: onDismiss) {
                    Image(systemName: Icons.chevronDown)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(String(localized: "Close"))
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        .contentShape(Rectangle())
        .gesture(dismissGesture)
        .accessibilityAddTraits(.isHeader)
    }

    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                dragOffset = max(0, value.translation.height)
            }
            .onEnded { value in
                if value.translation.height > 80 || value.predictedEndTranslation.height > 160 {
                    onDismiss()
                }
                dragOffset = 0
            }
    }
}
