import SwiftUI
import UniformTypeIdentifiers

/// The main window's queue panel, as in the Music app: a large "Up Next"
/// title with the count and Clear, then the rows. The capsule's queue button
/// opens and closes it.
struct PlayQueueView: View {
    @EnvironmentObject var playlistManager: PlaylistManager
    @State private var showingClearConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            PlayQueueContent()
        }
        .clearQueueConfirmation(isPresented: $showingClearConfirmation) {
            playlistManager.clearQueue()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Up Next")
                .font(.system(size: 20, weight: .bold))

            Spacer()

            if !playlistManager.currentQueue.isEmpty {
                Text("\(playlistManager.currentQueue.count) songs")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Button("Clear") {
                    showingClearConfirmation = true
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11, weight: .medium))
                .help("Clear Queue")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }
}

extension View {
    /// Shared confirmation alert for clearing the play queue, used by both the
    /// main-window queue header and the mini player's queue panel.
    func clearQueueConfirmation(isPresented: Binding<Bool>, onClear: @escaping () -> Void) -> some View {
        alert("Clear Queue", isPresented: isPresented) {
            Button("Cancel", role: .cancel) { }
            Button("Clear", role: .destructive, action: onClear)
        } message: {
            Text("Are you sure you want to clear the entire queue? This will stop playback.")
        }
    }
}

// MARK: - Queue Content (header-less, reusable)

/// The scrollable queue list / empty state without any header chrome, so it can
/// be hosted inside a custom shell (e.g. the mini player) as well as the main
/// PlayQueueView.
struct PlayQueueContent: View {
    /// Highlight color for the current track / hover state. Defaults to the app
    /// accent; the mini player passes the artwork's dominant color.
    var accentColor: Color = .accentColor
    /// Text colors for non-playing rows. Defaults to the system primary/secondary;
    /// immersive mode passes an artwork-adaptive color for legibility.
    var primaryTextColor: Color = .primary
    var secondaryTextColor: Color = .secondary
    var scale: CGFloat = 1

    @EnvironmentObject var playbackManager: PlaybackManager
    @EnvironmentObject var playlistManager: PlaylistManager
    @State private var draggedIndex: Int?

    var body: some View {
        Group {
            if playlistManager.currentQueue.isEmpty {
                emptyQueueView
            } else {
                queueListView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty Queue View

    private var emptyQueueView: some View {
        VStack(spacing: 16 * scale) {
            Image(systemName: Icons.musicNoteList)
                .font(.system(size: 48 * scale))
                .foregroundColor(.gray)

            Text("Queue is Empty")
                .font(.system(size: 15 * scale, weight: .semibold))

            Text("Play a song to start building your queue")
                .font(.system(size: 12 * scale))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Queue List View (LazyVStack-based)

    // A ScrollView + LazyVStack scrolls noticeably smoother than a List here:
    // List's NSTableView diffing stutters as per-row hover / now-playing state
    // updates, especially when layered over a translucent background.
    private var queueListView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(playlistManager.currentQueue.enumerated()), id: \.element.id) { pair in
                        queueRow(for: pair.element, at: pair.offset)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6 * scale)
            }
            .onAppear { scrollToCurrentTrack(using: proxy) }
        }
    }

    /// Brings the currently playing track to the top when the queue opens.
    private func scrollToCurrentTrack(using proxy: ScrollViewProxy) {
        let index = playlistManager.currentQueueIndex
        guard index >= 0, index < playlistManager.currentQueue.count else { return }
        let id = playlistManager.currentQueue[index].id
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: AnimationDuration.standardDuration)) {
                proxy.scrollTo(id, anchor: .top)
            }
        }
    }

    private func queueRow(for track: Track, at position: Int) -> some View {
        let isLastItem = position == playlistManager.currentQueue.count - 1
        let isCurrentTrack = position == playlistManager.currentQueueIndex

        return PlayQueueRow(
            track: track,
            position: position,
            isCurrentTrack: isCurrentTrack,
            isPlaying: isCurrentTrack && playbackManager.isPlaying,
            playlistManager: playlistManager,
            isLastItem: isLastItem,
            accentColor: accentColor,
            primaryTextColor: primaryTextColor,
            secondaryTextColor: secondaryTextColor,
            scale: scale
        )
        .onDrag {
            draggedIndex = position
            return NSItemProvider(object: track.id as NSString)
        }
        .onDrop(of: [UTType.text], delegate: QueueDropDelegate(
            destinationIndex: position,
            draggedIndex: $draggedIndex,
            playlistManager: playlistManager
        ))
    }
}

// MARK: - Queue Row Component

