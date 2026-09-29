//
// MarqueeText (iOS)
//
// A one-line title that scrolls when it does not fit, the way Apple Music and
// Spotify show a long track name: it rests, slides to the end, rests, slides
// back, edges faded. A wrapped title would push the whole player layout
// around every time the track changes.
//
// Text that fits is drawn plainly. With Reduce Motion the line truncates with
// an ellipsis instead of moving. VoiceOver sees one plain `Text` with the
// full string either way.
//

import SwiftUI

struct MarqueeText: View {
    let text: String
    let font: Font

    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    /// Points per second; slow enough to read while it moves.
    private static let speed: CGFloat = 32
    private static let pause: Double = 1.5
    private static let fadeWidth: CGFloat = 14

    private var overflow: CGFloat { max(0, textWidth - containerWidth) }
    private var scrolls: Bool { overflow > 1 && !reduceMotion }

    var body: some View {
        Text(text)
            .font(font)
            .lineLimit(1)
            .opacity(scrolls ? 0 : 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(widthReader($containerWidth))
            .background(
                Text(text).font(font).fixedSize().hidden().background(widthReader($textWidth))
            )
            .overlay(alignment: .leading) {
                if scrolls {
                    Text(text)
                        .font(font)
                        .fixedSize()
                        .offset(x: offset)
                }
            }
            .clipped()
            .mask(fadeMask)
            .task(id: "\(text)|\(textWidth)|\(containerWidth)|\(reduceMotion)") { await scroll() }
            // One plain text element however many copies are drawn.
            .accessibilityRepresentation { Text(text).font(font) }
    }

    private func widthReader(_ width: Binding<CGFloat>) -> some View {
        GeometryReader { proxy in
            Color.clear.onChange(of: proxy.size.width, initial: true) { _, newWidth in
                width.wrappedValue = newWidth
            }
        }
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
        let distance = overflow + Self.fadeWidth
        let duration = Double(distance / Self.speed)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Self.pause))
            withAnimation(.linear(duration: duration)) { offset = -distance }
            try? await Task.sleep(for: .seconds(duration + Self.pause))
            withAnimation(.linear(duration: duration)) { offset = 0 }
            try? await Task.sleep(for: .seconds(duration))
        }
    }
}
