import SwiftUI

/// The main window's player, as in the Music app on macOS 27: a floating glass
/// capsule centered over the content. Transport on the left, the "LCD" (cover,
/// title, "artist — album" and a thin seek line) in the middle, panel toggles
/// and volume on the right. Controls are monochrome; the accent marks only what
/// is switched on (shuffle, repeat, an open panel).
struct PlayerView: View {
    @EnvironmentObject var playbackManager: PlaybackManager
    @EnvironmentObject var playlistManager: PlaylistManager
    @Binding var rightSidebarContent: RightSidebarContent

    @State private var previousVolume: Float = 0.7
    @State private var showingVolume = false

    /// Fixed height of the capsule; the content column reserves it at the bottom.
    static let height: CGFloat = 56

    var body: some View {
        HStack(spacing: 6) {
            transport

            PlayerLCD(
                track: playbackManager.currentTrack,
                artwork: playbackManager.nowPlayingArtwork.shown,
                contextMenuItems: currentTrackContextMenuItems,
                playlistManager: playlistManager
            )
            .equatable()
            .overlay(alignment: .bottom) {
                PlayerProgressBar()
                    .padding(.leading, PlayerLCD.textInset)
                    .padding(.trailing, 8)
            }
            .frame(minWidth: 160, maxWidth: 380)

            panelButtons
        }
        .padding(.horizontal, 10)
        .frame(height: Self.height)
        .floatingControlClusterBackground()
        .shadow(color: .black.opacity(0.12), radius: 16, x: 0, y: 6)
        .onAppear {
            if !isMuted { previousVolume = playbackManager.volume }
        }
    }

    // MARK: - Transport

