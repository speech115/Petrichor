import Foundation

class FolderNode: Identifiable, ObservableObject {
    let id = UUID()
    let url: URL
    let name: String
    let isWatchFolder: Bool // True if this is the root watch folder

    @Published var children: [FolderNode] = []
    @Published var isExpanded: Bool = false
    @Published var isLoading: Bool = false

    // Counts for immediate contents only
    var immediateTrackCount: Int = 0
    var displayTrackCount: Int = 0
    var immediateFolderCount: Int {
        children.count
    }

    /// `FolderHierarchyBuilder` walks the filesystem off the main actor (a deep
    /// tree is slow to enumerate) and only needs to touch this node's
    /// `@Published` surface once, with the finished subtree. `@MainActor` here
    /// - rather than wrapping the caller's `MainActor.run` around a capture of
    /// `self` and `children` - keeps the crossing to exactly this one checked
    /// call instead of requiring `FolderNode` to be `Sendable` end to end.
    @MainActor
    func apply(children: [FolderNode], immediateTrackCount: Int, displayTrackCount: Int) {
        self.children = children.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        self.immediateTrackCount = immediateTrackCount
        self.displayTrackCount = displayTrackCount
    }

    // Cached database folder reference if this corresponds to a watched folder
    var databaseFolder: Folder?

    init(url: URL, name: String? = nil, isWatchFolder: Bool = false) {
        self.url = url
        self.name = name ?? url.lastPathComponent
        self.isWatchFolder = isWatchFolder
    }

    // Helper to get all tracks in this folder (immediate only). Only called
    // from `FoldersView` (macOS, main actor); `libraryManager` is
    // `@MainActor`-isolated, so this needs to be too.
    @MainActor
    func getImmediateTracks(using libraryManager: LibraryManager) -> [Track] {
        let allTracks: [Track]
        
        if let dbFolder = databaseFolder {
            allTracks = libraryManager.getTracksInFolder(dbFolder)
        } else {
            guard let parentFolder = libraryManager.folders.first(where: {
                self.url.path.starts(with: $0.url.path)
            }) else {
                return []
            }
            allTracks = libraryManager.getTracksInFolder(parentFolder)
        }
        
        return allTracks.filter { track in
            track.url.deletingLastPathComponent().path == self.url.path
        }
    }
}

// Make it Equatable for selection tracking
extension FolderNode: Equatable {
    static func == (lhs: FolderNode, rhs: FolderNode) -> Bool {
        lhs.id == rhs.id
    }
}

// Make it Hashable for use in Sets
extension FolderNode: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
