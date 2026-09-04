//
// NowPlayingLyricsPanel (iOS)
//
// Track lyrics as a panel over the Now Playing artwork. Lyrics load through
// the shared LyricsStore (single-flight cache); the text scrolls, and line
// highlighting only appears when the lyrics are timed — plain lyrics are
// shown as-is, with no fake highlight. Missing lyrics are a calm empty state.
//

import SwiftUI
import UIKit

struct NowPlayingLyricsPanel: View {
    @EnvironmentObject private var libraryManager: LibraryManager
    let playbackManager: PlaybackManager
    @ObservedObject private var playbackPresentation: PlaybackPresentationObservation
    private let playbackProgressState: PlaybackProgressState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var lyricLines: [LyricLine] = []
    @State private var isLoading = true
    @State private var fetchFailed = false
    @State private var currentLineIndex = -1
    @State private var hasTimedLyrics = false

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
        VStack(spacing: 16) {
            Image(systemName: Icons.customLyrics)
                .font(.system(size: min(emptyStateIconSize, 72)))
                .foregroundColor(.secondary)

            Text(String(localized: "No Lyrics Available"))
                .font(.headline)
                .foregroundColor(.secondary)

            if fetchFailed {
                Button {
                    loadLyricsForCurrentTrack(forceReload: true)
                } label: {
                    Label(String(localized: "Retry"), systemImage: Icons.arrowClockwise)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    ForEach(Array(lyricLines.enumerated()), id: \.offset) { index, line in
                        let isActive = hasTimedLyrics && currentLineIndex == index
                        let isPast = hasTimedLyrics && index < currentLineIndex

                        Text(line.text.isEmpty ? " " : line.text)
                            // Content text in a scrolling panel: a real text
                            // style, free to grow with Dynamic Type.
                            .font(.subheadline.weight(.semibold))
                            // Apple Music-style depth: the active line is bright
                            // and slightly enlarged, upcoming lines dim mildly,
                            // and past lines dim further with a soft blur so the
                            // eye rests on the present line.
                            .opacity(isActive ? 1 : (isPast ? 0.3 : 0.5))
                            .blur(radius: isPast ? 1.2 : 0)
                            .scaleEffect(isActive ? 1.08 : 1.0)
                            .multilineTextAlignment(.center)
                            .lineSpacing(6)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                // Tap a timed line to jump to it, like Apple Music.
                                guard hasTimedLyrics else { return }
                                UISelectionFeedbackGenerator().selectionChanged()
                                playbackManager.seekTo(time: line.startTime)
                            }
                            .animation(highlightAnimation, value: isActive)
                            .animation(highlightAnimation, value: isPast)
                            .id(index)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity)
                .textSelection(.enabled)
                // The panel reaches under the home indicator now; keep the text
                // above it so the last line is not obscured.
                .safeAreaPadding(.bottom)
            }
            .scrollIndicators(.never)
            .onChange(of: currentLineIndex) { _, newIndex in
                guard hasTimedLyrics, newIndex >= 0 else { return }
                withAnimation(scrollAnimation) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
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
            fetchFailed = false
            return
        }

        currentLineIndex = -1
        let loadedTrackId = track.id

        if !forceReload, let cached = libraryManager.cachedLyrics(for: loadedTrackId) {
            lyricLines = cached.lines
            hasTimedLyrics = cached.hasTimed
            isLoading = false
            fetchFailed = false
            updateCurrentLine(for: playbackProgressState.currentTime)
            return
        }

        isLoading = true
        lyricLines = []
        fetchFailed = false
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
                    fetchFailed = false
                }
            } catch {
                await MainActor.run {
                    guard currentTrack?.id == loadedTrackId else { return }
                    lyricLines = []
                    hasTimedLyrics = false
                    isLoading = false
                    fetchFailed = true
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
    }
}