    private var transport: some View {
        HStack(spacing: 2) {
            capsuleButton(
                Icons.shuffleFill,
                size: 13,
                isActive: playlistManager.isShuffleEnabled,
                help: playlistManager.isShuffleEnabled ? String(localized: "Disable Shuffle") : String(localized: "Enable Shuffle")
            ) { playlistManager.toggleShuffle() }

            capsuleButton(Icons.backwardFill, size: 16, help: String(localized: "Previous")) {
                playlistManager.playPreviousTrack()
            }

            Button {
                playbackManager.togglePlayPause()
            } label: {
                PlayPauseIcon(isPlaying: playbackManager.isPlaying, size: 20, color: .primary)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(ControlButtonStyle())
            .disabled(!hasCurrentTrack)
            .help(playbackManager.isPlaying ? String(localized: "Pause") : String(localized: "Play"))
            .id("playPause")

            capsuleButton(Icons.forwardFill, size: 16, help: String(localized: "Next")) {
                playlistManager.playNextTrack()
            }

            capsuleButton(
                Icons.repeatIcon(for: playlistManager.repeatMode),
                size: 13,
                isActive: playlistManager.repeatMode != .off,
                help: playlistManager.repeatMode.tooltip
            ) { playlistManager.toggleRepeatMode() }
        }
    }

    // MARK: - Right side

    private var panelButtons: some View {
        HStack(spacing: 2) {
            moreMenu

            capsuleButton(
                Icons.customLyrics,
                isCustomSymbol: true,
                size: 14,
                isActive: rightSidebarContent == .lyrics,
                help: rightSidebarContent == .lyrics ? String(localized: "Hide Lyrics") : String(localized: "Show Lyrics")
            ) {
                rightSidebarContent = rightSidebarContent == .lyrics ? .none : .lyrics
            }

            capsuleButton(
                Icons.queueList,
                size: 14,
                isActive: rightSidebarContent == .queue,
                enabled: true,
                help: rightSidebarContent == .queue ? String(localized: "Hide Queue") : String(localized: "Show Queue")
            ) {
                rightSidebarContent = rightSidebarContent == .queue ? .none : .queue
            }

            volumeButton
        }
    }

    private var moreMenu: some View {
        Menu {
            Button("Open Mini Player") { MiniPlayerWindowManager.shared.show() }
            Button("Open Immersive Mode") {
                // Routed through ContentView to centralize the open animation + toolbar handling.
                NotificationCenter.default.post(name: .toggleImmersivePlayer, object: nil)
            }
            if let track = playbackManager.currentTrack {
                Divider()
                Button("Show Info") { rightSidebarContent = .trackDetail(track) }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!hasCurrentTrack)
        .help("More")
    }

    private var volumeButton: some View {
        Button {
            showingVolume.toggle()
        } label: {
            Image(systemName: volumeIcon)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(ControlButtonStyle())
        .help("Volume")
        .popover(isPresented: $showingVolume, arrowEdge: .top) {
            HStack(spacing: 10) {
                Button(action: toggleMute) {
                    Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                }
                .buttonStyle(.plain)
                .help(isMuted ? String(localized: "Unmute") : String(localized: "Mute"))

                Slider(
                    value: Binding(
                        get: { playbackManager.volume },
                        set: { newVolume in
                            if playbackManager.volume > 0.01 {
                                previousVolume = playbackManager.volume
                            }
                            playbackManager.setVolume(newVolume)
                        }
                    ),
                    in: 0...1
                )
                .controlSize(.small)
                .frame(width: 140)

                Image(systemName: "speaker.wave.3.fill")
                    .foregroundStyle(.secondary)
            }
            .padding(12)
        }
    }

    // MARK: - Building blocks

    /// A borderless glyph button of the capsule. `isActive` paints it with the
    /// accent, the only color the capsule uses.
    private func capsuleButton(
        _ symbol: String,
        isCustomSymbol: Bool = false,
        size: CGFloat,
        isActive: Bool = false,
        enabled: Bool? = nil,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if isCustomSymbol {
                    Image(symbol)
                } else {
                    Image(systemName: symbol)
                }
            }
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(ControlButtonStyle())
        .disabled(!(enabled ?? hasCurrentTrack))
        .help(help)
    }

    private var hasCurrentTrack: Bool {
        playbackManager.currentTrack != nil
    }

    private var currentTrackContextMenuItems: [ContextMenuItem] {
        guard let track = playbackManager.currentTrack else { return [] }
        return TrackContextMenu.createPlayerViewMenuItems(for: track, playlistManager: playlistManager)
    }

    private var volumeIcon: String {
        if isMuted {
            return "speaker.slash.fill"
        } else if playbackManager.volume < 0.33 {
            return "speaker.fill"
        } else if playbackManager.volume < 0.66 {
            return "speaker.wave.1.fill"
        } else {
            return "speaker.wave.2.fill"
        }
    }

    /// Read from the volume, not kept beside it: the menu's volume commands
    /// change the volume without passing through this view.
    private var isMuted: Bool {
        playbackManager.volume < 0.01
    }

    private func toggleMute() {
        if isMuted {
            playbackManager.setVolume(previousVolume)
        } else {
            previousVolume = playbackManager.volume
            playbackManager.setVolume(0)
        }
    }
}

// MARK: - LCD

/// The middle of the capsule: cover, title with the favorite star, and
/// "artist — album" with each half linking to its page. Equatable so the
/// play/pause and volume re-renders of the capsule leave it alone.
private struct PlayerLCD: View, Equatable {
    let track: Track?
    let artwork: NowPlayingArtworkHold.Shown?
    let contextMenuItems: [ContextMenuItem]
    let playlistManager: PlaylistManager

    static let artworkSize: CGFloat = 38
    static let height: CGFloat = 44
    /// Where the text (and the seek line under it) starts.
    static let textInset: CGFloat = artworkSize + 10

    static func == (lhs: PlayerLCD, rhs: PlayerLCD) -> Bool {
        lhs.track?.id == rhs.track?.id
            && lhs.track?.isFavorite == rhs.track?.isFavorite
            && lhs.artwork == rhs.artwork
    }

    var body: some View {
        HStack(spacing: 10) {
            CrossfadeArtwork(artwork: artwork, cornerRadius: 4, iconSize: 14, maxPixelSize: 96)
                .frame(width: Self.artworkSize, height: Self.artworkSize)
                .onTapGesture {
                    guard let track else { return }
                    NotificationCenter.default.post(
                        name: NSNotification.Name("ShowTrackInfo"),
                        object: nil,
                        userInfo: ["track": track]
                    )
                }

            if let track {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(track.title)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(track.title)

                        FavoriteButtonView(trackId: track.id, isFavorite: track.isFavorite) {
                            playlistManager.toggleFavorite(for: track)
                        }
                    }

                    HStack(spacing: 0) {
                        Text(track.displayArtist)
                            .link { TrackContextMenu.goToArtist(of: track) }
                        if !track.displayAlbum.isEmpty {
                            Text(" — ")
                            Text(track.displayAlbum)
                                .link { TrackContextMenu.goToAlbum(of: track) }
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                }
                // Text at the top, the seek line drawn under it at the bottom.
                .padding(.top, 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                Text("Not Playing")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(height: Self.height)
        .contextMenu {
            TrackContextMenuContent(items: contextMenuItems)
        }
    }
}

// MARK: - Custom Button Style

struct ControlButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1.0)
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

#Preview {
    struct PreviewWrapper: View {
        @State private var rightSidebarContent: RightSidebarContent = .none

        var body: some View {
            let coordinator = AppCoordinator()
            PlayerView(rightSidebarContent: $rightSidebarContent)
                .environmentObject(coordinator.playbackManager)
                .environmentObject(coordinator.playlistManager)
                .environmentObject(coordinator.playbackManager.playbackProgressState)
                .padding(40)
        }
    }

    return PreviewWrapper()
}
