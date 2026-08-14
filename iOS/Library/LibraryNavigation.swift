//
// LibraryNavigation (iOS)
//
// Resolves a library filter item to the destination it opens and the album
// entity it names. One copy each, instead of the per-screen duplicates in
// ContentView and CategoryItemsView.
//

import SwiftUI

@MainActor
enum LibraryNavigation {
    /// In-memory album entity for a filter item: id first, then name.
    static func albumEntity(
        for item: LibraryFilterItem,
        libraryManager: LibraryManager
    ) -> AlbumEntity? {
        if let albumId = item.albumId {
            return libraryManager.albumEntities.first { $0.albumId == albumId }
        }
        return libraryManager.albumEntities.first { $0.name == item.name }
    }

    /// Artists and albums get their detail pages; everything else (genres,
    /// years, composers, album artists) becomes a plain filtered track list.
    static func destination(
        for filterType: LibraryFilterType,
        item: LibraryFilterItem,
        libraryManager: LibraryManager
    ) -> LibraryDestination {
        switch filterType {
        case .artists:
            return .artist(name: item.name)
        case .albums:
            return .album(
                albumEntity(for: item, libraryManager: libraryManager)
                    ?? AlbumEntity(name: item.name, trackCount: item.count)
            )
        default:
            return .tracks(item)
        }
    }
}
