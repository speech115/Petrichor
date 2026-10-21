//
// NowPlayingQueuePanel (iOS)
//
// The playback queue as a panel over the Now Playing artwork, in Apple
// Music's layout: wide Shuffle and Repeat toggles, then "Playing Next" (with
// the playlist it comes from) opened at the top; the tracks already played sit
// above it as History, dimmed, one scroll up. The current track is the panel
// header, not a row. A tap jumps playback to that entry, rows reorder by a
// long-press drag and a swipe removes them from the queue.
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

    private static let upNextAnchor = "queue.upNext"

    private var queueList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
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
            }
            .padding(.horizontal, 20)

            ScrollViewReader { proxy in
                List {
                    let occurrences = queueOccurrences
                    let current = playlistQueue.currentQueueIndex
                    let history = occurrences.filter { $0.position < current }
                    let upcoming = occurrences.filter { $0.position > current }

                    if !history.isEmpty {
                        Section {
                            ForEach(history) { occurrence in
                                queueRow(for: occurrence.track, at: occurrence.position, isReorderable: false)
                                    .opacity(0.55)
                            }
                        } header: {
                            sectionHeader(String(localized: "History"), subtitle: nil)
                        }
                    }

                    Section {
                        ForEach(upcoming) { occurrence in
                            queueRow(for: occurrence.track, at: occurrence.position)
                        }
                        .onMove { offsets, destination in
                            // This list has no multi-selection: native dragging moves one row.
                            guard let source = offsets.first, offsets.count == 1 else { return }
                            // Offsets count from the first upcoming row.
                            let first = current + 1
                            playlistManager.moveInQueue(
                                from: first + source,
                                to: first + (destination > source ? destination - 1 : destination)
                            )
                        }
                    } header: {
                        sectionHeader(String(localized: "Playing Next"), subtitle: sourceName.map { String(localized: "From \($0)") })
                            .id(Self.upNextAnchor)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .listRowSpacing(0)
                .onAppear {
                    proxy.scrollTo(Self.upNextAnchor, anchor: .top)
                }
            }
        }
    }

    /// The playlist the queue was started from; library queues have no name.
    private var sourceName: String? {
        guard playlistManager.currentQueueSource == .playlist else { return nil }
        return playlistManager.queueSourceName
    }

    private func sectionHeader(_ title: String, subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.headline)
                .foregroundStyle(palette.foreground)
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .textCase(nil)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
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
                .frame(maxWidth: .infinity, minHeight: 36)
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

    private func queueRow(for track: Track, at position: Int, isReorderable: Bool = true) -> some View {
        let isCurrentTrack = position == playlistQueue.currentQueueIndex

        return Button {
            playlistManager.playFromQueue(at: position)
        } label: {
            HStack(spacing: 12) {
                artwork(for: track)

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.body)
                        .lineLimit(1)
                    Text(track.displayArtist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                // Apple Music's reorder mark. The drag itself is the List's
                // long-press reorder, so the glyph only says it is there.
                if isReorderable {
                    Image(systemName: "line.3.horizontal")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
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

    private func artwork(for track: Track) -> some View {
        ArtworkTile(
            data: track.displayArtwork,
            cacheKey: ArtworkDataLoader.cacheKey(albumId: track.albumId, trackId: track.trackId),
            maxPixelSize: 144,
            loader: artworkLoader(for: track)
        )
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func artworkLoader(for track: Track) -> ArtworkDataLoader? {
        guard let trackId = track.trackId,
              let database = playlistManager.libraryManager?.databaseManager else { return nil }
        return ArtworkDataLoader.trackListArtwork(
            database: database,
            albumId: track.albumId,
            trackId: trackId,
            hasDisplayArtwork: track.displayArtwork != nil
        )
    }
}
