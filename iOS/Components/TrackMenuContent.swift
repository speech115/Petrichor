//
// TrackMenuContent (iOS)
//
// The track actions that every iOS menu shares: info, "Go to",
// playlists and favorites. The row's long-press menu puts the playback actions
// above these; the player's ellipsis button shows them on their own.
//
// Each entry is a plain `Button` with a `Label` and nothing else. That is what
// lets UIKit turn the menu into native `UIAction`s. Wrapping a label in an
// HStack, adding a `Spacer` or a `.buttonStyle` makes SwiftUI host a view
// inside the menu instead, and a hosted view is not ready when the menu's open
// animation starts — the rows read as grey placeholders until it finishes and
// they ignore the menu's own appearance while it plays.
//

import SwiftUI
import UIKit

struct TrackMenuContent: View {
    let track: Track
    let playlistManager: PlaylistManager

    var body: some View {
        Button {
            NotificationCenter.default.post(
                name: .showTrackInfo,
                object: nil,
                userInfo: ["track": track]
            )
        } label: {
            Label(String(localized: "Show Info"), systemImage: Icons.infoCircle)
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

        Button {
            NotificationCenter.default.post(name: .addTrackToPlaylist, object: nil, userInfo: ["track": track])
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
            return values.filter { !$0.isEmpty && $0 != filterType.unknownPlaceholder }.map { filterValue in
                TrackFilterDestination(
                    filterType: filterType,
                    value: filterValue,
                    title: "\(filterType.pluralDisplayName): \(filterType.localizedDisplay(filterValue))"
                )
            }
        }
    }
}

struct TrackFilterDestination: Identifiable {
    let filterType: LibraryFilterType
    let value: String
    let title: String

    var id: String { "\(filterType.rawValue)-\(value)" }
}
