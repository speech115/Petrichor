import SwiftUI
import Foundation

/// How the artwork-derived gradient behind the main player bar is drawn. Only takes
/// effect while "Tint interface with album artwork colors" is enabled.
enum PlayerBarBackgroundStyle: String, CaseIterable {
    case behindArtwork = "Behind album art"
    case fullWidth = "Full width"

    var displayName: String {
        switch self {
        case .behindArtwork: return String(localized: "Behind album art")
        case .fullWidth: return String(localized: "Full width")
        }
    }
}

/// Artwork-tinted backdrop for the main player bar. Kept separate (and Equatable) so
/// it only re-renders when the colors or style actually change, not on the play/pause
/// and progress-time updates that re-render the surrounding PlayerView body.
private struct PlayerBarBackground: View, Equatable {
    let colors: [Color]
    let style: PlayerBarBackgroundStyle

    var body: some View {
        if !colors.isEmpty {
            GeometryReader { geometry in
                if style == .fullWidth {
                    // Spread the artwork colors across the whole bar as a soft wash
                    // (mesh on macOS 15+, radial fallback below).
                    GradientBackground(colors: colors)
                } else {
                    RadialGradient(
                        colors: colors + [.clear],
                        center: .leading,
                        startRadius: 0,
                        endRadius: geometry.size.width * 0.25
                    )
                    .overlay(FocusStableMaterial())
                }
            }
            .animation(.easeInOut(duration: AnimationDuration.standardDuration), value: colors)
        }
    }
}

struct PlayerView: View {
    @EnvironmentObject var playbackManager: PlaybackManager
    @EnvironmentObject var playlistManager: PlaylistManager
    @Binding var rightSidebarContent: RightSidebarContent

    @Environment(\.scenePhase)
    var scenePhase
    @Environment(\.colorScheme)
    var colorScheme

    @AppStorage("useArtworkColors")
    private var useArtworkColors = true

    @AppStorage("tintPlaybackControls")
    private var tintPlaybackControls = true

    @AppStorage("playerBarBackgroundStyle")
    private var playerBarBackgroundStyle: PlayerBarBackgroundStyle = .fullWidth

    @State private var gradientColors: [Color] = []
    @State private var gradientRevision: UInt64 = 0
    @State private var playButtonPressed = false
    @State private var previousVolume: Float = 0.7
    @State private var isDraggingVolume = false

