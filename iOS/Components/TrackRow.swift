//
// TrackRow (iOS)
//
// The shared track row: artwork, title, artist, and a distinguishable playing
// state. Reused by the library, search, playlists, folders and the queue.
//
// Gestures live here so they work identically everywhere the row appears:
// swipe left to play next (with a confirmation haptic at gesture completion),
// long-press for the full context menu. VoiceOver exposes the same "Play Next"
// action as a custom action.
//
// Artwork is not preloaded into list track arrays: a Songs-sized library
// would carry megabytes of thumbnails before the first row paints. Visible
// rows fetch album thumbnails (and the rare track-only cover) through
// `ArtworkTile`'s loader as they appear.
//

import SwiftUI
import UIKit

struct TrackRow: View {
    let track: Track
    let onPlay: () -> Void
    /// Action/data dependencies are plain references on purpose. Observing the
    /// entire managers here made every queue-index change invalidate every row.
    let playlistManager: PlaylistManager
    let libraryManager: LibraryManager
    let playbackManager: PlaybackManager
    var menuContext: TrackContextMenu.MenuContext = .library
    var showsTrackNumber = false

    @ScaledMetric(relativeTo: .body) private var trackNumberWidth: CGFloat = 40

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onPlay) {
                HStack(spacing: 12) {
                    if showsTrackNumber {
                        Text(track.trackNumber.map(String.init) ?? "")
                            .font(.body.monospacedDigit())
                            .foregroundStyle(Color.secondaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .frame(width: trackNumberWidth, alignment: .trailing)
                    } else {
                        artworkView
                    }

                    TrackPlaybackStatus(
                        track: track,
                        playbackManager: playbackManager,
                        showsBars: showsTrackNumber
                    )
                    // Music starts the line between rows under the title,
                    // not under the cover.
                    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                }
                .frame(minHeight: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(TrackRowPressStyle())
            // One VoiceOver element per row: "title, artist" in a single phrase.
            // The custom actions below stay on that same element, so the row
            // remains operable after combining.
            .accessibilityElement(children: .combine)
            .accessibilityAction(named: String(localized: "Play Next")) {
                playNextWithConfirmation()
            }

            // Music's "…" at the end of every song: the same menu as a long
            // press, one tap away.
            Menu {
                contextMenuContent
            } label: {
                Label(String(localized: "More"), systemImage: "ellipsis")
                    .labelStyle(.iconOnly)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.secondaryText)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                playNextWithConfirmation()
            } label: {
                Label(String(localized: "Play Next"), systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            .tint(.green)
        }
        .contextMenu {
            contextMenuContent
        }
    }

    // MARK: - Gesture Actions

    private func playNextWithConfirmation() {
        ToastCenter.shared.enqueue(track, playNext: true, playlistManager: playlistManager)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    @ViewBuilder
    private var contextMenuContent: some View {
        Button(action: onPlay) {
            Label(String(localized: "Play"), systemImage: Icons.playFill)
        }
        Button {
            ToastCenter.shared.enqueue(track, playNext: true, playlistManager: playlistManager)
        } label: {
            Label(String(localized: "Play Next"), systemImage: "text.line.first.and.arrowtriangle.forward")
        }
        Button {
            ToastCenter.shared.enqueue(track, playNext: false, playlistManager: playlistManager)
        } label: {
            Label(String(localized: "Add to Queue"), systemImage: "text.append")
        }

        Divider()

        TrackMenuContent(track: track, playlistManager: playlistManager)

        if case .playlist(let playlist) = menuContext, playlist.type == .regular {
            Button(role: .destructive) {
                playlistManager.removeTrackFromPlaylist(track: track, playlistID: playlist.id)
            } label: {
                Label(String(localized: "Remove from Playlist"), systemImage: Icons.trash)
            }
        }
    }

    // MARK: - Artwork

    private var artworkCacheKey: String? {
        ArtworkDataLoader.cacheKey(albumId: track.albumId, trackId: track.trackId)
    }

    /// Visible rows without an in-memory thumbnail fetch it here.
    private var trackArtworkLoader: ArtworkDataLoader? {
        guard let trackId = track.trackId else { return nil }
        return ArtworkDataLoader.trackListArtwork(
            database: libraryManager.databaseManager,
            albumId: track.albumId,
            trackId: trackId,
            hasDisplayArtwork: track.displayArtwork != nil
        )
    }

    /// Music's 48 pt cover, with the playing mark drawn over it.
    private var artworkView: some View {
        ArtworkTile(
            data: track.displayArtwork,
            cacheKey: artworkCacheKey,
            maxPixelSize: 144,
            loader: trackArtworkLoader
        )
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay {
                ArtworkPlayingIndicator(track: track, playbackManager: playbackManager)
            }
    }
}

extension View {
    /// Music's song row in a list: a 48 pt cover with 4 pt above and below
    /// (56 pt in all), 20 pt in from the edge, the "…" close to the right
    /// edge, and a light line between rows. Callers apply it after
    /// `.equatable()`: list-row settings made inside an `EquatableView` never
    /// reach the list, which then pads the row to 78 pt.
    func songRowListStyle() -> some View {
        listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 9))
            .listRowSeparatorTint(Color.primary.opacity(0.12))
    }
}

