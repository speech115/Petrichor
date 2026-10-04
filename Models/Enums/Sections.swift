import Foundation

/// What the main window's center shows; the sidebar rows and search pick it.
enum Sections: String, CaseIterable, Identifiable {
    case home
    case discover
    case library
    case playlists
    case folders
    /// Results for the toolbar search field; it has no sidebar row.
    case search

    var id: String { rawValue }

    var label: String {
        switch self {
        case .home: return String(localized: "Home")
        case .discover: return String(localized: "Discover")
        case .library: return String(localized: "Library")
        case .playlists: return String(localized: "Playlists")
        case .folders: return String(localized: "Folders")
        case .search: return String(localized: "Search")
        }
    }

    var icon: String {
        switch self {
        case .home: return Icons.musicNoteHouse
        case .discover: return Icons.sparkles
        case .library: return Icons.customMusicNoteRectangleStack
        case .playlists: return Icons.musicNoteList
        case .folders: return Icons.folder
        case .search: return Icons.magnifyingGlass
        }
    }
}
