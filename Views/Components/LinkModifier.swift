import SwiftUI

extension View {
    /// Makes text act as a link, as artist and album names do in Apple Music:
    /// underlined with a pointing hand on hover, `action` on click.
    func link(_ action: @escaping () -> Void) -> some View {
        modifier(LinkModifier(action: action))
    }
}

private struct LinkModifier: ViewModifier {
    let action: () -> Void
    @State private var isHovered = false

    func body(content: Content) -> some View {
        Button(action: action) {
            content
                .underline(isHovered)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}
