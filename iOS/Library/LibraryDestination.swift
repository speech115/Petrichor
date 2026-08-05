//
// LibraryDestination (iOS)
//
// Navigation values for the Library tab's NavigationStack: a category's item
// list (artists, albums, genres, years), a category's track list, or all tracks.
//

import Foundation

enum LibraryDestination: Hashable {
    case category(LibraryFilterType)
    case tracks(LibraryFilterItem)
    case allTracks
}
