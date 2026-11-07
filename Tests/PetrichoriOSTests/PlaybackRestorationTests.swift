import Foundation
import GRDB
import Testing
@testable import Petrichor

// Regressions for the queue/restore state machines (docs/state-machines.md,
// SM-2 and SM-3). Each test names the invariant it guards. Nested under
// `PlaybackTests` so it runs serially with the other suites that touch the
// process-wide audio session and the saved-state UserDefaults keys.

/// Silent tracks written under the library root and inserted as database
/// rows, removed again by `cleanUp()`.
@MainActor
private struct TrackFixture {
    let database: DatabaseManager
    let folderURL: URL
    let folderID: Int64
    let tracks: [Track]

    static let savedKeys = ["SavedPlaybackState", "SavedPlaybackUIState", "SavedPlaybackPosition"]

    init(count: Int) async throws {
        let database = try DatabaseManager()
        let folderURL = LibraryPathStore.libraryRoot.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let urls = try (0..<count).map { index in
            let url = folderURL.appendingPathComponent("Track \(index).wav")
            try FileManager.default.moveItem(at: try makeSilentWAV(seconds: 4), to: url)
            return url
        }
        let (folderID, tracks) = try await database.dbQueue.write { db -> (Int64, [Track]) in
            try Folder(url: folderURL).insert(db)
            let folderID = db.lastInsertedRowID
            var tracks: [Track] = []
            for (index, url) in urls.enumerated() {
                var full = FullTrack(url: url)
                full.folderId = folderID
                full.title = "Track \(index)"
                full.duration = 4
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
        try? database.dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "DELETE FROM tracks WHERE folder_id = ?", arguments: [folderID])
            try db.execute(sql: "DELETE FROM folders WHERE id = ?", arguments: [folderID])
        }
        try? FileManager.default.removeItem(at: folderURL)
    }

    /// The managers wired the way `AppCoordinator` wires them, without its
    /// launch restoration.
    func makeManagers() -> (PlaylistManager, PlaybackManager) {
        let library = LibraryManager(databaseManager: database, deferLaunchWork: true)
        let playlists = PlaylistManager()
        let playback = PlaybackManager(libraryManager: library, playlistManager: playlists)
        playlists.setAudioPlayer(playback)
        playlists.setLibraryManager(library)
        playback.volume = 0
        return (playlists, playback)
    }

    /// Writes a saved session the way a backgrounding would, returning the old
    /// values so the test can put them back.
    static func saveSession(current: Track?, queue: [Track], index: Int, position: Double) throws -> [Data?] {
        let defaults = UserDefaults.standard
        let old = savedKeys.map { defaults.data(forKey: $0) }
        let state = PlaybackState(
            currentTrack: current, playbackPosition: position, queue: queue, currentQueueIndex: index,
            queueSource: .library, volume: 0, isMuted: true, shuffleEnabled: false, repeatMode: .off
        )
        defaults.set(try JSONEncoder().encode(state), forKey: savedKeys[0])
        if let current {
            defaults.set(try JSONEncoder().encode(state.createUIState(from: current)), forKey: savedKeys[1])
        }
        defaults.removeObject(forKey: savedKeys[2])
        return old
    }

    static func restoreDefaults(_ old: [Data?]) {
        for (key, value) in zip(savedKeys, old) {
            UserDefaults.standard.set(value, forKey: key)
        }
    }
}

@MainActor
private func waitUntil(_ timeout: Duration = .seconds(8), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(50))
    }
}

extension PlaybackTests {
@MainActor
struct QueueCursorTests {
    /// I-2.2: the queue cursor names the entry that plays. A restored queue
    /// whose saved index disagrees with the restored track (tracks before it
    /// vanished) must not keep the stale cursor once Play starts the track.
    @Test func playingARestoredTrackMovesTheCursorOntoIt() async throws {
        let fixture = try await TrackFixture(count: 4)
        defer { fixture.cleanUp() }
        let (playlists, playback) = fixture.makeManagers()
        defer { playback.stop() }

        playlists.replaceCurrentQueue(fixture.tracks, index: 0)
        playback.prepareTrackForRestoration(fixture.tracks[2], at: 0)
        try await waitUntil { playback.currentFullTrack != nil }
        try #require(playback.currentFullTrack != nil)

        playback.togglePlayPause()

        #expect(playback.currentTrack?.id == fixture.tracks[2].id)
        #expect(playlists.currentQueueIndex == playback.mirroredQueuePosition)
        #expect(playlists.currentQueueIndex == 2, "Next must follow the restored track, not the stale cursor")
    }

