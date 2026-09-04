import Foundation

extension LibraryManager {
    func scanLibraryInBackground() {
        Task(priority: .utility) {
            do { try await scanLibraryRoot() }
            catch { Logger.error("Failed to scan the iOS library: \(error)") }
        }
    }

    func scanLibraryRoot() async throws {
        let folders = try await databaseManager.addFoldersAsync(
            [LibraryPathStore.libraryRoot], bookmarkDataMap: [:]
        )
        guard !folders.isEmpty else { return }
        await MainActor.run { scheduleLibraryReload() }
    }
}
