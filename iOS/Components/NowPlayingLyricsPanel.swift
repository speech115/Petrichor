//
// NowPlayingLyricsPanel (iOS)
//
// Track lyrics as a panel over the Now Playing artwork. Lyrics load through
// the shared LyricsStore (single-flight cache); the text scrolls, and line
// highlighting only appears when the lyrics are timed — plain lyrics are
// shown as-is, with no fake highlight. Missing lyrics are a calm empty state.
//

import SwiftUI
import TipKit

struct NowPlayingLyricsPanel: View {
    @EnvironmentObject private var libraryManager: LibraryManager
    let playbackManager: PlaybackManager
    @ObservedObject private var playbackPresentation: PlaybackPresentationObservation
    private let playbackProgressState: PlaybackProgressState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var lyricLines: [LyricLine] = []
    @State private var isLoading = true
    @State private var fetchError: NSError?
    @AppStorage("onlineLyricsEnabled") private var onlineLyricsEnabled = false
    @State private var currentLineIndex = -1
    @State private var hasTimedLyrics = false
    /// Off while the reader scrolls the lyrics by hand, so the next line
    /// change doesn't yank the text out from under the finger.
    @State private var followsPlayhead = true
    @State private var resumeFollowTask: Task<Void, Never>?
    /// Where the singing is: the active line's index plus how far through it
    /// the playhead is. One value for the whole text, so crossing into the
    /// next line keeps moving forward instead of sweeping the fill back from
    /// the previous line's 1 to the new line's 0.
    @State private var sungPosition: Double = -1
    private let tapTip = LyricsTapTip()

    /// How long the lyrics stay where the reader left them before following
    /// the playhead again.
    private static let resumeFollowDelay: Duration = .seconds(3)

    init(playbackManager: PlaybackManager) {
        self.playbackManager = playbackManager
        playbackPresentation = playbackManager.presentationObservation
        playbackProgressState = playbackManager.playbackProgressState
    }

    private var currentTrack: Track? {
        playbackPresentation.currentTrack
    }

    var body: some View {
        Group {
            if isLoading {
                loadingView
            } else if lyricLines.isEmpty {
                emptyLyricsView
            } else {
                lyricsContent
            }
        }
        .onAppear {
            loadLyricsForCurrentTrack()
            // Sample the playhead at 0.5s while lyrics are on screen for tight
            // line highlighting; the rate drops back to 1s when this view closes.
            playbackManager.setFineProgressSampling(true)
        }
        .onDisappear {
            playbackManager.setFineProgressSampling(false)
        }
        .onChange(of: playbackPresentation.currentTrack?.id) { _, _ in
            loadLyricsForCurrentTrack()
        }
        .onChange(of: onlineLyricsEnabled) { _, _ in
            loadLyricsForCurrentTrack(forceReload: true)
        }
        .onReceive(playbackProgressState.$currentTime) { newTime in
            updateCurrentLine(for: newTime)
        }
    }

    // MARK: - Loading View

    private var loadingView: some View {
        Group {
            if reduceMotion {
                loadingPlaceholders
                    .opacity(0.5)
            } else {
                loadingPlaceholders
                    .phaseAnimator(
                        [0.3, 0.7],
                        content: { view, opacity in
                            view.opacity(opacity)
                        },
                        animation: { _ in .easeInOut(duration: 0.85) }
                    )
            }
        }
        .accessibilityLabel(String(localized: "Loading lyrics"))
    }