    /// I-2.2: shuffling before the first Play (no engine queue yet) keeps the
    /// restored track current, the way the engine-side shuffle keeps the
    /// playing one in place.
    @Test func shuffleBeforeTheFirstPlayKeepsTheRestoredTrackCurrent() async throws {
        let fixture = try await TrackFixture(count: 30)
        defer { fixture.cleanUp() }
        let (playlists, playback) = fixture.makeManagers()
        defer { playback.stop() }

        let restored = fixture.tracks[17]
        playlists.replaceCurrentQueue(fixture.tracks, index: 17)
        playback.prepareTrackForRestoration(restored, at: 0)
        try await waitUntil { playback.currentFullTrack != nil }

        playlists.toggleShuffle()

        #expect(Set(playlists.currentQueue.map(\.id)) == Set(fixture.tracks.map(\.id)))
        #expect(playlists.currentQueue[playlists.currentQueueIndex].id == restored.id)

        playback.togglePlayPause()
        #expect(playlists.currentQueueIndex == playback.mirroredQueuePosition)
        #expect(playlists.currentQueue[playlists.currentQueueIndex].id == restored.id)
    }
}

@MainActor
struct RestorationRaceTests {
    enum SavedSession: CaseIterable {
        /// A valid session: restoration would apply it.
        case restorable
        /// A session whose queue is gone: restoration discards it.
        case discarded
    }

    /// I-3.3: a track the user starts while restoration is still waiting for
    /// the library stays the playing track, queue and tile included.
    @Test(arguments: SavedSession.allCases)
    func restorationNeverReplacesATrackTheUserStarted(_ session: SavedSession) async throws {
        let fixture = try await TrackFixture(count: 3)
        defer { fixture.cleanUp() }
        let saved: (current: Track, queue: [Track])
        switch session {
        case .restorable:
            saved = (fixture.tracks[0], [fixture.tracks[0], fixture.tracks[1]])
        case .discarded:
            var gone = Track(url: LibraryPathStore.libraryRoot.appendingPathComponent("gone/missing.wav"))
            gone.trackId = 9_000_000_001
            gone.title = "Gone"
            saved = (gone, [gone])
        }
        let old = try TrackFixture.saveSession(current: saved.current, queue: saved.queue, index: 0, position: 1)
        defer { TrackFixture.restoreDefaults(old) }

        let coordinator = AppCoordinator()
        let playback = coordinator.playbackManager
        let playlists = coordinator.playlistManager
        defer { playback.stop() }

        let chosen = fixture.tracks[2]
        playlists.playTrack(chosen, fromTracks: [chosen])
        #expect(playback.currentTrack?.id == chosen.id)

        coordinator.restorePlaybackState()
        try await waitUntil(.seconds(5)) { playback.currentTrack?.id != chosen.id }

        #expect(playback.currentTrack?.id == chosen.id, "restoration replaced the track the user started")
        #expect(playlists.currentQueue.map(\.id) == [chosen.id])
        #expect(playlists.currentQueueIndex == playback.mirroredQueuePosition)
    }

    /// I-3.1 / I-3.2: when the saved current track is not in the restored
    /// queue, the temporary tile goes away instead of latching Play forever.
    @Test func restorationWithoutItsCurrentTrackDropsTheTemporaryTile() async throws {
        let fixture = try await TrackFixture(count: 3)
        defer { fixture.cleanUp() }
        let queue = [fixture.tracks[0], fixture.tracks[1]]
        let old = try TrackFixture.saveSession(current: fixture.tracks[2], queue: queue, index: 1, position: 1)
        defer { TrackFixture.restoreDefaults(old) }

        let coordinator = AppCoordinator()
        let playback = coordinator.playbackManager
        defer { playback.stop() }
        #expect(playback.currentTrack != nil && playback.currentTrack?.trackId == nil, "the temporary tile shows first")

        coordinator.restorePlaybackState()
        try await waitUntil { coordinator.playlistManager.currentQueue.count == queue.count }
        try #require(coordinator.playlistManager.currentQueue.count == queue.count)
        try await waitUntil(.seconds(1)) { false }

        #expect(playback.restoredUITrack == nil)
        #expect(playback.currentTrack == nil || playback.currentTrack?.trackId != nil, "temporary tile outlived restoration")

        playback.togglePlayPause()
        try await waitUntil(.seconds(3)) { playback.audioPlayer.state == .playing }
        #expect(!playback.isPlaying || playback.audioPlayer.state == .playing, "Play latched over silence")
    }
}
}
