import SwiftUI

struct AppearanceTabView: View {
    @AppStorage("colorMode")
    private var colorMode: ColorMode = .auto

    @AppStorage("useArtworkColors")
    private var useArtworkColors = true

    @AppStorage("playerBarBackgroundStyle")
    private var playerBarBackgroundStyle: PlayerBarBackgroundStyle = .fullWidth

    @AppStorage("tintPlaybackControls")
    private var tintPlaybackControls = true

    @AppStorage("tintNowPlayingBackground")
    private var tintNowPlayingBackground = true

    @AppStorage("miniPlayerAlwaysOnTop")
    private var miniPlayerAlwaysOnTop = false

    /// Leading inset used to nest the options that depend on the master tint toggle.
    private let dependentIndent: CGFloat = 20

    var body: some View {
        Form {
            Section("Visibility") {
                Toggle("Keep Mini Player on top of all other windows", isOn: $miniPlayerAlwaysOnTop)
                    .help("Floats the Mini Player window above windows from other apps")
            }

            Section("Customization") {
                HStack {
                    Text("Color mode")
                    Spacer()
                    TabbedButtons(
                        items: ColorMode.allCases,
                        selection: $colorMode,
                        style: .flexible
                    )
                    .frame(width: 200)
                }

                Toggle("Tint interface with album artwork colors", isOn: $useArtworkColors)
                    .help("Applies a gradient background derived from album artwork colors across the app")

                Picker("Player bar background style", selection: $playerBarBackgroundStyle) {
                    ForEach(PlayerBarBackgroundStyle.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                #if os(macOS)
                .pickerStyle(.radioGroup)
                #else
                .pickerStyle(.menu)
                #endif
                .disabled(!useArtworkColors)
                .padding(.leading, dependentIndent)

                Toggle("Color playback and audio controls", isOn: $tintPlaybackControls)
                    .help("Uses the album artwork's dominant color for playback and volume controls in the player, Mini Player, and Immersive mode")
                    .disabled(!useArtworkColors)
                    .padding(.leading, dependentIndent)

                Toggle("Use artwork background in Mini Player and Immersive mode", isOn: $tintNowPlayingBackground)
                    .help("Uses album artwork colors as the background in Mini Player and Immersive mode")
                    .disabled(!useArtworkColors)
                    .padding(.leading, dependentIndent)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .padding(5)
        .onChange(of: colorMode) { _, newValue in
            newValue.apply()
        }
        .onAppear {
            colorMode.apply()
        }
    }
}

extension ColorMode: TabbedItem {
    var title: String { displayName }
}

#Preview {
    AppearanceTabView()
        .frame(width: 600, height: 500)
}
