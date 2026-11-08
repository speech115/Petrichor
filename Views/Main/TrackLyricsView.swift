import SwiftUI

/// The main window's lyrics panel, as in the Music app: full height, no
/// header, large bold lines aligned left. The capsule's lyrics button opens
/// and closes it.
struct TrackLyricsView: View {
    var body: some View {
        TrackLyricsContent(fontSize: 22, isPanelStyle: true)
    }
}

// MARK: - Lyrics Content (header-less, reusable)

/// The lyrics display (loading / empty / synced scroll) without any header
/// chrome, so it can be hosted inside a custom shell (e.g. the mini player) as
/// well as the main TrackLyricsView. Self-manages loading and line sync.
struct TrackLyricsContent: View {
    /// Font size for lyric lines. Larger hosts (e.g. immersive mode) pass a bigger
    /// value; defaults preserve the compact main-window / mini-player sizing.
    var fontSize: CGFloat = 14
    /// Color for the active (or, for untimed lyrics, every) line.
    var activeColor: Color = .primary
    /// Color for inactive lines.
    var inactiveColor: Color = .secondary
    /// The Music app's panel look: every line bold and aligned left, the
    /// current one in `activeColor`, the rest dimmed; a click on a timed line
    /// seeks to it.
    var isPanelStyle = false

    @EnvironmentObject var libraryManager: LibraryManager
    @EnvironmentObject var playbackManager: PlaybackManager
    @ObservedObject private var lyricsStore = LyricsStore.shared

    @State private var lyricLines: [LyricLine] = []
    @State private var isLoading = true
    @State private var fetchFailed = false
    @State private var currentLineIndex: Int = -1
    @State private var hasTimedLyrics: Bool = false

    private var currentTrack: Track? {
        playbackManager.currentTrack
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
        .onChange(of: playbackManager.currentTrack?.id) { _, _ in
            loadLyricsForCurrentTrack()
        }
        // Listen for playback time changes and update the current line in real time.
        .onReceive(playbackManager.playbackProgressState.$currentTime) { newTime in
            updateCurrentLine(for: newTime)
        }
        .onReceive(lyricsStore.$cached) { lyrics in
            guard let lyrics, currentTrack?.id == lyrics.trackId else { return }
            apply(lyrics)
        }
    }

    // MARK: - Loading View
    private var loadingView: some View {
        VStack(spacing: 12) {
            ForEach([170.0, 130.0, 190.0, 110.0], id: \.self) { width in
                Capsule()
                    .fill(inactiveColor)
                    .frame(width: width, height: 13)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A gently pulsing skeleton of lyric lines. PhaseAnimator loops on its own
        // while visible (no extra @State) and restarts each time loading reappears.
        .phaseAnimator(
            [0.3, 0.7],
            content: { view, opacity in
                view.opacity(opacity)
            },
            animation: { _ in .easeInOut(duration: 0.85) }
        )
        .accessibilityLabel("Loading lyrics")
    }

    // MARK: - Empty Lyrics View
    private var emptyLyricsView: some View {
        VStack(spacing: 16) {
            Image(Icons.customLyrics)
                .font(.system(size: 48))
                .foregroundColor(activeColor)

            Text("No Lyrics Available")
                .font(.headline)
                .foregroundColor(activeColor)

            if fetchFailed {
                Button {
                    loadLyricsForCurrentTrack(forceReload: true)
                } label: {
                    Label("Retry", systemImage: Icons.arrowClockwise)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Lyrics Content with Conditional Synced Highlight
    private var lyricsContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: isPanelStyle ? .leading : .center, spacing: fontSize * (isPanelStyle ? 0.6 : 0.7)) {
                    ForEach(Array(lyricLines.enumerated()), id: \.offset) { index, line in
                        let isActive = hasTimedLyrics && currentLineIndex == index
                        let lyricText = line.text.isEmpty ? " " : line.text

                        Group {
                            if isPanelStyle {
                                panelLine(lyricText, line: line, isActive: isActive)
                            } else {
                                centeredLine(lyricText, isActive: isActive)
                            }
                        }
                        .id(index)
                    }
                }
                .padding(isPanelStyle ? 24 : 20)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)
            .onChange(of: currentLineIndex) { _, newIndex in
                guard hasTimedLyrics, newIndex >= 0 else { return }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
    }

    /// One line of the compact style (mini player, immersive): the current
    /// line turns bold and grows slightly; the text is selectable.
    private func centeredLine(_ text: String, isActive: Bool) -> some View {
        ZStack {
            Text(text)
                .font(.system(size: fontSize))
                .foregroundColor(inactiveColor)
                .opacity(isActive ? 0.0 : 1.0)
                .accessibilityHidden(true)

            Text(text)
                .font(.system(size: fontSize, weight: .bold))
                .foregroundColor(activeColor)
                .opacity(isActive ? 1.0 : 0.0)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
        .scaleEffect(isActive ? 1.05 : 1.0)
        .multilineTextAlignment(.center)
        .lineSpacing(6)
        .textSelection(.enabled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .animation(.smooth(duration: 0.25), value: isActive)
    }

    /// One line of the panel style. Untimed lyrics have no current line, so
    /// they all read in `activeColor`.
    private func panelLine(_ text: String, line: LyricLine, isActive: Bool) -> some View {
        Text(text)
            .font(.system(size: fontSize, weight: .bold))
            .foregroundStyle(isActive || !hasTimedLyrics ? activeColor : inactiveColor.opacity(0.55))
            .multilineTextAlignment(.leading)
            .lineSpacing(4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                guard hasTimedLyrics else { return }
                playbackManager.seekTo(time: line.startTime)
            }
            .accessibilityAddTraits(hasTimedLyrics ? .isButton : [])
            .animation(.easeInOut(duration: 0.25), value: isActive)
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
            apply(cached)
            return
        }

        isLoading = true
        lyricLines = []
        fetchFailed = false
        hasTimedLyrics = false   // Reset until we know

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
                    apply(result)
                }
            } catch is CancellationError {
                return
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

    private func apply(_ lyrics: LyricsStore.Lyrics) {
        lyricLines = lyrics.lines
        hasTimedLyrics = lyrics.hasTimed
        isLoading = false
        fetchFailed = false
        currentLineIndex = -1
        updateCurrentLine(for: playbackManager.playbackProgressState.currentTime)
    }

    /// Determine the current lyric line based on playback time.
    /// Only executed for timed lyrics; for untimed lyrics this does nothing.
    private func updateCurrentLine(for time: TimeInterval) {
        guard hasTimedLyrics, !lyricLines.isEmpty else { return }

        // Prefer precise judgment via endTime; fall back to startTime ≤ time when endTime is nil
        let newIndex = LyricsTimeline.activeLineIndex(in: lyricLines, at: time)

        if newIndex != currentLineIndex {
            currentLineIndex = newIndex
        }
    }
}
