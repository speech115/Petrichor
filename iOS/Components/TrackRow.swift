//
// TrackRow (iOS)
//
// The shared track row: artwork, title, artist, and a distinguishable playing
// state. Reused by the library, search, playlists, folders and the queue.
//
// Gestures live here so they work identically everywhere the row appears:
// swipe right to add to a playlist, swipe left to play next (with a
// confirmation haptic at gesture completion), long-press for the full
// context menu. VoiceOver exposes the same two actions as custom actions.
//
// Artwork is normally carried by the track: every list wrapper in
// LibraryManager fills `albumArtworkThumbnail` before rows are handed to the
// screen. The one case it cannot cover is a cover that hangs off the track
// instead of an album — 404 of them in a 2919-track library, full size, so
// loading them with every list would cost ~29 MB of blobs no list shows at
// once. Those rows fetch their own, one row at a time, as they appear.
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

    @State private var showingPlaylistPicker = false

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 12) {
                artworkView
                    .frame(width: 44, height: 44)

                TrackPlaybackStatus(track: track, playbackManager: playbackManager)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // One VoiceOver element per row: "title, artist" in a single phrase.
        // The custom actions below stay on that same element, so the row
        // remains operable after combining.
        .accessibilityElement(children: .combine)
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                showingPlaylistPicker = true
            } label: {
                Label(String(localized: "Add to Playlist"), systemImage: "text.badge.plus")
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
        .confirmationDialog(
            String(localized: "Add to Playlist"),
            isPresented: $showingPlaylistPicker,
            titleVisibility: .visible
        ) {
            ForEach(regularPlaylists) { playlist in
                Button(PlaylistDisplay.name(for: playlist)) {
                    playlistManager.updateTrackInPlaylist(track: track, playlist: playlist, add: true)
                }
            }
            Button(String(localized: "New Playlist...")) {
                playlistManager.showCreatePlaylistModal(with: [track])
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        }
        .accessibilityAction(named: String(localized: "Play Next")) {
            playNextWithConfirmation()
        }
        .accessibilityAction(named: String(localized: "Add to Playlist")) {
            showingPlaylistPicker = true
        }
    }

    // MARK: - Gesture Actions

    private func playNextWithConfirmation() {
        playlistManager.playNext(track)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private var regularPlaylists: [Playlist] {
        playlistManager.playlists.filter { $0.type == .regular }
    }

    @ViewBuilder
    private var contextMenuContent: some View {
        Button(action: onPlay) {
            Label(String(localized: "Play"), systemImage: Icons.playFill)
        }
        Button {
            playlistManager.playNext(track)
        } label: {
            Label(String(localized: "Play Next"), systemImage: "text.line.first.and.arrowtriangle.forward")
        }
        Button {
            playlistManager.addToQueue(track)
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
        if let albumId = track.albumId { return "album-\(albumId)" }
        return track.trackId.map { "track-\($0)" }
    }

    /// Only for rows the album could not supply: everything else already has
    /// its thumbnail and must not touch the database.
    private var trackArtworkLoader: ArtworkDataLoader? {
        guard track.displayArtwork == nil, let trackId = track.trackId else { return nil }
        let database = libraryManager.databaseManager
        let albumId = track.albumId
        return ArtworkDataLoader {
            if let albumId,
               let thumbnail = database.getAlbumArtworkThumbnail(albumId: albumId) {
                return thumbnail
            }
            return database.getArtworkData(albumId: nil, trackId: trackId)
        }
    }

    private var artworkView: some View {
        ArtworkTile(
            data: track.displayArtwork,
            cacheKey: artworkCacheKey,
            maxPixelSize: 144,
            loader: trackArtworkLoader,
            isDecorative: true
        )
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            // accessibilityHidden alone leaves the decoded image in the tree;
            // collapsing the tile to one element first actually hides it.
            .accessibilityElement(children: .ignore)
            .accessibilityHidden(true)
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
        case (.folder(let left), .folder(let right)):
            return left.id == right.id && left.url == right.url
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

    private var isCurrent: Bool {
        guard let current = playbackManager.currentTrack else { return false }
        if let currentID = current.trackId, let trackID = track.trackId {
            return currentID == trackID
        }
        return current.url.path == track.url.path
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                // No line limit on the title: the accessibility audit flags
                // any truncation ("Text clipped"), and a wrapped title keeps
                // the full name readable at accessibility sizes.
                Text(track.title)
                    .font(.body.weight(isCurrent ? .semibold : .regular))
                // Same reasoning as the title: a capped line limit is what
                // the audit calls clipped at accessibility sizes.
                Text(track.displayArtist)
                    .font(.subheadline)
                    .foregroundColor(.secondaryText)
            }

            Spacer(minLength: 8)

            if isCurrent {
                EqualizerBars(animating: playbackManager.isPlaying)
            } else {
                Color.clear
                    .frame(width: 18)
            }
        }
    }
}
