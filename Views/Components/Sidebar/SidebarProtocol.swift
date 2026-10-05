import SwiftUI

// MARK: - Sidebar Item Protocol

protocol SidebarItem: Identifiable, Equatable {
    var id: UUID { get }
    var title: String { get }
    var subtitle: String? { get }
    var icon: String? { get }
    /// Square artwork shown instead of `icon` when present (playlist covers).
    var artwork: SidebarItemArtwork? { get }
}

extension SidebarItem {
    var artwork: SidebarItemArtwork? { nil }
}

/// Leading artwork for a sidebar row. Prefer this over `icon` when set.
enum SidebarItemArtwork: Equatable {
    case data(Data)
    case playlistCover(PlaylistCover)
}

// MARK: - Library Sidebar Item

struct LibrarySidebarItem: SidebarItem {
    let id: UUID
    let title: String
    let subtitle: String?
    let icon: String?
    let filterType: LibraryFilterType
    let filterName: String
    let albumId: Int64?

    init(filterItem: LibraryFilterItem) {
        self.id = filterItem.id
        self.title = filterItem.name
        self.subtitle = String(localized: "\(filterItem.count) songs")
        self.icon = Self.getIcon(for: filterItem.filterType, isAllItem: false)
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
        self.filterType = filterType
        self.filterName = ""
        self.albumId = nil
    }

    private static func getIcon(for filterType: LibraryFilterType, isAllItem: Bool) -> String {
        isAllItem ? filterType.allItemIcon : filterType.icon
    }
}

// MARK: - Playlist Sidebar Item

struct PlaylistSidebarItem: SidebarItem {
    let id: UUID
    let title: String
    let subtitle: String?
    let icon: String?
    let artwork: SidebarItemArtwork?
    let playlist: Playlist

    init(playlist: Playlist, artworkOverride: SidebarItemArtwork? = nil) {
        self.id = playlist.id
        self.title = PlaylistDisplay.name(for: playlist)
        self.icon = Icons.defaultPlaylistIcon(for: playlist)
        self.artwork = artworkOverride ?? PlaylistSidebarArtwork.resolve(for: playlist)
        self.playlist = playlist

        if playlist.type == .smart, let limit = playlist.trackLimit {
            self.subtitle = String(localized: "\(playlist.trackCount) / \(limit) songs")
        } else {
            self.subtitle = String(localized: "\(playlist.trackCount) songs")
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
