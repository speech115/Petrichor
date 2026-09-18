//
// NowPlayingQueuePanel (iOS)
//
// The playback queue as a panel over the Now Playing artwork. Shows the whole
// queue with the current track highlighted; a tap jumps playback to that
// entry, rows reorder by dragging and a swipe removes them from the queue.
// Reuses PlaylistManager's queue methods — the view presents what the manager
// already does.
//
// Secondary text uses `.foregroundStyle(.secondary)`, not
// `Color.secondary`. The player sets its dark scheme through the SwiftUI
// environment, which does not reach the trait collection a `List` resolves
// semantic colors against: the artist, duration and position numbers came out
// in the light appearance's near-black and vanished into the panel.
//

import SwiftUI

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

    @State private var editMode = EditMode.inactive

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
        VStack(spacing: 0) {
            HStack {
                Text(TrackCountText.songs(playlistQueue.currentQueue.count))
                    .foregroundStyle(.secondary)
                Spacer()
                EditButton()
            }
            .padding(.horizontal, 20)
            .frame(minHeight: 44)

            List {
                ForEach(queueOccurrences) { occurrence in
                    queueRow(for: occurrence.track, at: occurrence.position)
                }
                .onMove { offsets, destination in
                    // This list has no multi-selection: native dragging moves one row.
                    guard let source = offsets.first, offsets.count == 1 else { return }
                    playlistManager.moveInQueue(
                        from: source,
                        to: destination > source ? destination - 1 : destination
                    )
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .listRowSpacing(0)
        }
        .environment(\.editMode, $editMode)
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

        return Button {
            playlistManager.playFromQueue(at: position)
        } label: {
            HStack(spacing: 12) {
                positionIndicator(isCurrentTrack: isCurrentTrack, position: position)

                VStack(alignment: .leading, spacing: 2) {
                    if isCurrentTrack {
                        Text(String(localized: "Now Playing"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(accentColor)
                    } else if position == playlistQueue.currentQueueIndex + 1 {
                        Text(String(localized: "Up Next"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text(track.title)
                        .font(.body.weight(isCurrentTrack ? .semibold : .regular))
                        .lineLimit(1)
                    Text(track.displayArtist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text(HelperUtils.formattedShortDuration(track.duration))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(isCurrentTrack ? accentColor.opacity(0.16) : Color.clear)
        .listRowSeparator(.hidden)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if !isCurrentTrack {
                Button(role: .destructive) {
                    playlistManager.removeFromQueue(at: position)
                } label: {
                    Label(String(localized: "Remove"), systemImage: Icons.trash)
                }
            }
        }
        .accessibilityActions {
            if position > 0 {
                Button(String(localized: "Move Up")) {
                    playlistManager.moveInQueue(from: position, to: position - 1)
                }
            }
            if position + 1 < playlistQueue.currentQueue.count {
                Button(String(localized: "Move Down")) {
                    playlistManager.moveInQueue(from: position, to: position + 1)
                }
            }
            if !isCurrentTrack {
                Button(String(localized: "Remove")) {
                    playlistManager.removeFromQueue(at: position)
                }
            }
        }
        .accessibilityLabel(Text("\(track.title), \(track.displayArtist)"))
        .accessibilityValue(isCurrentTrack ? Text(String(localized: "Now Playing")) : Text(""))
    }

    /// The play-state glyph sits in a fixed 24 pt column next to the track
    /// text, so it scales with Dynamic Type but stays capped to that column.
    @ScaledMetric(relativeTo: .caption) private var stateIconSize: CGFloat = 12

    private func positionIndicator(isCurrentTrack: Bool, position: Int) -> some View {
        Group {
            if isCurrentTrack {
                Image(systemName: playbackPresentation.isPlaying ? Icons.playFill : Icons.pauseFill)
                    .font(.system(size: min(stateIconSize, 16)))
                    .foregroundColor(accentColor)
            } else {
                Text("\(position + 1)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(width: 24)
    }
}