extension TrackRow: Equatable {
    // `TrackRow` is `@MainActor`-inferred (it's a `View`), but `Equatable`'s
    // requirement isn't isolated by its own declaration - an "isolated
    // conformance" the checker can't verify calls into from outside. SwiftUI
    // itself calls `==` synchronously from the main thread as part of view
    // diffing (that's the whole point of conforming a `View` to `Equatable`),
    // so `nonisolated` plus `assumeIsolated` turns that real guarantee into a
    // checked one instead of leaving the conformance unimplementable. The
    // contract behind it (SE-0470, SE-0392): `TrackRow` only ever lives on the main
    // thread, so a call to `==` from anywhere else is a programmer error and
    // traps at runtime.
    nonisolated static func == (lhs: TrackRow, rhs: TrackRow) -> Bool {
        MainActor.assumeIsolated {
            lhs.track.id == rhs.track.id
                && lhs.track.title == rhs.track.title
                && lhs.track.artist == rhs.track.artist
                && lhs.track.isFavorite == rhs.track.isFavorite
                && lhs.track.albumId == rhs.track.albumId
                && lhs.track.trackNumber == rhs.track.trackNumber
                && lhs.showsTrackNumber == rhs.showsTrackNumber
                && lhs.track.displayArtwork?.count == rhs.track.displayArtwork?.count
                && lhs.playlistManager === rhs.playlistManager
                && lhs.libraryManager === rhs.libraryManager
                && lhs.playbackManager === rhs.playbackManager
                && sameMenuContext(lhs.menuContext, rhs.menuContext)
        }
    }

    private static func sameMenuContext(
        _ lhs: TrackContextMenu.MenuContext,
        _ rhs: TrackContextMenu.MenuContext
    ) -> Bool {
        switch (lhs, rhs) {
        case (.library, .library):
            return true
        case (.playlist(let left), .playlist(let right)):
            return left.id == right.id
                && left.dateModified == right.dateModified
                && left.tracks.count == right.tracks.count
        default:
            return false
        }
    }
}

/// Only this small label/status subtree observes playback. Starting a queue no
/// longer rebuilds the artwork, gestures and context menu of every visible row.
private struct TrackPlaybackStatus: View {
    let track: Track
    @ObservedObject var playbackManager: PlaybackManager
    /// Rows without a cover (an album's numbered songs) keep the trailing
    /// bars; rows with one mark the cover instead.
    var showsBars: Bool

    private var isCurrent: Bool {
        playbackManager.isCurrent(track)
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                // One line each, truncated at the tail, as Apple Music does:
                // a wrapped title made rows of uneven height. VoiceOver and
                // the context menu still carry the full name.
                Text(track.title)
                    .font(.body.weight(isCurrent ? .semibold : .regular))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text(track.displayArtist)
                    .font(.subheadline)
                    .foregroundColor(.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if showsBars {
                if isCurrent {
                    EqualizerBars(animating: playbackManager.isPlaying)
                } else {
                    Color.clear
                        .frame(width: 18)
                }
            }
        }
    }
}

/// Grey press flash like Apple Music rows. Background only — scale would
/// jitter neighbouring list rows.
private struct TrackRowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.primary.opacity(0.06) : .clear)
            .animation(
                .easeOut(duration: AnimationDuration.quickDuration),
                value: configuration.isPressed
            )
    }
}
