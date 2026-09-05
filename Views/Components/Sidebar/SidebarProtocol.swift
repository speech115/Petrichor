import SwiftUI

// MARK: - Sidebar Item Protocol

protocol SidebarItem: Identifiable, Equatable {
    var id: UUID { get }
    var title: String { get }
    var subtitle: String? { get }
    var icon: String? { get }
    /// Square artwork shown instead of `icon` when present (playlist covers).
    var artwork: SidebarItemArtwork? { get }
    var count: Int? { get }
}

extension SidebarItem {
    var artwork: SidebarItemArtwork? { nil }
}

/// Leading artwork for a sidebar row. Prefer this over `icon` when set.
enum SidebarItemArtwork: Equatable {
    case data(Data)
    case playlistCover(PlaylistCover)
}

// MARK: - Home Sidebar Item

struct HomeSidebarItem: SidebarItem {
    let id: UUID
    let title: String
    let subtitle: String?
    let icon: String?
    let artwork: SidebarItemArtwork?
    var count: Int?
    let type: HomeItemType?
    
    // Item source
    enum ItemSource {
        case fixed(HomeItemType)
        case pinned(PinnedItem)
    }
    let source: ItemSource

    /// The always-present rows; everything below is a pin, including Artists and Albums.
    enum HomeItemType: CaseIterable {
        case discover
        case tracks
        case internetRadio

        var stableID: UUID {
            switch self {
            case .discover:
                return makeStableID("00000000-0000-0000-0000-000000000000")
            case .tracks:
                return makeStableID("00000000-0000-0000-0000-000000000001")
            case .internetRadio:
                return makeStableID("00000000-0000-0000-0000-000000000004")
            }
        }

        private func makeStableID(_ string: String) -> UUID {
            guard let uuid = UUID(uuidString: string) else {
                preconditionFailure("Invalid home sidebar UUID")
            }
            return uuid
        }

        var title: String {
            switch self {
            case .discover: return String(localized: "Discover")
            case .tracks: return String(localized: "Tracks")
            case .internetRadio: return String(localized: "Internet Radio")
            }
        }

        var icon: String {
            switch self {
            case .discover: return Icons.sparkles
            case .tracks: return Icons.musicNote
            case .internetRadio: return Icons.radioFill
            }
        }
    }

    // Init for fixed items
    init(
        type: HomeItemType,
        trackCount: Int? = nil,
        stationCount: Int? = nil
    ) {
        self.id = type.stableID
        self.type = type
        self.source = .fixed(type)
        self.title = type.title
        self.icon = type.icon
        self.artwork = nil

        // Set subtitle based on type
        switch type {
        // No subtitle: a track count would describe only the Fresh Music section, and any
        // other wording reads as noise beside three plain counts. `SidebarItemRow` still
        // reserves the line so this row matches its siblings' height.
        case .discover:
            self.subtitle = nil
        case .tracks:
            self.subtitle = String(localized: "\(trackCount ?? 0) songs")
        case .internetRadio:
            self.subtitle = String(localized: "\(stationCount ?? 0) stations")
        }
    }

    // Init for pinned items
    init(
        pinnedItem: PinnedItem,
        trackCount: Int = 0,
        playlist: Playlist? = nil,
        artworkOverride: SidebarItemArtwork? = nil
    ) {
        self.id = UUID(uuidString: "pinned-\(pinnedItem.id ?? 0)") ?? UUID()
        self.type = nil
        self.source = .pinned(pinnedItem)

        if pinnedItem.itemType == .category, let filterType = pinnedItem.filterType {
            // `displayName` is stored English; the plural form keeps the sidebar localized.
            self.title = filterType.pluralDisplayName
            self.subtitle = filterType.itemCountLabel(count)
        } else {
            self.title = playlist.map(DefaultPlaylists.displayName) ?? pinnedItem.displayName
            self.subtitle = playlist?.type == .stations
                ? String(localized: "\(count) stations")
                : String(localized: "\(count) songs")
        }

        self.icon = HomeSidebarItem.deriveIcon(for: pinnedItem, playlist: playlist)
        if let artworkOverride {
            self.artwork = artworkOverride
        } else {
            self.artwork = pinnedItem.itemType == .playlist
                ? playlist.flatMap(PlaylistSidebarArtwork.resolve(for:))
                : nil
        }
    }

    private static func deriveIcon(for pinnedItem: PinnedItem, playlist: Playlist?) -> String {
        switch pinnedItem.itemType {
        case .playlist:
            return playlist.map { Icons.defaultPlaylistIcon(for: $0) } ?? Icons.musicNoteList
        // `icon`, not `allItemIcon`: category rows mirror the Library type column.
        case .library, .category:
            return pinnedItem.filterType?.icon ?? Icons.musicNote
        case .folder:
            return Icons.folderFill
        }
    }
}

// MARK: - Equatable Conformance
extension HomeSidebarItem: Equatable {
    static func == (lhs: HomeSidebarItem, rhs: HomeSidebarItem) -> Bool {
        // Compare by ID first (most common case)
        if lhs.id != rhs.id {
            return false
        }

        // SwiftUI skips re-rendering a sidebar whose items all compare equal, so anything
        // the row displays has to be compared too, or its subtitle goes stale.
        if lhs.title != rhs.title || lhs.subtitle != rhs.subtitle || lhs.count != rhs.count {
            return false
        }

        // Then compare by source
        switch (lhs.source, rhs.source) {
        case let (.fixed(lhsType), .fixed(rhsType)):
            return lhsType == rhsType
        case let (.pinned(lhsItem), .pinned(rhsItem)):
            return lhsItem.id == rhsItem.id
        default:
            return false
        }
    }
}

// MARK: - Library Sidebar Item

