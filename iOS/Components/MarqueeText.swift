//
// MarqueeText (iOS)
//
// A one-line title that scrolls when it does not fit, the way Apple Music and
// shows a long track name: it rests, then slides left with a second copy
// following a gap behind it, so the loop closes seamlessly instead of
// bouncing back; edges faded. A wrapped title would push the whole player layout
// around every time the track changes.
//
// Text that fits is drawn plainly. With Reduce Motion the line truncates with
// an ellipsis instead of moving; at accessibility text sizes it wraps, since a
// moving line is unreadable there. VoiceOver sees one plain `Text` with the
// full string either way.
//

import SwiftUI

struct MarqueeText: View {
    let text: String
    let font: Font

    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion
    @Environment(\.dynamicTypeSize)
    private var dynamicTypeSize

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    /// Points per second; slow enough to read while it moves.
    private static let speed: CGFloat = 24
    /// Rest before each pass, long enough to read the start first.
    private static let pause: Double = 3
    /// Space between the end of the title and its repeated copy.
    private static let gap: CGFloat = 48
    private static let fadeWidth: CGFloat = 14

    private var overflow: CGFloat { max(0, textWidth - containerWidth) }
    private var scrolls: Bool { overflow > 1 && !reduceMotion }

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            Text(text).font(font).fixedSize(horizontal: false, vertical: true)
        } else {
            marquee
        }
    }

    private var marquee: some View {
        Text(text)
            .font(font)
            .lineLimit(1)
            .opacity(scrolls ? 0 : 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }, action: { containerWidth = $0 })
            .overlay(alignment: .leading) {
                // Measures the full width while resting, then is the moving
                // copy; the second copy closes the loop.
                HStack(spacing: Self.gap) {
                    Text(text)
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }, action: { textWidth = $0 })
                    if scrolls {
                        Text(text)
                    }
                }
                .font(font)
                .fixedSize()
                .offset(x: offset)
                .opacity(scrolls ? 1 : 0)
            }
            .clipped()
            .mask(fadeMask)
            .task(id: "\(text)|\(textWidth)|\(containerWidth)|\(reduceMotion)") { await scroll() }
            // One plain text element however many copies are drawn.
            .accessibilityRepresentation { Text(text).font(font) }
    }

    /// The trailing edge fades while it overflows; the leading edge only once
    /// the text has moved off it, so a resting title starts crisp.
    @ViewBuilder
    private var fadeMask: some View {
        if scrolls, containerWidth > 0 {
            let fade = Self.fadeWidth / containerWidth
            LinearGradient(
                stops: [
                    .init(color: offset < -1 ? .clear : .black, location: 0),
                    .init(color: .black, location: fade),
                    .init(color: .black, location: 1 - fade),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        } else {
            Color.black
        }
    }

    private func scroll() async {
        offset = 0
        guard scrolls else { return }
        let distance = textWidth + Self.gap
        let duration = Double(distance / Self.speed)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Self.pause))
            guard !Task.isCancelled else { return }
            withAnimation(.linear(duration: duration)) { offset = -distance }
            try? await Task.sleep(for: .seconds(duration))
            // The copy now sits exactly where the original started.
            offset = 0
        }
    }
}