struct PlayQueueRow: View {
    let track: Track
    let position: Int
    let isCurrentTrack: Bool
    let isPlaying: Bool
    let playlistManager: PlaylistManager
    let isLastItem: Bool
    var accentColor: Color = .accentColor
    var primaryTextColor: Color = .primary
    var secondaryTextColor: Color = .secondary
    var scale: CGFloat = 1

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8 * scale) {
            trackInfo
            Spacer(minLength: 4)
            trackControls
        }
        .padding(.horizontal, 10 * scale)
        .padding(.vertical, 6 * scale)
        .background(rowBackground)
        .contentShape(Rectangle())
        // Played songs stay in the list, dimmed, as the Music app shows history.
        .opacity(isPlayed ? 0.5 : 1)
        .overlay(
            isLastItem ? nil : Rectangle()
                .frame(height: 0.5)
                .foregroundColor(Color.secondary.opacity(0.2))
                .padding(.horizontal, 10 * scale),
            alignment: .bottom
        )
        .onHover { hovering in
            if hovering != isHovered {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isHovered = hovering
                }
            }
        }
        .onTapGesture(count: 2) { handleDoubleClick() }
    }

    private var isPlayed: Bool {
        position < playlistManager.currentQueueIndex
    }

    private var trackInfo: some View {
        VStack(alignment: .leading, spacing: 2 * scale) {
            HStack(spacing: 5 * scale) {
                if isCurrentTrack {
                    Image(systemName: isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                        .font(.system(size: 10 * scale))
                        .foregroundStyle(accentColor)
                        .help(isPlaying ? String(localized: "Playing") : String(localized: "Paused"))
                }
                Text(track.title)
                    .font(.system(size: 13 * scale, weight: isCurrentTrack ? .semibold : .regular))
                    .lineLimit(1)
                    .foregroundColor(primaryTextColor)
            }

            Text(track.displayArtist)
                .font(.system(size: 11 * scale))
                .lineLimit(1)
                .foregroundColor(secondaryTextColor)
        }
    }

    private var trackControls: some View {
        HStack(spacing: 5 * scale) {
            Text(HelperUtils.formattedShortDuration(track.duration))
                .font(.system(size: 11 * scale))
                .foregroundColor(secondaryTextColor)
                .monospacedDigit()

            if isHovered && !isCurrentTrack {
                removeButton
            }
        }
    }

    private var removeButton: some View {
        Button {
            playlistManager.removeFromQueue(at: position)
        } label: {
            Image(systemName: Icons.xmarkCircleFill)
                .font(.system(size: 14 * scale))
                .foregroundColor(.secondary)
        }
        .help("Remove from queue")
        .buttonStyle(.plain)
        .transition(.scale.combined(with: .opacity))
    }

    private var rowBackground: some View {
        ZStack {
            if isCurrentTrack {
                primaryTextColor.opacity(0.1)
            } else if isHovered {
                primaryTextColor.opacity(0.05)
            } else {
                Color.clear
            }
        }
        .cornerRadius(6)
    }

    private func handleDoubleClick() {
        if !isCurrentTrack {
            playlistManager.playFromQueue(at: position)
        }
    }
}

// MARK: - Drag and Drop Delegate

struct QueueDropDelegate: DropDelegate {
    let destinationIndex: Int
    @Binding var draggedIndex: Int?
    let playlistManager: PlaylistManager

    func performDrop(info: DropInfo) -> Bool {
        draggedIndex = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let from = draggedIndex, from != destinationIndex else { return }
        withAnimation(.default) {
            playlistManager.moveInQueue(from: from, to: destinationIndex)
        }
        draggedIndex = destinationIndex
    }
}

// MARK: - Preview

#Preview {
    PlayQueueView()
        .environmentObject({
            let playbackManager = PlaybackManager(
                libraryManager: LibraryManager(),
                playlistManager: PlaylistManager()
            )
            return playbackManager
        }())
        .environmentObject({
            let playlistManager = PlaylistManager()
            let sampleTracks = (0..<5).map { i in
                var track = Track(url: URL(fileURLWithPath: "/path/to/sample\(i).mp3"))
                track.title = "Sample Song \(i)"
                track.artist = "Sample Artist"
                track.album = "Sample Album"
                track.duration = 180.0 + Double(i * 30)
                return track
            }
            playlistManager.replaceCurrentQueue(sampleTracks)
            return playlistManager
        }())
        .frame(width: 350, height: 600)
}

#Preview("Empty Queue") {
    PlayQueueView()
        .environmentObject({
            let playbackManager = PlaybackManager(
                libraryManager: LibraryManager(),
                playlistManager: PlaylistManager()
            )
            return playbackManager
        }())
        .environmentObject(PlaylistManager())
        .frame(width: 350, height: 600)
}
