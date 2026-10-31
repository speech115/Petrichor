import AVFoundation
import Foundation
import GRDB
import Testing
@testable import Petrichor

// The only test that proves audio actually starts: everything else exercises
// queue bookkeeping, which stays green even when nothing ever reaches the
// speaker. Playback touches the process-wide `AVAudioSession`, so these run
// serially, including the queue suites nested under PlaybackTests.
@Suite(.serialized)
struct PlaybackTests {}

extension PlaybackTests {
@MainActor
struct PlaybackStartTests {
    @Test func restoredTrackSurvivesAnEarlySaveAndPlaysAfterLibraryLoads() async throws {
        let defaults = UserDefaults.standard
        let keys = ["SavedPlaybackState", "SavedPlaybackUIState"]
        let oldValues = keys.map { defaults.data(forKey: $0) }
        let database = try DatabaseManager()
        let artwork = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let wav = try makeSilentWAV(seconds: 12)
        let folderURL = LibraryPathStore.libraryRoot.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let url = folderURL.appendingPathComponent("Restore.wav")
        try FileManager.default.moveItem(at: wav, to: url)
        let track = try await database.dbQueue.write { db in
            try Folder(url: folderURL).insert(db)
            let folderID = db.lastInsertedRowID
            var full = FullTrack(url: url)
            full.folderId = folderID
            full.title = "Restore"
            full.duration = 12
            full.trackArtworkData = artwork
            try full.insert(db)
            return try #require(try Track.filter(Track.Columns.trackId == db.lastInsertedRowID).fetchOne(db))
        }
        defer {
            for (key, value) in zip(keys, oldValues) { defaults.set(value, forKey: key) }
            try? database.dbQueue.writeWithoutTransaction { db in
                try db.execute(sql: "DELETE FROM tracks WHERE id = ?", arguments: [track.trackId])
                try db.execute(sql: "DELETE FROM folders WHERE id = ?", arguments: [track.folderId])
            }
            try? FileManager.default.removeItem(at: folderURL)
        }
        let state = PlaybackState(
            currentTrack: track, playbackPosition: 3, queue: [track], currentQueueIndex: 0,
            queueSource: .library, volume: 0, isMuted: true, shuffleEnabled: false, repeatMode: .off
        )
        let saved = try JSONEncoder().encode(state)
        defaults.set(saved, forKey: keys[0])
        defaults.set(try JSONEncoder().encode(state.createUIState(from: track)), forKey: keys[1])
        let coordinator = AppCoordinator()
        let playback = coordinator.playbackManager
        defer { playback.stop() }
        // The count query is still in flight, exactly as on a large cold library.
        #expect(!coordinator.libraryManager.countsLoaded)
        coordinator.restorePlaybackState()
        coordinator.savePlaybackState()
        #expect(defaults.data(forKey: keys[0]) == saved, "temporary UI must not overwrite the saved track")
        await coordinator.savePlaybackStateInBackground()
        let backgroundState = try JSONDecoder().decode(
            PlaybackState.self, from: #require(defaults.data(forKey: keys[0]))
        )
        #expect(backgroundState.currentTrackId == track.trackId)
        #expect(backgroundState.queueTrackIds == state.queueTrackIds)
        #expect(backgroundState.playbackPosition == 3)

        let deadline = ContinuousClock.now + .seconds(8)
        while playback.currentFullTrack == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(playback.currentTrack?.trackId == track.trackId, "library completion must finish restoration")
        #expect(!playback.isPlaying, "restoring must wait for Play")
        let artworkDeadline = ContinuousClock.now + .seconds(8)
        while playback.currentTrack?.albumArtworkData == nil, ContinuousClock.now < artworkDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(playback.currentTrack?.albumArtworkData == artwork, "restored track must show its cover before Play")
        playback.togglePlayPause()
        let playingDeadline = ContinuousClock.now + .seconds(8)
        while playback.audioPlayer.state != .playing, ContinuousClock.now < playingDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(playback.audioPlayer.state == .playing, "restored track must actually play")
        #expect(playback.audioPlayer.currentPlaybackProgress >= 3, "resume must retain the saved position")
    }

