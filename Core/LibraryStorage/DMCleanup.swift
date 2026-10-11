import Foundation
import PetrichorCore

extension DatabaseManager {
    func cleanupOrphanedData() async throws {
        try await Task.detached { try self.core.cleanupOrphanedData() }.value
        Logger.info("Database orphan cleanup completed")
    }
}
