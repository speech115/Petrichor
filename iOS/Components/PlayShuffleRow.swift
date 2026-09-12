//
// PlayShuffleRow (iOS)
//
// The Play + Shuffle action pair shared by the album, artist and playlist
// headers. Both are tinted capsules of equal weight - on a 1 286-track
// playlist people press Shuffle, so it must not read as a secondary
// control. Play starts the content in its natural order; Shuffle starts it
// in a locally shuffled order without touching the user's shuffle setting.
//

import SwiftUI

struct PlayShuffleRow: View {
    let onPlay: () -> Void
    let onShuffle: () -> Void
    var playDisabled = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 12))
            : AnyLayout(HStackLayout(spacing: 16))
        layout {
            Button(action: onPlay) {
                Label(String(localized: "Play"), systemImage: Icons.playFill)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.accentColor)
            .controlSize(.large)
            .disabled(playDisabled)

            Button(action: onShuffle) {
                Label(String(localized: "Shuffle"), systemImage: Icons.shuffleFill)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.accentColor)
            .controlSize(.large)
            .disabled(playDisabled)
        }
    }
}
