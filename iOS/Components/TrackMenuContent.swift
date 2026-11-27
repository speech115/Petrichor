//
// TrackMenuContent (iOS)
//
// The track actions that every iOS menu shares, in Music's order: Favorite
// and Share side by side on top, then Add to Playlist, then Go to, View
// Credits and Share Lyrics. The row's long-press menu puts the playback
// actions above these; the player's ellipsis button shows them on their own.
// Music's Pin Song, Create Station and Remove Download have no counterpart
// in a local library and are left out.
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
        // Music's top row: Favorite and Share side by side, each a glyph
        // over its name.
        ControlGroup {
            Button {
                ToastCenter.shared.toggleFavorite(track, playlistManager: playlistManager)
            } label: {
                Label(
                    track.isFavorite ? String(localized: "Undo Favorite") : String(localized: "Favorite"),
                    systemImage: track.isFavorite ? "star.slash" : Icons.star
                )
            }
            ShareLink(item: track.url, preview: SharePreview(track.title)) {
                Label(String(localized: "Share"), systemImage: "square.and.arrow.up")
            }
        }

        Section {
            Button {
                NotificationCenter.default.post(name: .addTrackToPlaylist, object: nil, userInfo: ["track": track])
            } label: {
                Label(String(localized: "Add to Playlist"), systemImage: "text.badge.plus")
            }
        }

        Section {
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
                Label(String(localized: "Go to"), systemImage: "arrow.up.right")
            }

            Button {
                NotificationCenter.default.post(
                    name: .showTrackInfo,
                    object: nil,
                    userInfo: ["track": track]
                )
            } label: {
                Label(String(localized: "View Credits"), systemImage: Icons.infoCircle)
            }

            // Only once the lyrics are loaded (the player's lyrics panel
            // loads them): a menu cannot wait on a file read.
            if let lyrics = LyricsStore.shared.cachedLyrics(for: track.id), !lyrics.lines.isEmpty {
                ShareLink(
                    item: lyrics.lines.map(\.text).joined(separator: "\n"),
                    subject: Text(track.title)
                ) {
                    Label(String(localized: "Share Lyrics"), systemImage: "quote.bubble")
                }
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
