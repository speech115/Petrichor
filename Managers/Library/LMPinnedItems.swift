//
// LibraryManager class extension
//
// Loads the pinned items the database still keeps. Pinning itself has no UI any
// more: the macOS sidebar follows the iPhone, which has no pins.
//

import Foundation
import SwiftUI

extension LibraryManager {
    // MARK: - Pinned Items Management
    
    /// Load pinned items from database
    func loadPinnedItems() async {
        do {
            let items = try await databaseManager.getPinnedItems()
            await MainActor.run {
                self.pinnedItems = items
            }
        } catch {
            Logger.error("Failed to load pinned items: \(error)")
        }
    }
}