    var body: some View {
        ZStack {
            // Artwork-tinted backdrop, isolated into its own equatable view so the
            // frequent play/pause and progress-time re-renders of this body don't
            // re-evaluate (and visibly flash) the gradient and material.
            PlayerBarBackground(colors: gradientColors, style: playerBarBackgroundStyle)
                .equatable()

            // Content layer
            HStack(spacing: 20) {
                // Left section: Album art and track info
                leftSection

                Spacer()

                // Center section: Playback controls and progress
                centerSection

                Spacer()

                // Right section: Volume and queue controls
                rightSection
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            setupInitialState()
        }
        .onChange(of: playbackManager.currentTrack?.id) {
            updateGradientColors()
        }
        .onChange(of: colorScheme) {
            updateGradientColors()
        }
        .onChange(of: useArtworkColors) {
            updateGradientColors()
        }
    }

    // MARK: - View Sections

    private var leftSection: some View {
        HStack(spacing: 16) {
            albumArtwork
            trackDetails
        }
        .frame(width: 320, alignment: .leading)
    }

    private var centerSection: some View {
        VStack(spacing: 8) {
            playbackControls
            PlayerProgressBar(accent: controlAccent)
        }
        .frame(maxWidth: 500)
    }

    private var rightSection: some View {
        HStack(spacing: 12) {
            lyricsButton
            volumeControl
            queueButton
            #if os(macOS)
            miniPlayerButton
            immersiveButton
            #endif
        }
        .frame(width: 320, alignment: .trailing)
    }

    // MARK: - Left Section Components

    private var albumArtwork: some View {
        let trackArtworkInfo = playbackManager.currentTrack.map { track in
            TrackArtworkInfo(id: track.id, artworkData: track.artworkData)
        }

        return PlayerAlbumArtView(
            trackInfo: trackArtworkInfo,
            contextMenuItems: currentTrackContextMenuItems
        ) {
            if let currentTrack = playbackManager.currentTrack {
                NotificationCenter.default.post(
                    name: NSNotification.Name("ShowTrackInfo"),
                    object: nil,
                    userInfo: ["track": currentTrack]
                )
            }
        }
        .equatable()
    }

    private var trackDetails: some View {
        PlayerTrackDetailsView(
            track: playbackManager.currentTrack,
            contextMenuItems: currentTrackContextMenuItems,
            playlistManager: playlistManager
        )
        .equatable()
    }

    // MARK: - Center Section Components

    private var playbackControls: some View {
        HStack(spacing: 12) {
            shuffleButton
            previousButton
            playPauseButton
            nextButton
            repeatButton
        }
    }

    private var shuffleButton: some View {
        Button(action: {
            playlistManager.toggleShuffle()
        }, label: {
            Image(systemName: Icons.shuffleFill)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(playlistManager.isShuffleEnabled ? controlAccent : Color.secondary)
                .frame(width: 32, height: 32)
                .activeControlIndicator(isActive: playlistManager.isShuffleEnabled, color: controlAccent)
        })
        .buttonStyle(ControlButtonStyle())
        .hoverEffect(scale: 1.1)
        .disabled(playbackManager.currentTrack == nil)
        .help(playlistManager.isShuffleEnabled ? String(localized: "Disable Shuffle") : String(localized: "Enable Shuffle"))
    }

    private var previousButton: some View {
        Button(action: {
            playlistManager.playPreviousTrack()
        }, label: {
            Image(systemName: Icons.backwardFill)
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(controlsTinted ? controlAccent : .primary)
                .frame(width: 32, height: 32)
        })
        .buttonStyle(ControlButtonStyle())
        .tint(controlsTinted ? controlAccent : .primary)
        .hoverEffect(scale: 1.1)
        .disabled(playbackManager.currentTrack == nil)
        .help("Previous")
    }

    private var playPauseButton: some View {
        Button(action: {
            playbackManager.togglePlayPause()
        }, label: {
            PlayPauseIcon(isPlaying: playbackManager.isPlaying)
                .frame(width: 42, height: 42)
                .background(
                    Circle()
                        .fill(controlTint)
                        .shadow(color: controlTint.opacity(0.3), radius: 6, x: 0, y: 3)
                )
        })
        .buttonStyle(PlainButtonStyle())
        .hoverEffect(scale: 1.1)
        .scaleEffect(playButtonPressed ? 0.95 : 1.0)
        .animation(.easeInOut(duration: AnimationDuration.quickDuration), value: playButtonPressed)
        .onLongPressGesture(
            minimumDuration: 0,
            maximumDistance: .infinity,
            pressing: { pressing in
                playButtonPressed = pressing
            },
            perform: {}
        )
        .disabled(playbackManager.currentTrack == nil)
        .help(playbackManager.isPlaying ? String(localized: "Pause") : String(localized: "Play"))
        .id("playPause")
    }

    private var nextButton: some View {
        Button(action: {
            playlistManager.playNextTrack()
        }, label: {
            Image(systemName: Icons.forwardFill)
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(controlsTinted ? controlAccent : .primary)
                .frame(width: 32, height: 32)
        })
        .buttonStyle(ControlButtonStyle())
        .tint(controlsTinted ? controlAccent : .primary)
        .hoverEffect(scale: 1.1)
        .help("Next")
        .disabled(playbackManager.currentTrack == nil)
    }

    private var repeatButton: some View {
        Button(action: {
            playlistManager.toggleRepeatMode()
        }, label: {
            Image(systemName: Icons.repeatIcon(for: playlistManager.repeatMode))
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(playlistManager.repeatMode != .off ? controlAccent : Color.secondary)
                .frame(width: 32, height: 32)
                .activeControlIndicator(isActive: playlistManager.repeatMode != .off, color: controlAccent)
        })
        .buttonStyle(ControlButtonStyle())
        .hoverEffect(scale: 1.1)
        .help(playlistManager.repeatMode.tooltip)
        .disabled(playbackManager.currentTrack == nil)
    }

    // MARK: - Right Section Components

    private var volumeControl: some View {
        HStack(spacing: 8) {
            volumeButton
            volumeSlider
        }
    }

    private var volumeButton: some View {
        Button(action: toggleMute) {
            Image(systemName: volumeIcon)
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(scale: 1.1)
        .help(isMuted ? String(localized: "Unmute") : String(localized: "Mute"))
    }

    private var volumeSlider: some View {
        Slider(
            value: Binding(
                get: { playbackManager.volume },
                set: { newVolume in
                    // Save previous volume before changing
                    if playbackManager.volume > 0.01 {
                        previousVolume = playbackManager.volume
                    }

                    playbackManager.setVolume(newVolume)
                }
            ),
            in: 0...1
        ) { editing in
                isDraggingVolume = editing
        }
        .frame(width: 100)
        .controlSize(.small)
        .tint(controlAccent)
        .overlay(alignment: .leading) {
            if isDraggingVolume {
                Text(playbackManager.volume.formatted(.percent.precision(.fractionLength(0))))
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(platformColor: .windowBackgroundColor))
                            .shadow(radius: 2)
                    )
                    .offset(x: 100 * CGFloat(playbackManager.volume) - 15, y: -25)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.1), value: playbackManager.volume)
            }
        }
    }

    private var queueButton: some View {
        Button(action: {
            rightSidebarContent = rightSidebarContent == .queue ? .none : .queue
        }, label: {
            Image(systemName: Icons.queueList)
                .font(.system(size: 16))
                .foregroundColor(rightSidebarContent == .queue ? .white : .secondary)
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill(rightSidebarContent == .queue ? controlTint : Color.secondary.opacity(0.1))
                )
        })
        .buttonStyle(PlainButtonStyle())
        .hoverEffect(scale: 1.1)
        .help(rightSidebarContent == .queue ? String(localized: "Hide Queue") : String(localized: "Show Queue"))
    }

    private var immersiveButton: some View {
        Button(action: {
            // Routed through ContentView to centralize the open animation + toolbar handling.
            NotificationCenter.default.post(name: .toggleImmersivePlayer, object: nil)
        }, label: {
            Image(systemName: Icons.immersive)
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill(Color.secondary.opacity(0.1))
                )
        })
        .buttonStyle(PlainButtonStyle())
        .disabled(!hasCurrentTrack)
        .opacity(hasCurrentTrack ? 1.0 : 0.5)
        .hoverEffect(scale: hasCurrentTrack ? 1.1 : 1.0)
        .help("Open Immersive Mode")
    }

    #if os(macOS)
    private var miniPlayerButton: some View {
        Button(action: {
            MiniPlayerWindowManager.shared.show()
        }, label: {
            Image(systemName: Icons.miniPlayer)
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill(Color.secondary.opacity(0.1))
                )
        })
        .buttonStyle(PlainButtonStyle())
        .disabled(!hasCurrentTrack)
        .opacity(hasCurrentTrack ? 1.0 : 0.5)
        .hoverEffect(scale: hasCurrentTrack ? 1.1 : 1.0)
        .help("Open Mini Player")
    }
    #endif

    private var lyricsButton: some View {
        Button(action: {
            rightSidebarContent = rightSidebarContent == .lyrics ? .none : .lyrics
        }, label: {
            Image(Icons.customLyrics)
                .foregroundColor(rightSidebarContent == .lyrics ? .white : .secondary)
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill(rightSidebarContent == .lyrics ? controlTint : Color.secondary.opacity(0.1))
                )
        })
        .buttonStyle(PlainButtonStyle())
        .disabled(!hasCurrentTrack)
        .opacity(hasCurrentTrack ? 1.0 : 0.5)
        .hoverEffect(scale: hasCurrentTrack ? 1.1 : 1.0)
        .help(rightSidebarContent == .lyrics ? String(localized: "Hide Lyrics") : String(localized: "Show Lyrics"))
    }

    // MARK: - Computed Properties

    private var hasCurrentTrack: Bool {
        playbackManager.currentTrack != nil
    }

    private var controlsTinted: Bool {
        useArtworkColors && tintPlaybackControls
    }

    /// Raw dominant color used to fill the play/pause button (shared with the mini
    /// player and immersive mode via `NowPlayingArtwork`), or the accent color when
    /// tinting is disabled.
    private var controlTint: Color {
        NowPlayingArtwork.tint(for: playbackManager.currentTrack, useArtworkTint: controlsTinted)
    }

    /// Legible, mode-adjusted dominant color for the secondary controls (shuffle/
    /// repeat active, prev/next, progress, and volume), or the accent color when
    /// tinting is disabled.
    private var controlAccent: Color {
        NowPlayingArtwork.controlColor(for: playbackManager.currentTrack, useArtworkTint: controlsTinted, isDarkBackground: colorScheme == .dark)
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

    private var currentTrackContextMenuItems: [ContextMenuItem] {
        guard let track = playbackManager.currentTrack else { return [] }

        return TrackContextMenu.createPlayerViewMenuItems(
            for: track,
            playlistManager: playlistManager
        )
    }

    // MARK: - Helper Methods

    private func setupInitialState() {
        // Initialize the cached album art

        if !isMuted {
            previousVolume = playbackManager.volume
        }

        updateGradientColors()
    }

    private func updateGradientColors() {
        gradientRevision &+= 1
        let revision = gradientRevision
        guard useArtworkColors,
              let track = playbackManager.currentTrack else {
            gradientColors = []
            return
        }
        let trackID = track.id
        let artworkInput = track.albumArtworkData
        let isDark = colorScheme == .dark
        Task { @MainActor in
            let resolved = await track.backgroundGradientColors(isDark: isDark)
            guard !Task.isCancelled,
                  gradientRevision == revision,
                  playbackManager.currentTrack?.id == trackID,
                  useArtworkColors,
                  playbackManager.currentTrack?.albumArtworkData == artworkInput,
                  (colorScheme == .dark) == isDark else { return }
            gradientColors = resolved
        }
    }

    /// Read from the volume, not kept beside it: the menu's volume commands
    /// change the volume without passing through this view.
    private var isMuted: Bool {
        playbackManager.volume < 0.01
    }

    private func toggleMute() {
        if isMuted {
            // Unmute - restore previous volume
            playbackManager.setVolume(previousVolume)
        } else {
            // Mute - save current volume and set to 0
            previousVolume = playbackManager.volume
            playbackManager.setVolume(0)
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
            PlayerView(
                rightSidebarContent: $rightSidebarContent
            )
            .environmentObject(coordinator.playbackManager)
            .environmentObject(coordinator.playlistManager)
            .environmentObject(coordinator.playbackManager.playbackProgressState)
            .frame(height: 200)
        }
    }

    return PreviewWrapper()
}
