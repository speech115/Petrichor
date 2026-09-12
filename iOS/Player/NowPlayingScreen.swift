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
import UIKit

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

    let playbackManager: PlaybackManager
    let playlistManager: PlaylistManager
    @ObservedObject private var playbackPresentation: PlaybackPresentationObservation

    @AppStorage("useArtworkColors")
    private var useArtworkColors = true

    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    /// The cover's share of the screen backs off at accessibility text sizes:
    /// title and artist use a real, uncapped text style (`.title2`), and at
    /// the largest categories that block alone can need well over 150pt more
    /// than it does at the default size. A fixed 44% for the artwork left no
    /// room to absorb that, and the controls below ran off the bottom of the
    /// screen — this is what the "may be clipped at larger Dynamic Type
    /// sizes" audit finding was catching.
    @Environment(\.dynamicTypeSize)
    private var dynamicTypeSize

    @State private var palette = PlayerPalette.neutral
    @State private var hasAppliedPalette = false
    @State private var paletteTask: Task<Void, Never>?
    @State private var fineSamplingTask: Task<Void, Never>?
    @State private var panelKind: PanelKind?
    @State private var panelMounted = false
    @State private var panelVisible = false
    @State private var panelDragOffset: CGFloat = 0
    @State private var panelLifecycleTask: Task<Void, Never>?
    /// What the cover and the title row are showing. One update behind
    /// `track`, on purpose: the swap has to happen *inside* the animation that
    /// carries it, and `onChange` only fires once the new track has already
    /// been rendered. Everything else on the screen reads `track` directly.
    @State private var displayedTrack: Track?
    /// Set from the queue index before the swap, so the cover leaves towards
    /// the side the new one arrives from.
    @State private var slidesForward = true
    @State private var lastQueueIndex: Int?

    // The player is a fixed composition: title, scrubber, transport, volume
    // and accessory share the space the artwork leaves. Glyphs scale with
    // Dynamic Type but stay capped, so at the largest accessibility size
    // nothing grows past its slot or crowds its neighbour.
    @ScaledMetric(relativeTo: .subheadline) private var chipIconSize: CGFloat = 14
    @ScaledMetric(relativeTo: .caption) private var volumeIconSize: CGFloat = 12
    @ScaledMetric(relativeTo: .body) private var accessoryIconSize: CGFloat = 20

    init(
        isPresented: Binding<Bool>,
        playbackManager: PlaybackManager,
        playlistManager: PlaylistManager
    ) {
        _isPresented = isPresented
        self.playbackManager = playbackManager
        self.playlistManager = playlistManager
        playbackPresentation = playbackManager.presentationObservation
    }

    private var track: Track? {
        playbackPresentation.currentTrack
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
        // Keep the player's controls legible on its dark artwork surface
        // without changing the color scheme of the playlist underneath it.
        .environment(\.colorScheme, .dark)
        .onAppear {
            displayedTrack = track
            lastQueueIndex = playlistManager.currentQueueIndex
            // Paint from cache before the first layout so zoom doesn't flash
            // neutral gray then recolor; skip the async path on a warm hit.
            if let cached = PlayerPalette.cachedPalette(for: track, useArtworkColors: useArtworkColors) {
                palette = cached
                hasAppliedPalette = true
            } else {
                updatePalette()
            }
            // Fine scrubber sampling fights the open zoom for main-thread time.
            fineSamplingTask?.cancel()
            fineSamplingTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(Int(TimeConstants.zoomTransitionSettle * 1000)))
                guard !Task.isCancelled else { return }
                playbackManager.setFineProgressSampling(true)
            }
        }
        .onDisappear {
            paletteTask?.cancel()
            panelLifecycleTask?.cancel()
            fineSamplingTask?.cancel()
            playbackManager.setFineProgressSampling(false)
        }
        .onChange(of: track?.id) { _, _ in
            advanceDisplayedTrack()
            updatePalette()
        }
        .onChange(of: track?.artworkData?.count) { _, _ in
            // The current track arrives with a thumbnail and is enriched with
            // full artwork once audio starts. That is the same track, so it
            // lands without a transition — animating it would replay the slide.
            displayedTrack = track
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
            let resolved = await PlayerPalette.make(for: sourceTrack, useArtworkColors: shouldUseArtwork)
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
        // a letterbox on a short screen or a wall on a tall one. At
        // accessibility text sizes the title/artist block below needs
        // significantly more height (a real, uncapped text style), so the
        // cover gives back some of its share to keep the controls on screen.
        let artworkRatio: CGFloat = dynamicTypeSize.isAccessibilitySize ? 0.30 : 0.44
        let artworkSide = min(size.width - 56, size.height * artworkRatio)
        let controlSpacing: CGFloat = dynamicTypeSize.isAccessibilitySize ? 14 : 22

        return VStack(spacing: 0) {
            grabber

            Spacer(minLength: 12)

            artwork
                .frame(width: artworkSide, height: artworkSide)
                .id(displayedTrack?.id)
                .transition(coverTransition)

            Spacer(minLength: 12)

            VStack(spacing: controlSpacing) {
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
    }

    // MARK: - Grabber

    private var grabber: some View {
        Button {
            isPresented = false
        } label: {
            Capsule()
                .fill(Color.white.opacity(0.35))
                .frame(width: 36, height: 5)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Close"))
    }

    // MARK: - Artwork

    /// A slide rather than a clip: the cover carries a 24pt shadow, and any
    /// container tight enough to clip the travel would cut the shadow off. 40pt
    /// of offset under a cross-fade reads as direction without needing one.
    private var coverTransition: AnyTransition {
        directionalTransition(distance: 40)
    }

    private var titleTransition: AnyTransition {
        directionalTransition(distance: 20)
    }

    private func directionalTransition(distance: CGFloat) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        let entering = slidesForward ? distance : -distance
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(x: entering)),
            removal: .opacity.combined(with: .offset(x: -entering))
        )
    }

    private func advanceDisplayedTrack() {
        let index = playlistManager.currentQueueIndex
        if let lastQueueIndex {
            slidesForward = index >= lastQueueIndex
        }
        lastQueueIndex = index

        let animation: Animation = reduceMotion
            ? .easeInOut(duration: AnimationDuration.mediumDuration)
            : .spring(response: 0.32, dampingFraction: 0.9)
        withAnimation(animation) {
            displayedTrack = track
        }
    }

    private var artwork: some View {
        ArtworkTile(
            data: displayedTrack?.displayArtwork,
            cacheKey: displayedTrack.map { ArtworkCacheKey.nowPlaying($0.id) },
            cornerRadius: 12,
            iconSize: 72,
            maxPixelSize: 960,
            fallbackMaxPixelSize: 180,
            // The title and artist right below name the content; the cover
            // itself adds nothing VoiceOver cannot already say.
        )
        .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
    }

    // MARK: - Title

    private var titleRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                // A real text style, not a raw size: the audit's Dynamic Type
                // check only accepts fonts that scale fully with a text
                // style — capping the type size (via `.dynamicTypeSize`) is
                // itself flagged as "partially unsupported". No line limit
                // either: the audit flags any clipping risk, and letting the
                // title/artist wrap at the largest accessibility sizes is
                // the only way to keep the style uncapped without clipping.
                Text(displayedTrack?.title ?? "")
                    .font(.title2.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundColor(palette.foreground)
                    // The Dynamic Type audit is scoped to these two elements:
                    // they must stay uncapped, real text styles.
                    .accessibilityIdentifier("NowPlayingTitle")
                Text(displayedTrack?.displayArtist ?? "")
                    .font(.title2)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundColor(palette.secondary)
                    .accessibilityIdentifier("NowPlayingArtist")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Travels with the cover but half as far — the names sit in a
            // narrower column, and matching the cover's 40pt there overshoots.
            .id(displayedTrack?.id)
            .transition(titleTransition)
            .titleSwipeNavigation(
                onPrevious: { playlistManager.playPreviousTrack() },
                onNext: { playlistManager.playNextTrack() }
            )

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
                    TrackMenuContent(track: track, playlistManager: playlistManager)
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
            .font(.system(size: min(chipIconSize, 20), weight: .semibold))
            .foregroundColor(isActive ? palette.foreground : palette.secondary)
            .contentTransition(.symbolEffect(.replace.offUp))
            // The label is a 44pt hit target around the 30pt chip circle, so
            // the visual stays put while the touch area clears the HIG floor.
            .frame(width: 44, height: 44)
            .background(Circle().fill(palette.chip).frame(width: 30, height: 30))
            .contentShape(Circle())
    }

    // MARK: - Volume

    private var volumeRow: some View {
        HStack(spacing: 10) {
            // Glyphs frame the system slider; the slider itself is the control.
            Image(systemName: "speaker.fill")
                .accessibilityHidden(true)
            SystemVolumeSlider(tint: UIColor.white.withAlphaComponent(0.85))
                .frame(height: 24)
            Image(systemName: "speaker.wave.3.fill")
                .accessibilityHidden(true)
        }
        .font(.system(size: min(volumeIconSize, 16)))
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
                    .font(.system(size: min(accessoryIconSize, 24)))
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
                    .font(.system(size: min(accessoryIconSize, 24)))
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

    // Dismissal is the system zoom transition's interactive gesture: the
    // presented surface can be grabbed mid-flight and pulled down, or closed
    // with the grabber. No custom drag lives here — a `DragGesture` on the
    // content would claim the pan and starve the system gesture, which is the
    // "only responds after the animation ends" feel.
}
