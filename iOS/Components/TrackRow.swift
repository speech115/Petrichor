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

        Button(action: showTrackInfo) {
            Label(String(localized: "Show Info"), systemImage: Icons.infoCircle)
        }
        Button {
            UIPasteboard.general.string = track.url.path
        } label: {
            Label(String(localized: "Copy File Path"), systemImage: "doc.on.doc")
        }

        Menu {
            ForEach(goToDestinations) { destination in
                Button(destination.title) {
                    NotificationCenter.default.post(
                        name: .goToLibraryFilter,
                        object: nil,
                        userInfo: [
                            "filterType": destination.filterType,
                            "filterValue": destination.value
                        ]
                    )
                }
            }
        } label: {
            Label(String(localized: "Go to"), systemImage: "arrow.up.right.square")
        }

        Menu {
            Button {
                playlistManager.showCreatePlaylistModal(with: [track])
            } label: {
                Label(String(localized: "New Playlist..."), systemImage: "plus")
            }

            ForEach(regularPlaylists) { playlist in
                let isInPlaylist = playlistManager.playlistContainsTrack(track, in: playlist)
                Button {
                    playlistManager.updateTrackInPlaylist(
                        track: track,
                        playlist: playlist,
                        add: !isInPlaylist
                    )
                } label: {
                    Label(
                        DefaultPlaylists.displayName(for: playlist),
                        systemImage: isInPlaylist ? "checkmark" : "plus"
                    )
                }
            }
        } label: {
            Label(String(localized: "Add to Playlist"), systemImage: "text.badge.plus")
        }

        Button {
            playlistManager.toggleFavorite(for: track)
        } label: {
            Label(
                track.isFavorite
                    ? String(localized: "Remove from Favorites")
                    : String(localized: "Add to Favorites"),
                systemImage: track.isFavorite ? Icons.starFill : Icons.star
            )
        }

        if case .playlist(let playlist) = menuContext, playlist.type == .regular {
            Button(role: .destructive) {
                playlistManager.removeTrackFromPlaylist(track: track, playlistID: playlist.id)
            } label: {
                Label(String(localized: "Remove from Playlist"), systemImage: Icons.trash)
            }
        }
    }

    private var goToDestinations: [TrackFilterDestination] {
        LibraryFilterType.allCases.flatMap { filterType in
            let value = filterType.getValue(from: track)
            let values: [String]
            if filterType.usesMultiArtistParsing {
                values = ArtistParser.parse(
                    value,
                    unknownPlaceholder: filterType.unknownPlaceholder,
                    role: filterType.artistRole
                )
            } else {
                values = [value.isEmpty ? filterType.unknownPlaceholder : value]
            }
            return values.map { filterValue in
                TrackFilterDestination(
                    filterType: filterType,
                    value: filterValue,
                    title: "\(filterType.pluralDisplayName): \(filterType.localizedDisplay(filterValue))"
                )
            }
        }
    }

    private func showTrackInfo() {
        NotificationCenter.default.post(
            name: NSNotification.Name("ShowTrackInfo"),
            object: nil,
            userInfo: ["track": track]
        )
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
            loader: trackArtworkLoader
        )
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct TrackFilterDestination: Identifiable {
    let filterType: LibraryFilterType
    let value: String
    let title: String

    var id: String { "\(filterType.rawValue)-\(value)" }
}

extension TrackRow: Equatable {
    static func == (lhs: TrackRow, rhs: TrackRow) -> Bool {
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
                Text(track.title)
                    .font(.body.weight(isCurrent ? .semibold : .regular))
                    .lineLimit(1)
                Text(track.displayArtist)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
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
