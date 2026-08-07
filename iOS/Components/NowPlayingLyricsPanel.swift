//
// NowPlayingLyricsPanel (iOS)
//
// Track lyrics as a panel over the Now Playing artwork. Lyrics load through
// the shared LyricsStore (single-flight cache); the text scrolls, and line
// highlighting only appears when the lyrics are timed — plain lyrics are
// shown as-is, with no fake highlight. Missing lyrics are a calm empty state.
//

import SwiftUI

struct NowPlayingLyricsPanel: View {
    @EnvironmentObject private var libraryManager: LibraryManager
    @EnvironmentObject private var playbackManager: PlaybackManager

    let onDismiss: () -> Void

    @State private var lyricLines: [LyricLine] = []
    @State private var isLoading = true
    @State private var fetchFailed = false
    @State private var currentLineIndex = -1
    @State private var hasTimedLyrics = false

    private var currentTrack: Track? {
        playbackManager.currentTrack
    }

    var body: some View {
        NowPlayingPanel(title: String(localized: "Lyrics"), onDismiss: onDismiss) {
            Group {
                if isLoading {
                    loadingView
                } else if lyricLines.isEmpty {
                    emptyLyricsView
                } else {
                    lyricsContent
                }
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
        .onChange(of: playbackManager.currentTrack?.id) { _, _ in
            loadLyricsForCurrentTrack()
        }
        .onReceive(playbackManager.playbackProgressState.$currentTime) { newTime in
            updateCurrentLine(for: newTime)
        }
    }

    // MARK: - Loading View

    private var loadingView: some View {
        VStack(spacing: 12) {
            ForEach([170.0, 130.0, 190.0, 110.0], id: \.self) { width in
                Capsule()
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: width, height: 13)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .phaseAnimator(
            [0.3, 0.7],
            content: { view, opacity in
                view.opacity(opacity)
            },
            animation: { _ in .easeInOut(duration: 0.85) }
        )
        .accessibilityLabel(String(localized: "Loading lyrics"))
    }

    // MARK: - Empty Lyrics View

    private var emptyLyricsView: some View {
        VStack(spacing: 16) {
            Image(systemName: Icons.customLyrics)
                .font(.system(size: 48))
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

    private var lyricsContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(Array(lyricLines.enumerated()), id: \.offset) { index, line in
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.system(size: 15))
                            .fontWeight(hasTimedLyrics && currentLineIndex == index ? .bold : .regular)
                            .scaleEffect(hasTimedLyrics && currentLineIndex == index ? 1.08 : 1.0)
                            .foregroundColor(hasTimedLyrics && currentLineIndex == index ? .primary : .secondary)
                            .multilineTextAlignment(.center)
                            .lineSpacing(6)
                            .id(index)
                            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: currentLineIndex)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity)
                .textSelection(.enabled)
            }
            .scrollIndicators(.never)
            .onChange(of: currentLineIndex) { _, newIndex in
                guard hasTimedLyrics else { return }
                withAnimation {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
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

        if !forceReload, let cached = LyricsStore.shared.cachedLyrics(for: loadedTrackId) {
            lyricLines = cached.lines
            hasTimedLyrics = cached.hasTimed
            isLoading = false
            fetchFailed = false
            updateCurrentLine(for: playbackManager.playbackProgressState.currentTime)
            return
        }

        isLoading = true
        lyricLines = []
        fetchFailed = false
        hasTimedLyrics = false

        Task {
            do {
                let result = try await LyricsStore.shared.lyrics(
                    for: track,
                    using: libraryManager.databaseManager.dbQueue,
                    databaseManager: libraryManager.databaseManager,
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

        if newIndex != currentLineIndex {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                currentLineIndex = newIndex
            }
        }
    }
}
