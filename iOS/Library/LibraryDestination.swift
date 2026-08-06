//
// LibraryDestination (iOS)
//
// Navigation values for the Home tab's NavigationStack: Discover, a
// category's item list (artists, albums, genres, years), a category's track
// list, all tracks, and the artist and album detail pages.
//

import Foundation

enum LibraryDestination: Hashable {
    case discover
    case category(LibraryFilterType)
    case tracks(LibraryFilterItem)
    case allTracks
    case artist(name: String)
    case album(AlbumEntity)
}
