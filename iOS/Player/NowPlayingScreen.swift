//
// NowPlayingScreen (iOS)
//
// The full-screen player, laid out the way Apple Music lays its own out: one
// artwork-tinted surface edge to edge, a grabber, the cover as the hero, then
// title, scrubber, transport, volume and the lyrics / AirPlay / queue row.
//
// The surface ignores the safe areas on purpose. The previous version drew
// its gradient inside a NavigationStack's content area, which left the status
// bar and the home indicator painted in the plain window background — the
// white bands above and below the cover. There is no navigation bar here at
// all: the grabber dismisses on tap, a downward drag dismisses on release,
// and the track menu lives next to the title.
//
// Lyrics and the queue rise as panels over the artwork; the cover stays the
// screen's primary element, as the design spec requires.
//

import SwiftUI
import AVKit
import MediaPlayer

struct NowPlayingScreen: View {
    @Binding var isPresented: Bool

    @EnvironmentObject private var playbackManager: PlaybackManager
    @EnvironmentObject private var playlistManager: PlaylistManager

    @AppStorage("useArtworkColors")
    private var useArtworkColors = true

    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    @State private var palette = PlayerPalette.make(for: nil, useArtworkColors: false)
    @State private var paletteTask: Task<Void, Never>?
    @State private var dragOffset: CGFloat = 0
    @State private var showingQueue = false
    @State private var showingLyrics = false

    private var track: Track? {
        playbackManager.currentTrack
    }

