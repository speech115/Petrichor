//
// CategoryItemsView (iOS)
//
// One category's items (artists, albums, genres, release years). Artists get
// a list with circular thumbnails, albums a 2-column card grid with covers,
// genres and years the plain alphabet-indexed list. Artists and albums push
// to their detail pages, genres and years to the item's track list.
//

import SwiftUI

struct CategoryItemsView: View {
    @EnvironmentObject private var libraryManager: LibraryManager

    let filterType: LibraryFilterType

    @State private var items: [LibraryFilterItem] = []
    @State private var artistThumbnails: [String: Data] = [:]
    @State private var albumThumbnails: [Int64: Data] = [:]
    @State private var albumEntitiesByID: [Int64: AlbumEntity] = [:]

    var body: some View {
        Group {
            if filterType == .albums {
                albumsGrid
            } else {
                IndexedList(sections: sections) { item in
                    NavigationLink(value: destination(for: item)) {
                        row(for: item)
                    }
                }
            }
        }
        .navigationTitle(filterType.pluralDisplayName)
        .navigationBarTitleDisplayMode(.large)
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

    // MARK: - Albums Grid

    private var albumsGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 16),
                    GridItem(.flexible(), spacing: 16)
                ],
                spacing: 16
            ) {
                ForEach(items) { item in
                    NavigationLink(value: destination(for: item)) {
                        AlbumGridCard(
                            item: item,
                            cover: item.albumId.flatMap { albumThumbnails[$0] }
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
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
        if let albumId = item.albumId {
            return albumEntitiesByID[albumId]
        }
        return libraryManager.albumEntities.first { $0.name == item.name }
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(for item: LibraryFilterItem) -> some View {
        switch filterType {
        case .artists:
            HStack(spacing: 12) {
                ArtworkTile(data: artistThumbnails[item.name], cornerRadius: 22)
                    .frame(width: 44, height: 44)
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
            albumEntitiesByID = Dictionary(
                libraryManager.albumEntities.compactMap { album in
                    album.albumId.map { ($0, album) }
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

// MARK: - Album Grid Card

private struct AlbumGridCard: View {
    let item: LibraryFilterItem
    let cover: Data?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkTile(data: cover, cornerRadius: 10, iconSize: 28)
                .aspectRatio(1, contentMode: .fit)

            Text(item.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)

            Text(String(localized: "\(item.count) songs"))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}
