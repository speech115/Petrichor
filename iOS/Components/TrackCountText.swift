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

    /// The album's display year, or nil when unknown (empty or the "Unknown"
    /// placeholder).
    static func year(_ album: AlbumEntity) -> String? {
        let year = LibraryFilterType.years.localizedDisplay(album.year ?? "")
        guard !year.isEmpty, year != LibraryFilterType.years.localizedUnknownPlaceholder else {
            return nil
        }
        return year
    }

    /// "year • N songs", or just "N songs" when the year is unknown.
    static func albumSubtitle(_ album: AlbumEntity) -> String {
        if let year = year(album) {
            return "\(year) • \(songs(album.trackCount))"
        }
        return songs(album.trackCount)
    }
}