    private var panelUp: Bool {
        showingQueue || showingLyrics
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                background

                content(in: geometry.size)
                    .offset(y: max(0, dragOffset))

                if panelUp {
                    panelDismissLayer
                        .transition(.opacity)
                }

                if showingQueue {
                    NowPlayingQueuePanel(
                        accentColor: palette.foreground,
                        onDismiss: { showingQueue = false }
                    )
                    .frame(height: geometry.size.height * 0.7)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                if showingLyrics {
                    NowPlayingLyricsPanel {
                        showingLyrics = false
                    }
                    .frame(height: geometry.size.height * 0.72)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.38, dampingFraction: 0.86), value: showingQueue)
            .animation(.spring(response: 0.38, dampingFraction: 0.86), value: showingLyrics)
        }
        // The player is its own dark surface whatever the app's scheme is, so
        // the system controls inside it (volume slider, AirPlay picker, menus)
        // have to be told which scheme they are being drawn on.
        .preferredColorScheme(.dark)
        .onAppear {
            dragOffset = 0
            playbackManager.setFineProgressSampling(true)
            updatePalette()
        }
        .onDisappear {
            paletteTask?.cancel()
            playbackManager.setFineProgressSampling(false)
        }
        .onChange(of: track?.id) { _, _ in
            updatePalette()
        }
        .onChange(of: track?.artworkData?.count) { _, _ in
            updatePalette()
        }
        .onChange(of: useArtworkColors) { _, _ in
            updatePalette()
        }
    }

    // MARK: - Background

    private var background: some View {
        LinearGradient(colors: palette.gradient, startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.45), value: palette)
    }

    private func updatePalette() {
        paletteTask?.cancel()
        let sourceTrack = track
        let sourceTrackID = sourceTrack?.id
        let shouldUseArtwork = useArtworkColors

        paletteTask = Task { @MainActor in
            let resolved = await Task.detached(priority: .userInitiated) {
                PlayerPalette.make(for: sourceTrack, useArtworkColors: shouldUseArtwork)
            }.value
            guard !Task.isCancelled,
                  track?.id == sourceTrackID,
                  useArtworkColors == shouldUseArtwork else { return }
            palette = resolved
        }
    }

    // MARK: - Content

    private func content(in size: CGSize) -> some View {
        // The cover takes what the controls leave, capped so it never becomes
        // a letterbox on a short screen or a wall on a tall one.
        let artworkSide = min(size.width - 56, size.height * 0.44)

        return VStack(spacing: 0) {
            grabber

            Spacer(minLength: 12)

            artwork
                .frame(width: artworkSide, height: artworkSide)
                .scaleEffect(playbackManager.isPlaying ? 1 : 0.84)
                .animation(
                    reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.72),
                    value: playbackManager.isPlaying
                )

            Spacer(minLength: 12)

            VStack(spacing: 22) {
                titleRow
                PlayerScrubber(palette: palette)
                PlayerTransport(palette: palette)
                volumeRow
                accessoryRow
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 8)
        }
        .padding(.top, 8)
        .padding(.bottom, 16)
        .contentShape(Rectangle())
        .gesture(dismissGesture)
    }

    // MARK: - Grabber

    private var grabber: some View {
        Capsule()
            .fill(Color.white.opacity(0.35))
            .frame(width: 36, height: 5)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .onTapGesture { isPresented = false }
            .accessibilityLabel(String(localized: "Close"))
            .accessibilityAddTraits(.isButton)
    }

    // MARK: - Artwork

    private var artwork: some View {
        ArtworkTile(
            data: track?.displayArtwork,
            cacheKey: track.map { "now-playing-\($0.id)" },
            cornerRadius: 12,
            iconSize: 72,
            maxPixelSize: 960,
            fallbackMaxPixelSize: 180
        )
        .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
    }

    // MARK: - Title

    private var titleRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(track?.title ?? "")
                    .font(.system(size: 21, weight: .bold))
                    .foregroundColor(palette.foreground)
                Text(track?.displayArtist ?? "")
                    .font(.system(size: 21))
                    .foregroundColor(palette.secondary)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)

            if let track {
                chipButton(
                    icon: track.isFavorite ? Icons.starFill : Icons.star,
                    label: String(localized: "Favorite"),
                    isActive: track.isFavorite
                ) {
                    UISelectionFeedbackGenerator().selectionChanged()
                    playlistManager.toggleFavorite(for: track)
                }

                Menu {
                    TrackContextMenuContent(items: contextMenuItems)
                } label: {
                    chipLabel(icon: "ellipsis", isActive: false)
                }
                .accessibilityLabel(String(localized: "Track menu"))
            }
        }
    }

    private func chipButton(
        icon: String,
        label: String,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            chipLabel(icon: icon, isActive: isActive)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func chipLabel(icon: String, isActive: Bool) -> some View {
        Image(systemName: icon)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(isActive ? palette.foreground : palette.secondary)
            .frame(width: 30, height: 30)
            .background(Circle().fill(palette.chip))
            .contentShape(Circle())
    }

    // MARK: - Volume

    private var volumeRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill")
            SystemVolumeSlider(tint: UIColor.white.withAlphaComponent(0.85))
                .frame(height: 24)
            Image(systemName: "speaker.wave.3.fill")
        }
        .font(.system(size: 12))
        .foregroundColor(palette.secondary)
    }

    // MARK: - Lyrics / AirPlay / Queue

    private var accessoryRow: some View {
        HStack(spacing: 0) {
            Button {
                UISelectionFeedbackGenerator().selectionChanged()
                showingLyrics = true
            } label: {
                SymbolImage(Icons.customLyrics)
                    .font(.system(size: 20))
                    .foregroundColor(palette.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(track == nil)
            .accessibilityLabel(String(localized: "Lyrics"))

            AirPlayButton(tint: UIColor.white.withAlphaComponent(0.55))
                .frame(maxWidth: .infinity)
                .frame(height: 44)

            Button {
                UISelectionFeedbackGenerator().selectionChanged()
                showingQueue = true
            } label: {
                Image(systemName: Icons.queueList)
                    .font(.system(size: 20))
                    .foregroundColor(palette.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Queue"))
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Panels

    /// A tap on the artwork area puts a raised panel back down.
    private var panelDismissLayer: some View {
        Color.black.opacity(0.0001)
            .contentShape(Rectangle())
            .onTapGesture {
                showingQueue = false
                showingLyrics = false
            }
    }

    // MARK: - Dismissal

    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard !panelUp else { return }
                dragOffset = max(0, value.translation.height)
            }
            .onEnded { value in
                if !panelUp && (
                    value.translation.height > 90 || value.predictedEndTranslation.height > 200
                ) {
                    isPresented = false
                } else {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.92)) {
                        dragOffset = 0
                    }
                }
            }
    }

    private var contextMenuItems: [ContextMenuItem] {
        guard let track else { return [] }
        return TrackContextMenu.createPlayerViewMenuItems(
            for: track,
            playlistManager: playlistManager
        )
    }
}

// MARK: - System Volume Slider

/// The system volume control: a UIKit `MPVolumeView` stripped to its slider.
/// It reflects the hardware buttons' volume and moves with them, which no
/// custom control can do.
///
/// The knob is replaced with an empty image so only the bar shows, the way
/// Apple Music's volume slider looks — the default round thumb sits proud of
/// the track and reads as a much heavier control than the scrubber above it.
struct SystemVolumeSlider: UIViewRepresentable {
    let tint: UIColor

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.showsRouteButton = false
        view.showsVolumeSlider = true
        view.tintColor = tint
        view.setVolumeThumbImage(UIImage(), for: .normal)
        view.setVolumeThumbImage(UIImage(), for: .highlighted)
        return view
    }

    func updateUIView(_ view: MPVolumeView, context: Context) {
        view.tintColor = tint
    }
}

// MARK: - AirPlay Button

/// The system AirPlay route picker, matching the tint of the surrounding
/// Lyrics / Queue buttons.
struct AirPlayButton: UIViewRepresentable {
    let tint: UIColor

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView(frame: .zero)
        view.tintColor = tint
        view.activeTintColor = tint
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {
        view.tintColor = tint
        view.activeTintColor = tint
    }
}
