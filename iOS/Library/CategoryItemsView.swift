//
// CategoryItemsView (iOS)
//
// An alphabet-indexed list of one category's items (artists, albums, genres,
// release years). Artists and albums push to their detail pages, genres and
// years to the item's track list.
//

import SwiftUI

struct CategoryItemsView: View {
    @EnvironmentObject private var libraryManager: LibraryManager

    let filterType: LibraryFilterType

    @State private var items: [LibraryFilterItem] = []

    var body: some View {
        IndexedList(sections: sections) { item in
            NavigationLink(value: destination(for: item)) {
                HStack {
                    Text(item.name)
                    Spacer()
                    Text("\(item.count)")
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle(filterType.pluralDisplayName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .onChange(of: libraryManager.tracks.count) { _, _ in
            reload()
        }
        .overlay {
            if items.isEmpty, libraryManager.shouldShowMainUI {
                ContentUnavailableView(
                    filterType.emptyStateMessage,
                    systemImage: Icons.musicNote
                )
            }
        }
    }

    private var sections: [IndexedSection<LibraryFilterItem>] {
        let sections = IndexedListSectionFactory.sections(
            from: items,
            key: { IndexedListSectionFactory.sectionKey(for: $0.name) }
        )
        if filterType == .years {
            return sections.sorted { $0.key > $1.key }
        }
        return sections
    }

    /// Artists and albums get their detail pages; genres and years keep the
    /// plain track list.
    private func destination(for item: LibraryFilterItem) -> LibraryDestination {
        switch filterType {
        case .artists:
            return .artist(name: item.name)
        case .albums:
            return .album(albumEntity(for: item) ?? AlbumEntity(name: item.name, trackCount: item.count))
        default:
            return .tracks(item)
        }
    }

    private func albumEntity(for item: LibraryFilterItem) -> AlbumEntity? {
        libraryManager.albumEntities.first { entity in
            if let itemAlbumId = item.albumId, let entityAlbumId = entity.albumId {
                return itemAlbumId == entityAlbumId
            }
            return entity.name == item.name
        }
    }

    private func reload() {
        let sorted = libraryManager.getLibraryFilterItems(for: filterType)
        items = sort(sorted)
    }

    private func sort(_ items: [LibraryFilterItem]) -> [LibraryFilterItem] {
        if filterType == .years {
            return items.sorted { yearValue($0.name) > yearValue($1.name) }
        }
        return items.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func yearValue(_ year: String) -> Int {
        Int(year.prefix(4)) ?? Int.min
    }
}
