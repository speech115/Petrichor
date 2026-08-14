//
// TrackCountText (iOS)
//
// Localized track-count strings shared by the detail headers and list rows.
// One copy of the pluralization and the year-aware "year • N songs" subtitle,
// instead of a literal `String(localized:)` at every call site.
//

import SwiftUI

enum TrackCountText {
    static func songs(_ count: Int) -> String {
        String(localized: "\(count) songs")
    }

    /// "year • N songs", or just "N songs" when the year is unknown.
    static func albumSubtitle(_ album: AlbumEntity) -> String {
        let year = LibraryFilterType.years.localizedDisplay(album.year ?? "")
        let count = songs(album.trackCount)
        if !year.isEmpty, year != LibraryFilterType.years.localizedUnknownPlaceholder {
            return "\(year) • \(count)"
        }
        return count
    }
}
