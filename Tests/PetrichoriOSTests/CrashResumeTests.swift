import Foundation
import GRDB
import Testing
@testable import Petrichor

// A kill or crash never runs the backgrounding or termination save. These
// tests stop at the point the process would die: whatever the next launch
// reads must already be in UserDefaults. Nested under `PlaybackTests` so they
// run serially with the other suites that touch the audio session and the
// saved-state keys.

/// Silent tracks under the library root, inserted as database rows and
/// removed again by `cleanUp()`. The saved-state keys are put back as well.
@MainActor
private struct CrashFixture {
    let database: DatabaseManager
    let folderURL: URL
    let folderID: Int64
    let tracks: [Track]
    let savedDefaults: [Data?]

    static let savedKeys = ["SavedPlaybackState", "SavedPlaybackUIState", "SavedPlaybackPosition"]

    init(count: Int, seconds: Double = 8) async throws {
        savedDefaults = Self.savedKeys.map { UserDefaults.standard.data(forKey: $0) }
        let database = try DatabaseManager()
        let folderURL = LibraryPathStore.libraryRoot.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let urls = try (0..<count).map { index in
            let url = folderURL.appendingPathComponent("Crash \(index).wav")
            try FileManager.default.moveItem(at: try makeSilentWAV(seconds: seconds), to: url)
            return url
        }
        let (folderID, tracks) = try await database.dbQueue.write { db -> (Int64, [Track]) in
            try Folder(url: folderURL).insert(db)
            let folderID = db.lastInsertedRowID
            var tracks: [Track] = []
            for (index, url) in urls.enumerated() {
                var full = FullTrack(url: url)
                full.folderId = folderID
                full.title = "Crash \(index)"
                full.duration = seconds
                try full.insert(db)
                tracks.append(try #require(try Track.filter(Track.Columns.trackId == db.lastInsertedRowID).fetchOne(db)))
            }
            return (folderID, tracks)
        }
        self.database = database
        self.folderURL = folderURL
        self.folderID = folderID
        self.tracks = tracks
    }

    func cleanUp() {
        for (key, value) in zip(Self.savedKeys, savedDefaults) {
            UserDefaults.standard.set(value, forKey: key)
        }
        try? database.dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "DELETE FROM tracks WHERE folder_id = ?", arguments: [folderID])
            try db.execute(sql: "DELETE FROM folders WHERE id = ?", arguments: [folderID])
        }
        try? FileManager.default.removeItem(at: folderURL)
    }

    /// Writes a saved session the way a backgrounding would.
    func saveSession(current: Track, queue: [Track], index: Int, position: Double) throws {
        let state = PlaybackState(
            currentTrack: current, playbackPosition: position, queue: queue, currentQueueIndex: index,
            queueSource: .library, volume: 0, isMuted: true, shuffleEnabled: false, repeatMode: .off
        )
        let defaults = UserDefaults.standard
        defaults.set(try JSONEncoder().encode(state), forKey: Self.savedKeys[0])
        defaults.set(try JSONEncoder().encode(state.createUIState(from: current)), forKey: Self.savedKeys[1])
        defaults.removeObject(forKey: Self.savedKeys[2])
    }

    static func savedState() throws -> PlaybackState {
        try JSONDecoder().decode(
            PlaybackState.self,
            from: try #require(UserDefaults.standard.data(forKey: savedKeys[0]))
        )
    }

    static func savedMark() throws -> AppCoordinator.PlaybackPositionMark {
        try JSONDecoder().decode(
            AppCoordinator.PlaybackPositionMark.self,
            from: try #require(UserDefaults.standard.data(forKey: savedKeys[2]))
        )
    }
}

@MainActor
private func waitUntil(_ timeout: Duration = .seconds(8), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(50))
    }
}

/// A coordinator launched against whatever the previous one left behind,
/// waited until its restoration applied.
@MainActor
private func relaunch(expectingQueueCount count: Int) async throws -> AppCoordinator {
    let coordinator = AppCoordinator()
    coordinator.restorePlaybackState()
    try await waitUntil {
        coordinator.playlistManager.currentQueue.count == count
            && coordinator.playbackManager.currentFullTrack != nil
    }
    return coordinator
}

