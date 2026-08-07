//
// CategoryItemsView (iOS)
//
// An alphabet-indexed list of one category's items (artists, albums, genres,
// release years). Artists and albums push to their detail pages, genres and
// years to the item's track list.
//

import SwiftUI
import UIKit

struct CategoryItemsView: View {
    @EnvironmentObject private var libraryManager: LibraryManager

    let filterType: LibraryFilterType

    @State private var items: [LibraryFilterItem] = []
    @State private var artistThumbnails: [String: Data] = [:]
    @State private var albumThumbnails: [Int64: Data] = [:]

    var body: some View {
        IndexedList(sections: sections) { item in
            NavigationLink(value: destination(for: item)) {
                row(for: item)
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

    // MARK: - Rows

    @ViewBuilder
    private func row(for item: LibraryFilterItem) -> some View {
        switch filterType {
        case .artists:
            HStack(spacing: 12) {
                thumbnailView(data: artistThumbnails[item.name], cornerRadius: 22)
                textRow(item)
            }
        case .albums:
            HStack(spacing: 12) {
                thumbnailView(data: item.albumId.flatMap { albumThumbnails[$0] }, cornerRadius: 6)
                textRow(item)
            }
        default:
            textRow(item)
        }
    }

    private func textRow(_ item: LibraryFilterItem) -> some View {
        HStack {
            Text(item.name)
            Spacer()
            Text("\(item.count)")
                .foregroundColor(.secondary)
        }
    }

    private func thumbnailView(data: Data?, cornerRadius: CGFloat) -> some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(Color.secondary.opacity(0.12))
                    Image(systemName: Icons.musicNote)
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                }
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    private func reload() {
        let sorted = sort(libraryManager.getLibraryFilterItems(for: filterType))
        items = sorted

        // One lookup per row would be quadratic on large libraries; index the
        // entity caches once per reload instead.
        if filterType == .artists {
            artistThumbnails = Dictionary(
                libraryManager.artistEntities.compactMap { artist in
                    artist.artworkThumbnail.map { (artist.name, $0) }
                },
                uniquingKeysWith: { first, _ in first }
            )
        } else if filterType == .albums {
            albumThumbnails = Dictionary(
                libraryManager.albumEntities.compactMap { album in
                    album.albumId.flatMap { id in album.artworkThumbnail.map { (id, $0) } }
                },
                uniquingKeysWith: { first, _ in first }
            )
        }
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