    @Test func startingAQueueReachesThePlayingState() async throws {
        let url = try makeSilentWAV()
        defer { try? FileManager.default.removeItem(at: url) }

        let backend = AVQueuePlayerBackend()
        backend.setQueue(
            [QueueEntry(entryId: AudioEntryId(id: "silent"), url: url)],
            startingAt: 0,
            startPaused: false
        )

        #expect(await waitForPlaying(backend), "плеер не дошёл до состояния playing")
    }

    /// The seek bar divides current time by the item's duration: if the
    /// duration is not known yet (or reported as indefinite), the bar stays
    /// pinned at zero while the track plays - the "music plays, slider frozen"
    /// symptom. Duration must settle to the real value shortly after start,
    /// and progress must advance.
    @Test func progressAdvancesOnceDurationIsKnown() async throws {
        let url = try makeSilentWAV(seconds: 2)
        defer { try? FileManager.default.removeItem(at: url) }

        let backend = AVQueuePlayerBackend()
        backend.setQueue(
            [QueueEntry(entryId: AudioEntryId(id: "silent"), url: url)],
            startingAt: 0,
            startPaused: false
        )
        #expect(await waitForPlaying(backend))

        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline, backend.duration == 0 {
            try? await Task.sleep(for: .milliseconds(100))
        }

        #expect(backend.duration > 0, "длительность так и не стала известна — слайдер застынет на нуле")

        let first = backend.currentPlaybackProgress
        try await Task.sleep(for: .milliseconds(700))
        let second = backend.currentPlaybackProgress
        #expect(second > first, "прогресс не растёт во время воспроизведения")
    }

    @Test func resumeAfterAPausedStartAlsoReachesThePlayingState() async throws {
        let url = try makeSilentWAV()
        defer { try? FileManager.default.removeItem(at: url) }

        let backend = AVQueuePlayerBackend()
        backend.setQueue(
            [QueueEntry(entryId: AudioEntryId(id: "silent"), url: url)],
            startingAt: 0,
            startPaused: true
        )
        #expect(backend.state == .paused)

        backend.resume()

        #expect(await waitForPlaying(backend), "resume не запустил воспроизведение")
    }
}

}

// MARK: - Regression: false finish and queue refill

/// Records delegate callbacks. `AVQueuePlayerBackend` routes every call
/// through the main thread, so the test reads this only via `MainActor`.
private final class RecordingDelegate: PlaybackBackendDelegate {
    var started: [AudioEntryId] = []
    var finished: [(entryId: AudioEntryId, stopReason: AudioPlayerStopReason)] = []
    var skipped: [AudioEntryId] = []
    var errors: [AudioPlayerError] = []

    func backendDidStartPlaying(with entryId: AudioEntryId) { started.append(entryId) }
    func backendStateChanged(with newState: AudioPlayerState, previous: AudioPlayerState) {}
    func backendDidFinishPlaying(entryId: AudioEntryId, stopReason: AudioPlayerStopReason, progress: Double, duration: Double) {
        finished.append((entryId, stopReason))
    }
    func backendUnexpectedError(error: AudioPlayerError) { errors.append(error) }
    func backendDidFinishBuffering(with entryId: AudioEntryId) {}
    func backendDidSkipQueueEntry(entryId: AudioEntryId) { skipped.append(entryId) }
}

