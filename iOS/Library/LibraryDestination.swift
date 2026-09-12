//
// LibraryDestination (iOS)
//
// Navigation values for the Home tab's NavigationStack: Discover, a
// category's item list (artists, albums), a category's track list, all
// tracks, and the artist and album detail pages. Genres and years are
// reachable only as filtered track lists (`.tracks`), not as browsing
// categories.
//

import Foundation

enum LibraryDestination: Hashable {
    case category(LibraryFilterType)
    case tracks(LibraryFilterItem)
    case allTracks
    case recentlyAdded
    case artist(name: String)
    case album(AlbumEntity)
    case playlist(UUID)
}
