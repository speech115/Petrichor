import SwiftUI

/// The album, artist and playlist pages share the iPhone's detail-page look:
/// a large cover, Play and Shuffle as equal capsules, and the cover's colors
/// washing the page.
enum DetailPageStyle {
    static let artworkSize: CGFloat = 200
    static let titleFont = Font.system(size: 28, weight: .bold)
}

/// Play and Shuffle as equal capsules, as on the iPhone: on a long list people
/// press Shuffle, so it must not read as secondary. `extra` adds page-specific
/// buttons (Edit) in the same style.
struct PlayShuffleButtons<Extra: View>: View {
    let onPlay: () -> Void
    let onShuffle: () -> Void
    var isDisabled = false
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onPlay) {
                Label("Play", systemImage: Icons.playFill)
                    .frame(width: 110)
            }
            .disabled(isDisabled)

            Button(action: onShuffle) {
                Label("Shuffle", systemImage: Icons.shuffleFill)
                    .frame(width: 110)
            }
            .disabled(isDisabled)

            extra()
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.tint)
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .tint(.accentColor)
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
    /// top and fading out downward, as on the iPhone detail pages.
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
        }
    }
}