/// Regression for the "player does not open" bug: starting a new queue while
/// something is playing tears the old queue down, and the resulting KVO
/// `currentItem: old -> nil` transition used to be reported as a finished
/// track. That invented an eof, advanced the queue index and bumped play
/// counts for a track that never finished. Rebooting the queue must not emit
/// any finish event.
extension PlaybackTests {
@MainActor
struct QueueRebuildRegressionTests {
    private func waitForFinishCount(
        _ delegate: RecordingDelegate,
        _ count: Int,
        timeout: Duration = .seconds(5)
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await MainActor.run(body: { delegate.finished.count }) >= count { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    @Test func rebuildingTheQueueOverAPlayingTrackDoesNotReportAFinish() async throws {
        let first = try makeSilentWAV(seconds: 2)
        let second = try makeSilentWAV(seconds: 2)
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        let backend = AVQueuePlayerBackend()
        let delegate = RecordingDelegate()
        backend.backendDelegate = delegate
        backend.setQueue(
            [
                QueueEntry(entryId: AudioEntryId(id: "first"), url: first),
                QueueEntry(entryId: AudioEntryId(id: "second"), url: second)
            ],
            startingAt: 0,
            startPaused: false
        )
        #expect(await waitForPlaying(backend))

        try await Task.sleep(for: .milliseconds(300))
        backend.playQueueEntry(at: 1, startPaused: false)

        try await Task.sleep(for: .seconds(1))
        await MainActor.run {
            #expect(delegate.finished.isEmpty, "пересборка очереди не должна выдавать ложное завершение трека")
        }

        #expect(await waitForFinishCount(delegate, 1, timeout: .seconds(5)))
        await MainActor.run {
            #expect(delegate.finished.map(\.entryId.id) == ["second"], "завершиться должен только реально доигранный трек")
        }
    }
}

}

/// The lookahead window preloads only the current item and its successor, so a long queue must be
/// refilled while playing or it would silently end after the window. Playing
/// through 18 one-second tracks proves the whole queue is consumed in order.
extension PlaybackTests {
@MainActor
struct QueueRefillTests {
    @Test func aQueueLongerThanTheLookaheadWindowPlaysThroughToTheEnd() async throws {
        var urls: [URL] = []
        var entries: [QueueEntry] = []
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }

        for index in 0..<18 {
            let url = try makeSilentWAV(seconds: 1)
            urls.append(url)
            entries.append(QueueEntry(entryId: AudioEntryId(id: "t\(index)"), url: url))
        }

        let backend = AVQueuePlayerBackend()
        let delegate = RecordingDelegate()
        backend.backendDelegate = delegate
        backend.setQueue(entries, startingAt: 0, startPaused: false)
        #expect(await waitForPlaying(backend))

        let deadline = ContinuousClock.now + .seconds(40)
        while ContinuousClock.now < deadline {
            let count = await MainActor.run(body: { delegate.finished.count })
            if count == entries.count { break }
            try? await Task.sleep(for: .milliseconds(200))
        }

        await MainActor.run {
            #expect(delegate.finished.map(\.entryId.id) == (0..<18).map { "t\($0)" },
                    "все треки должны доиграть по порядку, очередь доливается за lookahead-окном")
            #expect(delegate.skipped.isEmpty)
            #expect(delegate.errors.isEmpty)
        }
    }
}

}

/// A track that cannot be opened is dropped from the queue and playback moves
/// on. When it was the last entry there is nothing to move on to: the queue
/// ends instead of replaying the track before it.
extension PlaybackTests {
@MainActor
struct QueueItemFailureTests {
    private let broken = QueueEntry(
        entryId: AudioEntryId(id: "broken"),
        url: FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).wav")
    )

    private func startWithBrokenLastTrack(startPaused: Bool) async throws -> (AVQueuePlayerBackend, RecordingDelegate, URL) {
        let url = try makeSilentWAV(seconds: 1)
        let backend = AVQueuePlayerBackend()
        let delegate = RecordingDelegate()
        backend.backendDelegate = delegate
        backend.setQueue(
            [QueueEntry(entryId: AudioEntryId(id: "played"), url: url), broken],
            startingAt: 1,
            startPaused: startPaused
        )
        #expect(await waitUntil { delegate.skipped.map(\.id) == ["broken"] })
        try await Task.sleep(for: .seconds(1))
        return (backend, delegate, url)
    }

