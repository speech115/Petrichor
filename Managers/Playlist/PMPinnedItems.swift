//
// PlaylistManager class extension
//
// Keeps the stored pinned items consistent when a playlist is deleted.
//

import Foundation
import SwiftUI

extension PlaylistManager {
    /// Handle playlist deletion - remove from pinned items if needed
    func handlePlaylistDeletionForPinnedItems(_ playlistId: UUID) async {
        guard let manager = libraryManager else { return }
        
        // Check if this playlist is pinned
        guard manager.pinnedItems.contains(where: { $0.playlistId == playlistId }) else {
            return
        }
        
        do {
            try await manager.databaseManager.removePinnedItemMatching(
                filterType: nil,
                filterValue: nil,
                playlistId: playlistId
            )
            await manager.loadPinnedItems()
        } catch {
            Logger.error("Failed to remove deleted playlist from pinned items: \(error)")
        }
    }
}
