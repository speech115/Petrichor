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
    private enum PanelKind: Equatable {
        case queue
        case lyrics

        var title: String {
            switch self {
            case .queue:
                String(localized: "Queue")
            case .lyrics:
                String(localized: "Lyrics")
            }
        }

        var heightRatio: CGFloat {
            switch self {
            case .queue:
                0.70
            case .lyrics:
                0.72
            }
        }
    }

    @Binding var isPresented: Bool
    @Binding var presentationDragOffset: CGFloat

    let playbackManager: PlaybackManager
    let playlistManager: PlaylistManager
    @ObservedObject private var playbackPresentation: PlaybackPresentationObservation

    @AppStorage("useArtworkColors")
    private var useArtworkColors = true

    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    @State private var palette = PlayerPalette.make(for: nil, useArtworkColors: false)
    @State private var hasAppliedPalette = false
    @State private var paletteTask: Task<Void, Never>?
    @State private var panelKind: PanelKind?
    @State private var panelMounted = false
    @State private var panelVisible = false
    @State private var panelDragOffset: CGFloat = 0
    @State private var panelLifecycleTask: Task<Void, Never>?

    init(
        isPresented: Binding<Bool>,
        presentationDragOffset: Binding<CGFloat>,
        playbackManager: PlaybackManager,
        playlistManager: PlaylistManager
    ) {
        _isPresented = isPresented
        _presentationDragOffset = presentationDragOffset
        self.playbackManager = playbackManager
        self.playlistManager = playlistManager
        playbackPresentation = playbackManager.presentationObservation
    }

    private var track: Track? {
        playbackPresentation.currentTrack
    }

    private var panelUp: Bool {
        panelMounted
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                background

                content(in: geometry.size)

                if panelMounted {
                    panelDismissLayer
                        .opacity(panelVisible ? 1 : 0)
                        .allowsHitTesting(panelVisible)
                }

                if panelMounted, let panelKind {
                    NowPlayingPanel(
                        title: panelKind.title,
                        onDismiss: dismissPanel,
                        onDragChanged: updatePanelDrag,
                        onDragEnded: finishPanelDrag
                    ) {
                        panelContent(for: panelKind)
                    }
                    .frame(height: geometry.size.height * panelKind.heightRatio)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .offset(y: reduceMotion ? 0 : panelOffset(height: geometry.size.height * panelKind.heightRatio))
                    .opacity(reduceMotion && !panelVisible ? 0 : 1)
                    .allowsHitTesting(panelVisible)
                }
            }
        }
        // The player is its own dark surface whatever the app's scheme is, so
        // the system controls inside it (volume slider, AirPlay picker, menus)
        // have to be told which scheme they are being drawn on.
        .preferredColorScheme(.dark)
        .onAppear {
            playbackManager.setFineProgressSampling(true)
            updatePalette()
        }
        .onDisappear {
            paletteTask?.cancel()
            panelLifecycleTask?.cancel()
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
            if hasAppliedPalette {
                withAnimation(.easeInOut(duration: 0.25)) {
                    palette = resolved
                }
            } else {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    palette = resolved
                    hasAppliedPalette = true
                }
            }
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
                .scaleEffect(playbackPresentation.isPlaying ? 1 : 0.86)
                .animation(
                    reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.86),
                    value: playbackPresentation.isPlaying
                )

            Spacer(minLength: 12)

            VStack(spacing: 22) {
                titleRow
                PlayerScrubber(
                    palette: palette,
                    playbackManager: playbackManager
                )
                PlayerTransport(
                    palette: palette,
                    playbackManager: playbackManager,
                    playlistManager: playlistManager
                )
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
        Button {
            isPresented = false
        } label: {
            Capsule()
                .fill(Color.white.opacity(0.35))
                .frame(width: 36, height: 5)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Close"))
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
            .contentTransition(.symbolEffect(.replace.offUp))
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
                presentPanel(.lyrics)
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
                presentPanel(.queue)
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
                dismissPanel()
            }
    }

    @ViewBuilder
    private func panelContent(for kind: PanelKind) -> some View {
        switch kind {
        case .queue:
            NowPlayingQueuePanel(
                accentColor: palette.foreground,
                playbackManager: playbackManager,
                playlistManager: playlistManager
            )
        case .lyrics:
            NowPlayingLyricsPanel(playbackManager: playbackManager)
        }
    }

    private func panelOffset(height: CGFloat) -> CGFloat {
        panelVisible ? max(0, panelDragOffset) : height
    }

    private func presentPanel(_ kind: PanelKind) {
        panelLifecycleTask?.cancel()

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            panelKind = kind
            panelMounted = true
            panelVisible = false
            panelDragOffset = 0
        }

        panelLifecycleTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled,
                  panelMounted,
                  panelKind == kind else { return }

            let animation: Animation = reduceMotion
                ? .easeOut(duration: 0.20)
                : .spring(response: 0.28, dampingFraction: 0.90)
            withAnimation(animation) {
                panelVisible = true
            }
        }
    }

    private func dismissPanel() {
        panelLifecycleTask?.cancel()
        guard panelMounted else { return }

        let duration = 0.20
        withAnimation(.easeOut(duration: duration)) {
            panelVisible = false
        }

        panelLifecycleTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled, !panelVisible else { return }

            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                panelMounted = false
                panelKind = nil
                panelDragOffset = 0
            }
        }
    }

    private func updatePanelDrag(_ translation: CGFloat) {
        panelDragOffset = max(0, translation)
    }

    private func finishPanelDrag(_ translation: CGFloat, _ predictedTranslation: CGFloat) {
        let shouldDismiss = translation > 80 || predictedTranslation > 160
        if shouldDismiss {
            dismissPanel()
        } else if reduceMotion {
            panelDragOffset = 0
        } else {
            withAnimation(.spring(response: 0.24, dampingFraction: 0.90)) {
                panelDragOffset = 0
            }
        }
    }

    // MARK: - Dismissal

    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard !panelUp else { return }
                presentationDragOffset = max(0, value.translation.height)
            }
            .onEnded { value in
                let shouldDismiss = presentationDragOffset > 90
                    || value.predictedEndTranslation.height > 200
                if !panelUp && shouldDismiss {
                    isPresented = false
                } else {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.92)) {
                        presentationDragOffset = 0
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