struct LibrarySidebarItem: SidebarItem {
    let id: UUID
    let title: String
    let subtitle: String?
    let icon: String?
    let count: Int?
    let filterType: LibraryFilterType
    let filterName: String
    let albumId: Int64?

    init(filterItem: LibraryFilterItem) {
        self.id = filterItem.id
        self.title = filterItem.name
        self.subtitle = String(localized: "\(filterItem.count) songs")
        self.icon = Self.getIcon(for: filterItem.filterType, isAllItem: false)
        self.count = nil
        self.filterType = filterItem.filterType
        self.filterName = filterItem.name
        self.albumId = filterItem.albumId
    }

    // Special "All" item
    init(allItemFor filterType: LibraryFilterType, count: Int) {
        self.id = UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", filterType.stableIndex))") ?? UUID()
        self.title = filterType.allItemsTitle
        self.subtitle = String(localized: "\(count) songs")
        self.icon = Self.getIcon(for: filterType, isAllItem: true)
        self.count = nil
        self.filterType = filterType
        self.filterName = ""
        self.albumId = nil
    }

    private static func getIcon(for filterType: LibraryFilterType, isAllItem: Bool) -> String {
        isAllItem ? filterType.allItemIcon : filterType.icon
    }
}

// MARK: - Library Type Sidebar Item

/// A row in the Library tab's entity-type column (Artists, Albums, Genres, ...).
struct LibraryTypeSidebarItem: SidebarItem {
    let id: UUID
    let title: String
    let subtitle: String?
    let icon: String?
    let count: Int?
    let filterType: LibraryFilterType

    init(filterType: LibraryFilterType) {
        // Distinct group from `LibrarySidebarItem`'s "All" rows so the two can never collide.
        self.id = UUID(uuidString: "00000000-0000-0000-0003-\(String(format: "%012d", filterType.stableIndex))") ?? UUID()
        self.title = filterType.pluralDisplayName
        self.subtitle = nil
        self.icon = filterType.icon
        self.count = nil
        self.filterType = filterType
    }
}

// MARK: - Playlist Sidebar Item

struct PlaylistSidebarItem: SidebarItem {
    let id: UUID
    let title: String
    let subtitle: String?
    let icon: String?
    let artwork: SidebarItemArtwork?
    let count: Int?
    let playlist: Playlist

    init(playlist: Playlist, artworkOverride: SidebarItemArtwork? = nil) {
        self.id = playlist.id
        self.title = DefaultPlaylists.displayName(for: playlist)
        self.icon = Icons.defaultPlaylistIcon(for: playlist)
        self.artwork = artworkOverride ?? PlaylistSidebarArtwork.resolve(for: playlist)
        self.playlist = playlist

        // Set subtitle and count based on playlist type
        if playlist.type == .stations {
            self.subtitle = String(localized: "\(playlist.trackCount) stations")
            self.count = nil
        } else if playlist.type == .smart {
            let trackCount = playlist.trackCount
            if let limit = playlist.trackLimit {
                self.subtitle = String(localized: "\(trackCount) / \(limit) songs")
            } else {
                self.subtitle = String(localized: "\(trackCount) songs")
            }
            self.count = nil
        } else {
            self.subtitle = String(localized: "\(playlist.trackCount) songs")
            self.count = nil
        }
    }
}

/// Shared cover/collage resolution for playlist rows in the Home and Playlists sidebars.
enum PlaylistSidebarArtwork {
    static func resolve(for playlist: Playlist) -> SidebarItemArtwork? {
        if let data = playlist.artworkData {
            return .data(data)
        }
        if let cover = PlaylistCover.of(playlist) {
            return .playlistCover(cover)
        }
        return nil
    }

    /// When there is no pinned cover or cached collage, build a 4-tile collage
    /// from preview tracks (same idea as iOS `PlaylistsTabView`).
    static func resolveOrWarmCollage(
        for playlist: Playlist,
        database: DatabaseManager
    ) async -> SidebarItemArtwork? {
        if let resolved = resolve(for: playlist) {
            return resolved
        }

        var playlist = playlist
        var previews = database.getPlaylistPreviewTracks(playlist, limit: 4)
        for index in previews.indices where previews[index].albumArtworkData == nil {
            previews[index].albumArtworkData = database.getArtworkData(
                albumId: previews[index].albumId,
                trackId: previews[index].trackId
            )
        }
        guard previews.contains(where: { $0.albumArtworkData != nil }) else { return nil }
        playlist.tracks = previews
        guard let data = await playlist.warmArtworkCacheIfNeeded() else { return nil }
        return .data(data)
    }
}

// MARK: - Folder Node Sidebar Item

struct FolderNodeSidebarItem: SidebarItem {
    let id: UUID
    let title: String
    let subtitle: String?
    let icon: String?
    let count: Int?
    let folderNode: FolderNode

    init(folderNode: FolderNode) {
        self.id = folderNode.id
        self.title = folderNode.name
        self.folderNode = folderNode

        if folderNode.children.isEmpty {
            self.icon = Icons.folderFill
        } else {
            self.icon = folderNode.isExpanded ? Icons.folderFillBadgeMinus : Icons.folderFillBadgePlus
        }

        let trackCount = folderNode.displayTrackCount
        if folderNode.immediateFolderCount > 0 && trackCount > 0 {
            self.subtitle = String(localized: "\(folderNode.immediateFolderCount) folders, \(trackCount) tracks")
        } else if folderNode.immediateFolderCount > 0 {
            self.subtitle = String(localized: "\(folderNode.immediateFolderCount) folders")
        } else if trackCount > 0 {
            self.subtitle = String(localized: "\(trackCount) tracks")
        } else {
            self.subtitle = nil
        }

        self.count = nil
    }
}
