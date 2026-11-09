import SwiftUI

/// The album, artist and playlist pages share one look, after the Music app:
/// a large cover, a bold title, Play and Shuffle in gray, and the cover's
/// colors washing the page.
enum DetailPageStyle {
    static let artworkSize: CGFloat = 200
    static let titleFont = Font.system(size: 28, weight: .bold)
}

/// The detail pages' actions as in the Music app: Play as a gray capsule with
/// its label, Shuffle as a round gray button beside it. `extra` adds
/// page-specific buttons (Edit) in the same gray style.
struct PlayShuffleButtons<Extra: View>: View {
    let onPlay: () -> Void
    let onShuffle: () -> Void
    var isDisabled = false
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onPlay) {
                Label("Play", systemImage: Icons.playFill)
                    .padding(.horizontal, 8)
            }
            .buttonBorderShape(.capsule)
            .disabled(isDisabled)

            Button(action: onShuffle) {
                Image(systemName: Icons.shuffleFill)
            }
            .buttonBorderShape(.circle)
            .disabled(isDisabled)
            .help("Shuffle")

            extra()
                .buttonBorderShape(.capsule)
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.primary)
        .buttonStyle(.bordered)
        .controlSize(.large)
    }
}

extension PlayShuffleButtons where Extra == EmptyView {
    init(onPlay: @escaping () -> Void, onShuffle: @escaping () -> Void, isDisabled: Bool = false) {
        self.init(onPlay: onPlay, onShuffle: onShuffle, isDisabled: isDisabled) { EmptyView() }
    }
}

extension View {
    /// The window background with the cover's colors washing the page from the
    /// window's top edge and fading out downward, as on the iPhone detail pages.
    func artworkWash(_ colors: [Color]) -> some View {
        background {
            ZStack {
                Color(platformColor: .windowBackgroundColor)
                if !colors.isEmpty {
                    GradientBackground(colors: colors)
                        .mask(LinearGradient(colors: [.black, .black.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom))
                        .transaction { $0.animation = nil }
                }
            }
            // Up to the window's top edge: no blank title-bar strip above the wash.
            .ignoresSafeArea(.container, edges: .top)
        }
    }
}
