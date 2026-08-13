//
// TrackSortField
//
// Track sort key, keyed by raw string for `UserDefaults`/`PlaylistSortManager`
// persistence. The macOS-only comparator machinery (`KeyPathComparator<Track>`,
// which reaches into `Table`-sort-column properties that only exist on macOS)
// lives in the `extension TrackSortField` inside
// `Views/Components/TrackViews/TrackTableOptionsDropdown.swift`, alongside the
// dropdown view that is its only real user. This base declaration is what
// `PlaylistSortManager` (shared, `Managers/`) needs to store and look up a
// preference on both platforms.
//

enum TrackSortField: String, CaseIterable {
    case trackNumber
    case discNumber
    case favorite
    case title
    case artist
    case album
    case genre
    case year
    case composer
    case filename
    case duration
    case dateAdded
    case dateFavorited
    case playCount
    case lastPlayedDate
    case custom
}