extension PlaybackTests {
@MainActor
struct CrashResumeTests {
    /// A queue the user started in the foreground survives a kill: the next
    /// launch restores that queue, its current track and the repeat mode,
    /// not the session saved at the last backgrounding.
    @Test func aKillAfterStartingANewQueueResumesThatQueue() async throws {
        let fixture = try await CrashFixture(count: 4)
        defer { fixture.cleanUp() }
        let old = [fixture.tracks[0], fixture.tracks[1]]
        try fixture.saveSession(current: old[0], queue: old, index: 0, position: 1)

        let first = AppCoordinator()
        defer { first.playbackManager.stop() }
        first.playbackManager.volume = 0
        first.restorePlaybackState()
        try await waitUntil { first.playbackManager.currentFullTrack != nil }

        let fresh = [fixture.tracks[2], fixture.tracks[3]]
        first.playlistManager.playTrack(fresh[1], fromTracks: fresh)
        first.playlistManager.toggleRepeatMode()
        #expect(first.playlistManager.repeatMode == .all)

        // The process dies here, in the foreground: no scenePhase save runs.
        try await waitUntil(.seconds(6)) {
            (try? CrashFixture.savedState().queueTrackIds) == fresh.compactMap(\.trackId)
        }
        let saved = try CrashFixture.savedState()
        #expect(saved.queueTrackIds == fresh.compactMap(\.trackId), "the kill rolled the queue back")
        #expect(saved.currentTrackId == fresh[1].trackId)
        #expect(saved.repeatModeEnum == .all)
        first.playbackManager.stop()

        let second = try await relaunch(expectingQueueCount: fresh.count)
        defer { second.playbackManager.stop() }
        #expect(second.playlistManager.currentQueue.map(\.id) == fresh.map(\.id))
        #expect(second.playbackManager.currentTrack?.trackId == fresh[1].trackId)
        #expect(second.playlistManager.currentQueueIndex == 1)
        #expect(second.playlistManager.repeatMode == .all)
    }

    /// Pausing makes the playhead durable through the coordinator, which both
    /// platforms share; the Mac had no playhead mark at all, so a crash there
    /// rolled back to the last quit.
    @Test func aKillAfterPausingResumesAtThePausedPosition() async throws {
        let fixture = try await CrashFixture(count: 2)
        defer { fixture.cleanUp() }
        try fixture.saveSession(current: fixture.tracks[0], queue: fixture.tracks, index: 0, position: 0)

        let first = AppCoordinator()
        defer { first.playbackManager.stop() }
        first.playbackManager.volume = 0
        first.restorePlaybackState()
        try await waitUntil { first.playbackManager.currentFullTrack != nil }

        let target = fixture.tracks[1]
        first.playlistManager.playTrack(target, fromTracks: fixture.tracks)
        try await waitUntil { first.playbackManager.audioPlayer.state == .playing }
        try #require(first.playbackManager.audioPlayer.state == .playing)
        first.playbackManager.seekTo(time: 5)
        try await waitUntil { first.playbackManager.currentTime >= 5 }
        first.playbackManager.togglePlayPause()
        #expect(!first.playbackManager.isPlaying)
        let pausedAt = first.playbackManager.currentTime

        // The process dies here: only what the pause wrote survives.
        try await waitUntil(.seconds(2)) { (try? CrashFixture.savedMark().trackId) == target.trackId }
        let mark = try CrashFixture.savedMark()
        #expect(mark.trackId == target.trackId, "the pause did not record the playhead")
        #expect(abs(mark.position - pausedAt) < 0.5)
        first.playbackManager.stop()

        let second = try await relaunch(expectingQueueCount: fixture.tracks.count)
        defer { second.playbackManager.stop() }
        #expect(second.playbackManager.currentTrack?.trackId == target.trackId)
        #expect(abs(second.playbackManager.currentTime - pausedAt) < 0.5)
    }
}
}
