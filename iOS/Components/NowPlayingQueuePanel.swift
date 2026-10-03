//
// NowPlayingQueuePanel (iOS)
//
// The playback queue as a panel over the Now Playing artwork. Shows the whole
// queue with the current track highlighted; a tap jumps playback to that
// entry, rows reorder by dragging and a swipe removes them from the queue.
// Shuffle and repeat sit in its header, where Apple Music keeps them.
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

    let palette: PlayerPalette
    let playbackManager: PlaybackManager
    let playlistManager: PlaylistManager
    @ObservedObject private var playbackPresentation: PlaybackPresentationObservation
    @ObservedObject private var playlistQueue: PlaylistQueueObservation
    @ObservedObject private var playlistTransport: PlaylistTransportObservation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var editMode = EditMode.inactive

    init(
        palette: PlayerPalette,
        playbackManager: PlaybackManager,
        playlistManager: PlaylistManager
    ) {
        self.palette = palette
        self.playbackManager = playbackManager
        self.playlistManager = playlistManager
        playbackPresentation = playbackManager.presentationObservation
        playlistQueue = playlistManager.queueObservation
        playlistTransport = playlistManager.transportObservation
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
            HStack(spacing: 8) {
                modeButton(
                    icon: Icons.shuffleFill,
                    isActive: playlistTransport.isShuffleEnabled,
                    label: String(localized: "Shuffle")
                ) {
                    playlistManager.toggleShuffle()
                }
                modeButton(
                    icon: Icons.repeatIcon(for: playlistTransport.repeatMode),
                    isActive: playlistTransport.repeatMode != .off,
                    label: String(localized: "Repeat")
                ) {
                    playlistManager.toggleRepeatMode()
                }
                Text(TrackCountText.songs(playlistQueue.currentQueue.count))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, 4)
                Spacer()
                EditButton()
                    .tint(palette.foreground)
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

    @ScaledMetric(relativeTo: .subheadline) private var modeIconSize: CGFloat = 15

    /// Shuffle and repeat read as toggles, Apple Music's way: the active
    /// state is a solid light capsule with a dark glyph, not just a recolor,
    /// so the state survives a glance.
    private func modeButton(
        icon: String,
        isActive: Bool,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: min(modeIconSize, 22), weight: .semibold))
                .foregroundColor(isActive ? Color.black.opacity(0.8) : palette.accessory)
                .contentTransition(.symbolEffect(.replace.offUp))
                .frame(width: 52, height: 32)
                .background {
                    Capsule()
                        .fill(isActive ? palette.control : palette.chip)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isActive)
                }
                .frame(height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(TransportButtonStyle())
        .disabled(playbackPresentation.currentTrack == nil)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        // Shuffle and repeat change only from here while the panel is up.
        .sensoryFeedback(.selection, trigger: "\(icon)|\(isActive)")
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
                            .foregroundStyle(palette.foreground)
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
        .listRowBackground(isCurrentTrack ? palette.foreground.opacity(0.16) : Color.clear)
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
                    .foregroundColor(palette.foreground)
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
