//
// DatabaseManager class extension
//
// This extension contains all the methods for querying category items for
// Album, Artist, Album artist, Composer, Genre, Decades, and Years.
//

import Foundation
import GRDB
import PetrichorCore

extension DatabaseManager {
    // MARK: - Helper Methods

    private func rowToFilterItem(_ row: Row, filterType: LibraryFilterType) -> LibraryFilterItem {
        let name = row["name"] as? String ?? ""
        let columnName = (filterType == .decades) ? "decade" : "name"
        let actualName = row[columnName] as? String ?? name

        let count: Int
        if let count64 = row["track_count"] as? Int64 {
            count = Int(count64)
        } else if let countInt = row["track_count"] as? Int {
            count = countInt
        } else {
            count = 0
        }

        // Albums carry their id so a merge can target the exact album (titles aren't unique).
        let albumId: Int64? = filterType == .albums ? row["id"] : nil

        return LibraryFilterItem(
            name: actualName,
            count: count,
            filterType: filterType,
            albumId: albumId
        )
    }

    // MARK: - Home - Entities

    func getArtistEntities() -> [ArtistEntity] {
        do {
            return try rows(core.artistEntities(hideDuplicates: hideDuplicateTracks)).map { row in
                ArtistEntity(name: row["name"], trackCount: row["trackCount"] ?? 0)
            }
        } catch {
            Logger.error("Failed to read artist_entities: \(error)")
            return []
        }
    }

    func getAlbumEntities() -> [AlbumEntity] {
        do {
            return try rows(core.albumEntities(hideDuplicates: hideDuplicateTracks)).map { row in
                AlbumEntity(
                    name: row["title"],
                    trackCount: row["trackCount"] ?? 0,
                    albumId: row["id"],
                    year: (row["release_year"] as Int?).map { String($0) } ?? "",
                    artistName: row["artistName"]
                )
            }
        } catch {
            Logger.error("Failed to read album_entities: \(error)")
            return []
        }
    }

    func getArtistFilterItems() -> [LibraryFilterItem] {
        do {
            return try rows(core.artistFilterItems(hideDuplicates: hideDuplicateTracks)).map { row in rowToFilterItem(row, filterType: .artists) }
        } catch {
            Logger.error("Failed to read artist_filter_items: \(error)")
            return []
        }
    }

    func getAlbumFilterItems() -> [LibraryFilterItem] {
        do {
            return try rows(core.albumFilterItems(hideDuplicates: hideDuplicateTracks)).map { row in rowToFilterItem(row, filterType: .albums) }
        } catch {
            Logger.error("Failed to read album_filter_items: \(error)")
            return []
        }
    }

    func getAlbumArtistFilterItems() -> [LibraryFilterItem] {
        do {
            return try rows(core.albumArtistFilterItems(hideDuplicates: hideDuplicateTracks)).map { row in
                rowToFilterItem(row, filterType: .albumArtists)
            }
        } catch {
            Logger.error("Failed to read album_artist_filter_items: \(error)")
            return []
        }
    }

    func getComposerFilterItems() -> [LibraryFilterItem] {
        do {
            return try rows(core.composerFilterItems(hideDuplicates: hideDuplicateTracks)).map { row in rowToFilterItem(row, filterType: .composers) }
        } catch {
            Logger.error("Failed to read composer_filter_items: \(error)")
            return []
        }
    }

    func getGenreFilterItems() -> [LibraryFilterItem] {
        do {
            return try rows(core.genreFilterItems(hideDuplicates: hideDuplicateTracks)).map { row in rowToFilterItem(row, filterType: .genres) }
        } catch {
            Logger.error("Failed to read genre_filter_items: \(error)")
            return []
        }
    }

    func getDecadeFilterItems() -> [LibraryFilterItem] {
        do {
            return try rows(core.decadeFilterItems(hideDuplicates: hideDuplicateTracks)).map { row in rowToFilterItem(row, filterType: .decades) }
        } catch {
            Logger.error("Failed to read decade_filter_items: \(error)")
            return []
        }
    }

    func getYearFilterItems() -> [LibraryFilterItem] {
        do {
            return try rows(core.yearFilterItems(hideDuplicates: hideDuplicateTracks)).map { row in rowToFilterItem(row, filterType: .years) }
        } catch {
            Logger.error("Failed to read year_filter_items: \(error)")
            return []
        }
    }
}