    private var loadingPlaceholders: some View {
        VStack(spacing: 12) {
            ForEach([170.0, 130.0, 190.0, 110.0], id: \.self) { width in
                Capsule()
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: width, height: 13)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty Lyrics View

    /// The empty-state glyph follows Dynamic Type; the cap keeps it from
    /// dwarfing the message under it at the largest accessibility sizes.
    @ScaledMetric(relativeTo: .largeTitle) private var emptyStateIconSize: CGFloat = 48

    private var emptyLyricsView: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: Icons.customLyrics)
                    .font(.system(size: min(emptyStateIconSize, 72)))
                    .foregroundColor(.secondary)

                Text(emptyTitle)
                    .font(.headline)
                    .foregroundStyle(.primary)

                Text(emptyDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if !onlineLyricsEnabled {
                    Button(String(localized: "Enable Online Lyrics")) {
                        onlineLyricsEnabled = true
                    }
                } else if fetchError != nil {
                    Button {
                        loadLyricsForCurrentTrack(forceReload: true)
                    } label: {
                        Label(String(localized: "Retry"), systemImage: Icons.arrowClockwise)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.center, for: .alignment)
    }

    private var isOffline: Bool {
        guard let fetchError, fetchError.domain == NSURLErrorDomain else { return false }
        return [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
                NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff].contains(fetchError.code)
    }

    private var emptyTitle: String {
        if !onlineLyricsEnabled { return String(localized: "Online Lyrics Are Off") }
        if isOffline { return String(localized: "No Internet Connection") }
        if fetchError != nil { return String(localized: "Couldn't Load Lyrics") }
        return String(localized: "No Lyrics Available")
    }

    private var emptyDescription: String {
        if !onlineLyricsEnabled { return String(localized: "No lyrics in this file. Enable online search to look for them.") }
        if isOffline { return String(localized: "Connect to the internet and try again.") }
        if fetchError != nil { return String(localized: "The lyrics service couldn't be reached. Try again.") }
        return String(localized: "No lyrics were found for this song.")
    }

    // MARK: - Lyrics Content with Conditional Synced Highlight

    /// Every line keeps one weight and one layout. Swapping `.regular` for
    /// `.bold` on the active line re-measures its text, which reflows the stack
    /// under a scroll that is animating to that very line — the two fight and
    /// the highlight stutters across both the old line and the new one. Colour,
    /// opacity and scale carry the highlight instead; none of them touch layout.
    private var lyricsContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if hasTimedLyrics {
                        TipView(tapTip)
                    }
                    ForEach(Array(lyricLines.enumerated()), id: \.offset) { index, line in
                        lyricLine(line, index: index, proxy: proxy)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity)
                .textSelection(.enabled)
            }
            .scrollIndicators(.never)
            .onScrollPhaseChange { _, phase in
                handleScrollPhase(phase)
            }
            .onChange(of: currentLineIndex) { _, _ in
                scrollToCurrentLine(proxy)
            }
            .onChange(of: followsPlayhead) { _, follows in
                if follows { scrollToCurrentLine(proxy) }
            }
            .onDisappear { resumeFollowTask?.cancel() }
        }
    }

    @ViewBuilder
    private func lyricLine(_ line: LyricLine, index: Int, proxy: ScrollViewProxy) -> some View {
        let isActive = hasTimedLyrics && currentLineIndex == index
        let text = Text(line.text.isEmpty ? " " : line.text)
            // Content text in a scrolling panel: a real text
            // style, free to grow with Dynamic Type.
            .font(.title2.weight(.semibold))
            .textRenderer(LyricLineFill(progress: min(1, max(0, sungPosition - Double(index))), isLit: isActive))
            .opacity(!hasTimedLyrics || isActive ? 1 : 0.60)
            .scaleEffect(isActive ? 1.06 : 1.0)
            .multilineTextAlignment(.center)
            .lineSpacing(6)
            .animation(highlightAnimation, value: isActive)
            .id(index)

        if hasTimedLyrics {
            // A tap on a line plays from it, as in Apple Music, and hands the
            // scroll back to the playhead at once.
            Button {
                tapTip.invalidate(reason: .actionPerformed)
                playbackManager.seekTo(time: line.startTime)
                resumeFollowTask?.cancel()
                followsPlayhead = true
                scrollToCurrentLine(proxy)
            } label: {
                text
            }
            .buttonStyle(.plain)
        } else {
            text
        }
    }

    private func scrollToCurrentLine(_ proxy: ScrollViewProxy) {
        guard followsPlayhead, hasTimedLyrics, currentLineIndex >= 0 else { return }
        withAnimation(scrollAnimation) {
            proxy.scrollTo(currentLineIndex, anchor: .center)
        }
    }

    /// A touch takes the scroll over at once, mid auto-scroll included; the
    /// playhead gets it back after the reader has let go for a moment.
    private func handleScrollPhase(_ phase: ScrollPhase) {
        switch phase {
        case .interacting:
            resumeFollowTask?.cancel()
            followsPlayhead = false
        case .idle where !followsPlayhead:
            resumeFollowTask?.cancel()
            resumeFollowTask = Task { @MainActor in
                try? await Task.sleep(for: Self.resumeFollowDelay)
                guard !Task.isCancelled else { return }
                followsPlayhead = true
            }
        default:
            break
        }
    }

    private var highlightAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.22)
    }

    private var scrollAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.32)
    }

    // MARK: - Helper Methods

    private func loadLyricsForCurrentTrack(forceReload: Bool = false) {
        guard let track = currentTrack else {
            lyricLines = []
            isLoading = false
            fetchError = nil
            return
        }

        currentLineIndex = -1
        sungPosition = -1
        resumeFollowTask?.cancel()
        followsPlayhead = true
        let loadedTrackId = track.id

        if !forceReload, let cached = libraryManager.cachedLyrics(for: loadedTrackId) {
            lyricLines = cached.lines
            hasTimedLyrics = cached.hasTimed
            isLoading = false
            fetchError = nil
            updateCurrentLine(for: playbackProgressState.currentTime)
            return
        }

        isLoading = true
        lyricLines = []
        fetchError = nil
        hasTimedLyrics = false

        Task {
            do {
                // Shared cache + single-flight: concurrent lyrics views (main window,
                // mini player, immersive) for the same track load only once.
                let result = try await libraryManager.lyrics(
                    for: track,
                    forceReload: forceReload
                )

                await MainActor.run {
                    guard currentTrack?.id == loadedTrackId else { return }
                    lyricLines = result.lines
                    hasTimedLyrics = result.hasTimed
                    isLoading = false
                    fetchError = nil
                }
            } catch {
                await MainActor.run {
                    guard currentTrack?.id == loadedTrackId else { return }
                    lyricLines = []
                    hasTimedLyrics = false
                    isLoading = false
                    fetchError = error as NSError
                }
            }
        }
    }

    /// Determine the current lyric line based on playback time.
    /// Only executed for timed lyrics; for untimed lyrics this does nothing.
    private func updateCurrentLine(for time: TimeInterval) {
        guard hasTimedLyrics, !lyricLines.isEmpty else { return }

        let newIndex = LyricsTimeline.activeLineIndex(in: lyricLines, at: time)

        // Written plainly: the highlight and the scroll each declare their own
        // animation. Wrapping the index change here layered a third transaction
        // over both and drove them at different speeds.
        if newIndex != currentLineIndex {
            currentLineIndex = newIndex
        }

        // The playhead arrives once per sample. The fill heads for where the
        // song will be by the next one, so it sweeps on time instead of half
        // a second behind; paused, it stops where the song stopped.
        let interval = playbackProgressState.sampleInterval
        let isPlaying = playbackPresentation.isPlaying
        let position = newIndex < 0 ? -1 : Double(newIndex) + LyricsTimeline.lineProgress(
            in: lyricLines,
            index: newIndex,
            at: isPlaying ? time + interval : time
        )
        // A seek lands at once; only the song's own progress sweeps.
        let isSweep = isPlaying && position >= sungPosition && position - sungPosition < 2
        withAnimation(isSweep ? .linear(duration: interval) : nil) {
            sungPosition = position
        }
    }
}

