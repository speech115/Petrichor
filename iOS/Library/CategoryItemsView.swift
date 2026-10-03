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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let filterType: LibraryFilterType
    let zoomNamespace: Namespace.ID

    @State private var items: [LibraryFilterItem] = []
    @State private var sections: [IndexedSection<LibraryFilterItem>] = []
    @State private var hasLoaded = false

    var body: some View {
        Group {
            if filterType == .albums {
                albumsGrid
            } else {
                IndexedList(
                    sections: sections,
                    bottomClearance: IndexedListSectionFactory.floatingTabBarClearance(for: dynamicTypeSize)
                ) { item in
                    NavigationLink(value: destination(for: item)) {
                        row(for: item)
                    }
                }
            }
        }
        .navigationTitle(filterType.pluralDisplayName)
        .toolbarTitleDisplayMode(.inline)
        .task(id: ReloadKey(revision: libraryManager.libraryRevision, entitiesLoaded: libraryManager.entitiesLoaded)) {
            await reload()
        }
        .overlay {
            if hasLoaded, items.isEmpty, libraryManager.shouldShowMainUI {
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
                    let album = albumEntity(for: item) ?? AlbumEntity(name: item.name, trackCount: item.count)
                    NavigationLink(value: destination(for: item)) {
                        AlbumGridCard(
                            item: item,
                            artworkLoader: albumArtworkLoader(for: item.albumId)
                        )
                        .detailZoomSource(.album(album.id), in: zoomNamespace, cornerRadius: 10)
                    }
                    .buttonStyle(.plain)
                    .albumContextMenu(album)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private nonisolated static func sections(
        _ items: [LibraryFilterItem],
        filterType: LibraryFilterType
    ) -> [IndexedSection<LibraryFilterItem>] {
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
    /// plain track list. Resolved by the shared `LibraryNavigation`.
    private func destination(for item: LibraryFilterItem) -> LibraryDestination {
        LibraryNavigation.destination(for: filterType, item: item, libraryManager: libraryManager)
    }

    private func albumEntity(for item: LibraryFilterItem) -> AlbumEntity? {
        LibraryNavigation.albumEntity(for: item, libraryManager: libraryManager)
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(for item: LibraryFilterItem) -> some View {
        switch filterType {
        case .artists:
            HStack(spacing: 12) {
                ArtworkTile(
                    data: nil,
                    cacheKey: ArtworkCacheKey.artist(item.name),
                    cornerRadius: 22,
                    loader: artistArtworkLoader(for: item.name)
                )
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

    private struct ReloadKey: Equatable {
        let revision: Int
        let entitiesLoaded: Bool
    }

    /// The query (a GROUP BY over the whole library on a cold cache), the
    /// sort and the sectioning all run off the main actor.
    private func reload() async {
        let filterType = filterType
        let fetched = await libraryManager.libraryFilterItems(for: filterType)
        let (sorted, built) = await Task.detached(priority: .userInitiated) {
            let sorted = Self.sort(fetched, filterType: filterType)
            return (sorted, Self.sections(sorted, filterType: filterType))
        }.value
        guard !Task.isCancelled else { return }
        items = sorted
        sections = built
        hasLoaded = true
    }

    private func artistArtworkLoader(for name: String) -> ArtworkDataLoader {
        let database = libraryManager.databaseManager
        return ArtworkDataLoader { database.getArtistArtworkThumbnail(name: name) }
    }

    private func albumArtworkLoader(for albumId: Int64?) -> ArtworkDataLoader? {
        guard let albumId else { return nil }
        let database = libraryManager.databaseManager
        return ArtworkDataLoader { database.getAlbumArtworkThumbnail(albumId: albumId) }
    }

    private nonisolated static func sort(
        _ items: [LibraryFilterItem],
        filterType: LibraryFilterType
    ) -> [LibraryFilterItem] {
        if filterType == .years {
            return items.sorted { yearValue($0.name) > yearValue($1.name) }
        }
        return items.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private nonisolated static func yearValue(_ year: String) -> Int {
        Int(year.prefix(4)) ?? Int.min
    }
}

// MARK: - Album Grid Card

private struct AlbumGridCard: View {
    let item: LibraryFilterItem
    let artworkLoader: ArtworkDataLoader?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkTile(
                data: nil,
                cacheKey: item.albumId.map(ArtworkCacheKey.album),
                cornerRadius: 10,
                iconSize: 28,
                maxPixelSize: 600,
                loader: artworkLoader,
                // The card's name and count sit right below the cover.
            )
                .aspectRatio(1, contentMode: .fit)

            Text(item.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)

            Text(TrackCountText.songs(item.count))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}
