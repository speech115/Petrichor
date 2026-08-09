//
// NowPlayingQueuePanel (iOS)
//
// The playback queue as a panel over the Now Playing artwork. Shows the whole
// queue with the current track highlighted; rows reorder by dragging and a
// swipe removes them from the queue. Reuses PlaylistManager's queue methods —
// the view presents what the manager already does.
//

import SwiftUI
import UniformTypeIdentifiers

struct NowPlayingQueuePanel: View {
    private struct QueueOccurrence: Identifiable {
        let id: String
        let track: Track
        let position: Int
    }

    let accentColor: Color
    let playbackManager: PlaybackManager
    let playlistManager: PlaylistManager
    @ObservedObject private var playbackPresentation: PlaybackPresentationObservation
    @ObservedObject private var playlistQueue: PlaylistQueueObservation

    @State private var draggedIndex: Int?

    init(
        accentColor: Color,
        playbackManager: PlaybackManager,
        playlistManager: PlaylistManager
    ) {
        self.accentColor = accentColor
        self.playbackManager = playbackManager
        self.playlistManager = playlistManager
        playbackPresentation = playbackManager.presentationObservation
        playlistQueue = playlistManager.queueObservation
    }

    var body: some View {
        if playlistQueue.currentQueue.isEmpty {
            emptyQueueView
        } else {
            queueList
        }
    }

    // MARK: - Empty Queue

    private var emptyQueueView: some View {
        ContentUnavailableView(
            String(localized: "Queue is Empty"),
            systemImage: Icons.musicNoteList,
            description: Text(String(localized: "Play a song to start building your queue"))
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Queue List

    private var queueList: some View {
        List {
            ForEach(queueOccurrences) { occurrence in
                queueRow(for: occurrence.track, at: occurrence.position)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .listRowSpacing(0)
    }

    private var queueOccurrences: [QueueOccurrence] {
        var occurrencesByTrackID: [String: Int] = [:]

        return playlistQueue.currentQueue.enumerated().map { position, track in
            let occurrence = occurrencesByTrackID[track.id, default: 0]
            occurrencesByTrackID[track.id] = occurrence + 1
            return QueueOccurrence(
                id: "\(track.id)#\(occurrence)",
                track: track,
                position: position
            )
        }
    }

    private func queueRow(for track: Track, at position: Int) -> some View {
        let isCurrentTrack = position == playlistQueue.currentQueueIndex

        return HStack(spacing: 12) {
            positionIndicator(isCurrentTrack: isCurrentTrack, position: position)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.body.weight(isCurrentTrack ? .semibold : .regular))
                    .lineLimit(1)
                Text(track.displayArtist)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(HelperUtils.formattedShortDuration(track.duration))
                .font(.caption)
                .foregroundColor(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .listRowBackground(isCurrentTrack ? accentColor.opacity(0.16) : Color.clear)
        .listRowSeparator(.hidden)
        .onDrag {
            draggedIndex = position
            return NSItemProvider(object: track.id as NSString)
        }
        .onDrop(of: [UTType.text], delegate: QueueDropDelegate(
            destinationIndex: position,
            draggedIndex: $draggedIndex,
            playlistManager: playlistManager
        ))
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if !isCurrentTrack {
                Button(role: .destructive) {
                    playlistManager.removeFromQueue(at: position)
                } label: {
                    Label(String(localized: "Remove"), systemImage: Icons.trash)
                }
            }
        }
        .accessibilityLabel(Text(track.title))
        .accessibilityValue(isCurrentTrack ? Text(String(localized: "Now Playing")) : Text(""))
    }

    private func positionIndicator(isCurrentTrack: Bool, position: Int) -> some View {
        Group {
            if isCurrentTrack {
                Image(systemName: playbackPresentation.isPlaying ? Icons.playFill : Icons.pauseFill)
                    .font(.system(size: 12))
                    .foregroundColor(accentColor)
            } else {
                Text("\(position + 1)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(width: 24)
    }
}

// MARK: - Drag and Drop Delegate

private struct QueueDropDelegate: DropDelegate {
    let destinationIndex: Int
    @Binding var draggedIndex: Int?
    let playlistManager: PlaylistManager

    func performDrop(info: DropInfo) -> Bool {
        draggedIndex = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let from = draggedIndex, from != destinationIndex else { return }
        withAnimation(.spring(response: 0.24, dampingFraction: 0.90)) {
            playlistManager.moveInQueue(from: from, to: destinationIndex)
        }
        draggedIndex = destinationIndex
    }
}
