//
// EqualizerBars (iOS)
//
// The three animated bars marking the playing track in a row. Read as a
// state, not a control: a static pause icon looks like a button the row
// does not have. Bars animate only while playing and freeze on pause; with
// reduce motion they stay static.
//
// The phase is a function of wall-clock time, not of the row's lifecycle:
// a reused row that scrolls back into view picks up the correct phase
// instead of restarting the cycle.
//

import SwiftUI

struct EqualizerBars: View {
    var animating: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let barHeights: [CGFloat] = [14, 20, 10]
    private static let speeds: [Double] = [6.0, 4.6, 7.4]
    private static let phaseOffsets: [Double] = [0, 2.1, 4.3]

    var body: some View {
        TimelineView(.animation(paused: !(animating && !reduceMotion))) { context in
            let phase = context.date.timeIntervalSinceReferenceDate

            HStack(alignment: .bottom, spacing: 2.5) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: 3, height: Self.barHeights[index])
                        .scaleEffect(
                            y: scale(for: index, phase: phase),
                            anchor: .bottom
                        )
                }
            }
        }
        .frame(width: 18, height: 20)
        .accessibilityHidden(true)
    }

    private func scale(for index: Int, phase: TimeInterval) -> CGFloat {
        let value = sin(phase * Self.speeds[index] + Self.phaseOffsets[index])
        // 0.675 + 0.325 * sin keeps the scale in [0.35, 1.0]: a negative
        // scaleY would flip the capsule below its anchor into the next row.
        return 0.675 + 0.325 * value
    }
}