    @Test func aFailedLastTrackEndsTheQueueInsteadOfReplayingThePreviousOne() async throws {
        let (backend, delegate, url) = try await startWithBrokenLastTrack(startPaused: false)
        defer { backend.stop(); try? FileManager.default.removeItem(at: url) }

        #expect(!delegate.started.map(\.id).contains("played"), "уже сыгранный трек не должен запускаться снова")
        #expect(backend.state != .playing)
    }

    @Test func aFailedLastTrackWhilePausedStaysSilent() async throws {
        let (backend, delegate, url) = try await startWithBrokenLastTrack(startPaused: true)
        defer { backend.stop(); try? FileManager.default.removeItem(at: url) }

        #expect(!delegate.started.map(\.id).contains("played"))
        #expect(backend.state != .playing, "сбой на паузе не должен включать звук")
    }

    @Test func playAfterAFailedLastTrackPlaysTheRemainingQueue() async throws {
        let (backend, delegate, url) = try await startWithBrokenLastTrack(startPaused: false)
        defer { backend.stop(); try? FileManager.default.removeItem(at: url) }

        backend.resume()

        #expect(await waitForPlaying(backend), "Play после конца очереди должен играть, а не молчать")
        #expect(delegate.started.last?.id == "played")
    }

    @Test func aFailedCurrentTrackHandsOverToItsSuccessor() async throws {
        let url = try makeSilentWAV(seconds: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let backend = AVQueuePlayerBackend()
        let delegate = RecordingDelegate()
        backend.backendDelegate = delegate
        defer { backend.stop() }

        backend.setQueue([broken, QueueEntry(entryId: AudioEntryId(id: "next"), url: url)], startingAt: 0, startPaused: false)

        #expect(await waitUntil { delegate.started.map(\.id).contains("next") })
        #expect(await waitForPlaying(backend))
        #expect(backend.queue.map(\.id) == ["next"])
    }
}
}

/// Repeat injects the next track into the engine queue; reordering the queue
/// must keep that successor, or repeat-one walks on to another track.
extension PlaybackTests {
@MainActor
struct ShuffleRepeatTests {
    @Test func turningShuffleOnWhilePlayingKeepsRepeatOne() async throws {
        let urls = try (0..<4).map { _ in try makeSilentWAV(seconds: 1) }
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let tracks = urls.map(Track.init(url:))
        let coordinator = AppCoordinator()
        let playback = coordinator.playbackManager
        let playlists = coordinator.playlistManager
        defer {
            playback.stop()
            playlists.repeatMode = .off
            playlists.isShuffleEnabled = false
        }

        playlists.repeatMode = .one
        playlists.playTrack(tracks[0], fromTracks: tracks)
        #expect(await waitUntil(timeout: .seconds(60)) { playback.audioPlayer.currentPlaybackProgress > 0.2 })

        playlists.toggleShuffle()

        try await Task.sleep(for: .seconds(2.5))
        #expect(playback.currentTrack?.url == tracks[0].url, "repeat-one должен повторять тот же трек после shuffle")
    }
}
}

// MARK: - Shared fixtures

@MainActor
fileprivate func waitUntil(timeout: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline, !condition() {
        try? await Task.sleep(for: .milliseconds(50))
    }
    return condition()
}

/// Polls instead of sleeping a fixed amount: the player reaches `.playing`
/// only after the item loads, and that timing is not ours to predict. The
/// The 60-second timeout covers a cold media-service boot on hosted runners;
/// subsequent playback starts in the same run are fast.
@MainActor
fileprivate func waitForPlaying(_ backend: AVQueuePlayerBackend, timeout: Duration = .seconds(60)) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if backend.state == .playing { return true }
        try? await Task.sleep(for: .milliseconds(100))
    }
    return false
}
