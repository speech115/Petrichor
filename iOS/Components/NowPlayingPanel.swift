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
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: (_ translation: CGFloat, _ predictedTranslation: CGFloat) -> Void
    private let content: Content

    init(
        title: String,
        onDismiss: @escaping () -> Void,
        onDragChanged: @escaping (CGFloat) -> Void,
        onDragEnded: @escaping (_ translation: CGFloat, _ predictedTranslation: CGFloat) -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.onDismiss = onDismiss
        self.onDragChanged = onDragChanged
        self.onDragEnded = onDragEnded
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
                        .font(.system(size: min(closeIconSize, 20), weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 44, height: 44)
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

    /// The close glyph scales with Dynamic Type inside its fixed 44 pt button.
    @ScaledMetric(relativeTo: .subheadline) private var closeIconSize: CGFloat = 14

    /// Measured in `.global` for the same reason the player's dismissal is: the
    /// header rides on the surface this drag offsets, so a local translation
    /// would cancel itself out frame by frame.
    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { value in
                onDragChanged(value.translation.height)
            }
            .onEnded { value in
                onDragEnded(
                    value.translation.height,
                    value.predictedEndTranslation.height
                )
            }
    }
}