/// The active lyric line, lit from the leading edge as the line is sung: the
/// whole line drawn dimmed, then a lit copy masked up to `progress`, carried
/// across wrapped lines in reading order, with a soft edge like Apple
/// Music's. Lines that are not lit draw plainly.
private struct LyricLineFill: TextRenderer, Animatable {
    var progress: Double
    let isLit: Bool

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    private static let dimOpacity = 0.45
    private static let edgeWidth: CGFloat = 24

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        guard isLit else {
            for line in layout { context.draw(line) }
            return
        }
        let lines = Array(layout)
        let total = lines.reduce(0) { $0 + $1.typographicBounds.width }
        var remaining = progress * total

        for line in lines {
            var dimmed = context
            dimmed.opacity = Self.dimOpacity
            dimmed.draw(line)

            let bounds = line.typographicBounds.rect.insetBy(dx: 0, dy: -6)
            let lit = min(max(remaining, 0), bounds.width)
            remaining -= bounds.width
            guard lit > 0 else { continue }

            var bright = context
            bright.clipToLayer { mask in
                let solid = CGRect(x: bounds.minX, y: bounds.minY, width: lit, height: bounds.height)
                mask.fill(Path(solid), with: .color(.black))
                let edge = CGRect(x: solid.maxX, y: bounds.minY, width: Self.edgeWidth, height: bounds.height)
                mask.fill(Path(edge), with: .linearGradient(
                    Gradient(colors: [.black, .clear]),
                    startPoint: CGPoint(x: edge.minX, y: edge.midY),
                    endPoint: CGPoint(x: edge.maxX, y: edge.midY)
                ))
            }
            bright.draw(line)
        }
    }
}
