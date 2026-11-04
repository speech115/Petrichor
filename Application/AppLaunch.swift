//
// AppLaunch
//
// Opens the library database and builds the app's object graph on top of it.
// Opening can fail (a damaged file, a migration that throws, a full disk);
// the app then shows the reason with a way to retry instead of crashing, and
// the iPhone also offers to reset the library database. The managers are
// built only once the database is open, so none of them runs without one.
//

import Foundation

@MainActor
final class AppLaunch<Running>: ObservableObject {
    /// What `build` made of the open database, or nil while it cannot be opened.
    @Published private(set) var running: Running?
    /// Why the database did not open; nil once it has.
    @Published private(set) var databaseError: String?

    private let openDatabase: () throws -> DatabaseManager
    private let removeDatabase: () throws -> Void
    private let build: (DatabaseManager) -> Running
    private let didReset: (Running) -> Void
    /// The files were deleted but no database has opened since: the first
    /// open that succeeds, possibly a later Try Again, reports the reset.
    private var resetPending = false

    /// - Parameters:
    ///   - openDatabase, removeDatabase: The app's own database file; tests
    ///     pass one in a temporary folder.
    ///   - build: Makes the running app from the open database, on launch or
    ///     after a successful retry.
    ///   - didReset: Runs once the database a reset created is open, also when
    ///     that happens only on a later Try Again. Its row
    ///     ids restart from 1, so state keyed by the old ids (the iOS
    ///     Spotlight snapshot) is cleared here.
    init(
        openDatabase: @escaping () throws -> DatabaseManager = { try DatabaseManager() },
        removeDatabase: @escaping () throws -> Void = { try DatabaseFactory.removeDatabaseFiles() },
        build: @escaping (DatabaseManager) -> Running,
        didReset: @escaping (Running) -> Void = { _ in }
    ) {
        self.openDatabase = openDatabase
        self.removeDatabase = removeDatabase
        self.build = build
        self.didReset = didReset
        openLibrary()
    }

    /// Opens the database and, on success, builds the app. Does nothing once
    /// the app is running.
    func openLibrary() {
        guard running == nil else { return }
        do {
            let running = build(try openDatabase())
            self.running = running
            databaseError = nil
            if resetPending {
                resetPending = false
                didReset(running)
            }
        } catch {
            Logger.critical("Failed to open the library database: \(error)")
            databaseError = error.localizedDescription
        }
    }

    /// Deletes the database file and opens a new, empty one. Music files stay
    /// where they are; the next scan builds the library from them again, while
    /// playlists, favorites and play counts stored only in the database are lost.
    func resetLibraryDatabase() {
        guard running == nil else { return }
        do {
            try removeDatabase()
        } catch {
            Logger.critical("Failed to delete the library database: \(error)")
            databaseError = error.localizedDescription
            return
        }
        resetPending = true
        openLibrary()
    }
}

// MARK: - Previews and Tests

// SwiftUI previews and the hosted unit tests build the managers on the app's
// own database without the launch screen in between; a database that cannot
// open stops them here. Not under `#if DEBUG`: `#Preview` bodies compile in
// Release too. The app itself never calls these; it goes through `AppLaunch`.

extension LibraryManager {
    convenience init() {
        self.init(databaseManager: DatabaseManager.openForPreviews(), deferLaunchWork: false)
    }
}

extension AppCoordinator {
    convenience init() {
        self.init(databaseManager: DatabaseManager.openForPreviews())
    }
}

private extension DatabaseManager {
    static func openForPreviews() -> DatabaseManager {
        do {
            return try DatabaseManager()
        } catch {
            preconditionFailure("Library database unavailable: \(error)")
        }
    }
}
