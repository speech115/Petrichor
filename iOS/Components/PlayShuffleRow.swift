//
// PlayShuffleRow (iOS)
//
// The prominent Play + Shuffle action pair shared by the album, artist and
// playlist headers. Play starts the content in its natural order; Shuffle
// starts it in a locally shuffled order without touching the user's
// shuffle setting.
//

import SwiftUI

struct PlayShuffleRow: View {
    let onPlay: () -> Void
    let onShuffle: () -> Void
    var playDisabled = false

    var body: some View {
        HStack(spacing: 16) {
            Button(action: onPlay) {
                Label(String(localized: "Play"), systemImage: Icons.playFill)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(playDisabled)

            Button(action: onShuffle) {
                Label(String(localized: "Shuffle"), systemImage: Icons.shuffleFill)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(playDisabled)
        }
    }
}
