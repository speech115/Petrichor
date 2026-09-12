import Foundation
import MediaPlayer
import Testing
@testable import Petrichor

// A queue entry pointing at a *missing* file would be dropped by the
// backend's failure handling: AVPlayerItem reaches `.failed` asynchronously
// and `handleItemFailure` removes it from the queue, racing with these
// bookkeeping assertions. Entries therefore share one real silent WAV.
// The suite is serialized: these tests construct real AVQueuePlayers with
// dozens of items, and several at once overload the simulator's media
// service, which starts dropping items.
@Suite(.serialized)
@MainActor
struct QueueBackendTests {
    private func makeEntry(_ name: String, url: URL) -> QueueEntry {
        QueueEntry(entryId: AudioEntryId(id: name), url: url)
    }

    private func makeManyEntries(_ count: Int, url: URL) -> [QueueEntry] {
        (0..<count).map { makeEntry("t\($0)", url: url) }
    }

    private func withFixture(_ body: (URL) throws -> Void) throws {
        let url = try makeSilentWAV(seconds: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }

@Test func setQueueInstallsEntriesInOrder() throws {
    try withFixture { url in
        let backend = AVQueuePlayerBackend()
        let entries = [makeEntry("a", url: url), makeEntry("b", url: url), makeEntry("c", url: url)]

        backend.setQueue(entries, startingAt: 0, startPaused: true)

        #expect(backend.queue.map(\.id) == ["a", "b", "c"])
    }
}

@Test func insertNextPlacesEntryRightAfterCurrent() throws {
    try withFixture { url in
        let backend = AVQueuePlayerBackend()
        backend.setQueue([makeEntry("a", url: url), makeEntry("b", url: url)], startingAt: 0, startPaused: true)

        backend.insertNext(makeEntry("x", url: url))

        #expect(backend.queue.map(\.id) == ["a", "x", "b"])
        #expect(backend.hasQueuedSuccessor)
    }
}

@Test func removingTheOnlySuccessorClearsTheFlag() throws {
    try withFixture { url in
        let backend = AVQueuePlayerBackend()
        backend.setQueue([makeEntry("a", url: url), makeEntry("b", url: url)], startingAt: 0, startPaused: true)

        backend.removeQueueEntry(id: AudioEntryId(id: "b"))

        #expect(backend.hasQueuedSuccessor == false)
        #expect(backend.queueIndex(of: AudioEntryId(id: "b")) == nil)
    }
}

@Test func shuffleKeepsPlayedAndCurrentInPlace() throws {
    try withFixture { url in
        let backend = AVQueuePlayerBackend()
        let entries = (0..<10).map { makeEntry("t\($0)", url: url) }
        backend.setQueue(entries, startingAt: 2, startPaused: true)

        backend.shuffleQueue()

        #expect(backend.queue.prefix(3).map(\.id) == ["t0", "t1", "t2"])
        #expect(backend.queue.count == 10)
    }
}

// MARK: - Lookahead window

// A huge queue (e.g. all 3853 tracks) must not be loaded into the player at
// once: every AVPlayerItem does a synchronous XPC to the media service, so
// preloading the whole library hangs the main thread until the watchdog kills
// the app. The backend caps preloaded items at current + lookahead.

@Test func setQueuePreloadsOnlyTheLookaheadWindow() throws {
    try withFixture { url in
        let backend = AVQueuePlayerBackend()
        backend.setQueue(makeManyEntries(40, url: url), startingAt: 0, startPaused: true)

        #expect(backend.preloadedItemCount == 2, "текущий + один следующий, а не вся очередь")
        #expect(backend.queue.count == 40, "логическая очередь хранит всё")
    }
}

@Test func shortQueuesPreloadEverything() throws {
    try withFixture { url in
        let backend = AVQueuePlayerBackend()
        backend.setQueue(makeManyEntries(5, url: url), startingAt: 0, startPaused: true)

        #expect(backend.preloadedItemCount == 2)
    }
}

@Test func appendRefillsOnlyUpToTheCap() throws {
    try withFixture { url in
        let backend = AVQueuePlayerBackend()
        backend.setQueue(makeManyEntries(10, url: url), startingAt: 0, startPaused: true)

        (0..<10).forEach { _ in backend.append(makeEntry("extra", url: url)) }

        #expect(backend.preloadedItemCount == 2, "долив не превышает lookahead-окно")
        #expect(backend.queue.count == 20)
    }
}

@Test func jumpingDeepIntoTheQueueReloadsOnlyItsWindow() throws {
    try withFixture { url in
        let backend = AVQueuePlayerBackend()
        backend.setQueue(makeManyEntries(40, url: url), startingAt: 0, startPaused: true)

        backend.playQueueEntry(at: 20, startPaused: true)

        #expect(backend.preloadedItemCount == 2, "окно лимитировано даже при прыжке в середину очереди")
        #expect(backend.queueIndex(of: AudioEntryId(id: "t20")) == 20)
    }
}

// MARK: - Now Playing re-publication

/// The lock screen extrapolates elapsed time from the published rate+elapsed
/// anchor, so the backend must re-publish on its own events (pause, resume,
/// seek) instead of leaving the manager's one-time publish to go stale.
/// `MPNowPlayingInfoCenter` is a plain dictionary in-process, so the test can
/// read back exactly what the backend handed the system.
@Test func pauseRepublishesNowPlayingMetadata() async throws {
    let url = try makeSilentWAV(seconds: 2)
    defer { try? FileManager.default.removeItem(at: url) }

    let backend = AVQueuePlayerBackend()
    backend.setQueue(
        [QueueEntry(entryId: AudioEntryId(id: "silent"), url: url)],
        startingAt: 0,
        startPaused: false
    )

    // Wait for a stable `.playing` before publishing: the backend re-publishes
    // on every timeControlStatus change, and the load-time
    // `.waitingToPlayAtSpecifiedRate` → `.playing` transition would race with
    // the metadata assertions below on a slow start.
    let startedDeadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < startedDeadline, backend.state != .playing {
        try? await Task.sleep(for: .milliseconds(100))
    }
    #expect(backend.state == .playing, "плеер не дошёл до состояния playing")
    // Give the KVO re-publication of that final transition a beat to land.
    try await Task.sleep(for: .milliseconds(300))

    let metadata = NowPlayingMetadata(
        title: "Now Playing Test",
        artist: "Test Artist",
        albumTitle: "Test Album"
    )
    backend.setNowPlayingMetadata(metadata)

    var info = MPNowPlayingInfoCenter.default().nowPlayingInfo
    #expect(info?[MPMediaItemPropertyTitle] as? String == "Now Playing Test")
    #expect(info?[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1, "играющий трек публикует rate 1")

    backend.pause()
    // The KVO callback re-publishes asynchronously after the pause lands.
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
        info = MPNowPlayingInfoCenter.default().nowPlayingInfo
        if (info?[MPNowPlayingInfoPropertyPlaybackRate] as? Double) == 0 { break }
        try? await Task.sleep(for: .milliseconds(50))
    }

    #expect((info?[MPNowPlayingInfoPropertyPlaybackRate] as? Double) == 0, "пауза пере-публикует rate 0")
    #expect(info?[MPMediaItemPropertyTitle] as? String == "Now Playing Test", "пере-публикация сохраняет метаданные трека")
}
@Test func pausedTrackSwitchPublishesLoadedDurationAndSeekPosition() async throws {
    let first = try makeSilentWAV(seconds: 4)
    let second = try makeSilentWAV(seconds: 8)
    defer {
        try? FileManager.default.removeItem(at: first)
        try? FileManager.default.removeItem(at: second)
    }
    let backend = AVQueuePlayerBackend()
    defer { backend.stop(); backend.setNowPlayingMetadata(nil) }
    backend.setQueue([
        makeEntry("first", url: first), makeEntry("second", url: second)
    ], startingAt: 0, startPaused: true)
    for (index, seconds) in [4.0, 8.0].enumerated() {
        if index > 0 { backend.playQueueEntry(at: index, startPaused: true) }
        backend.setNowPlayingMetadata(NowPlayingMetadata(title: "Track \(index)"))
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            let published = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyPlaybackDuration] as? Double ?? 0
            if abs(published - seconds) < 0.1 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let published = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyPlaybackDuration] as? Double ?? 0
        #expect(abs(backend.duration - seconds) < 0.1)
        #expect(abs(published - seconds) < 0.1, "Lock screen must receive loaded duration after switching tracks")
        #expect(backend.seek(to: 2))
        let seekDeadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < seekDeadline {
            let elapsed = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double ?? 0
            if abs(elapsed - 2) < 0.1 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let elapsed = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double ?? 0
        #expect(abs(elapsed - 2) < 0.1)
    }
}

@Test func editingBeyondLookaheadPreservesPreparedItems() throws {
    try withFixture { url in
        let backend = AVQueuePlayerBackend()
        backend.setQueue(makeManyEntries(10, url: url), startingAt: 0, startPaused: true)
        let prepared = backend.preloadedItemIdentities
        backend.append(makeEntry("appended", url: url))
        backend.insert(makeEntry("inserted", url: url), at: 5)
        backend.removeQueueEntry(at: 5)
        #expect(backend.preloadedItemIdentities == prepared)
        backend.insertNext(makeEntry("next", url: url))
        #expect(backend.preloadedItemIdentities.first == prepared.first)
        #expect(backend.preloadedItemIdentities.last != prepared.last)
        #expect(backend.preloadedItemCount == 2)
    }
}

@Test func seekRejectsInvalidPositionsAndEmptyQueue() throws {
    let backend = AVQueuePlayerBackend()
    #expect(!backend.seek(to: 0))
    try withFixture { url in
        backend.setQueue([makeEntry("a", url: url)], startingAt: 0, startPaused: true)
        #expect(!backend.seek(to: .infinity))
        #expect(!backend.seek(to: .nan))
        #expect(!backend.seek(to: -1))
    }
}

@Test func movingForwardUsesTheSharedPreRemovalDestination() throws {
    try withFixture { url in
        let backend = AVQueuePlayerBackend()
        backend.setQueue(makeManyEntries(4, url: url), startingAt: 0, startPaused: true)
        backend.move(from: 0, to: 3)
        #expect(backend.queue.map(\.id) == ["t1", "t2", "t0", "t3"])
        #expect(backend.hasQueuedSuccessor)
        backend.move(from: 2, to: 0)
        #expect(backend.queue.map(\.id) == ["t0", "t1", "t2", "t3"])
    }
}

@Test func automaticTrackAdvanceKeepsLockScreenSeekable() async throws {
    let first = try makeSilentWAV(seconds: 1)
    let second = try makeSilentWAV(seconds: 6)
    defer {
        try? FileManager.default.removeItem(at: first)
        try? FileManager.default.removeItem(at: second)
    }
    let backend = AVQueuePlayerBackend()
    let delegate = NowPlayingTestDelegate()
    delegate.backend = backend
    backend.backendDelegate = delegate
    defer { backend.stop(); backend.setNowPlayingMetadata(nil) }
    backend.setQueue([
        makeEntry("first", url: first), makeEntry("second", url: second)
    ], startingAt: 0, startPaused: false)
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline {
        if delegate.currentID == "second", backend.state == .playing { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(delegate.currentID == "second")
    #expect(backend.state == .playing)
    let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
    #expect(info?[MPMediaItemPropertyTitle] as? String == "second")
    #expect(abs((info?[MPMediaItemPropertyPlaybackDuration] as? Double ?? 0) - 6) < 0.1)
    #expect(backend.seek(to: 3))
    let seekDeadline = ContinuousClock.now + .seconds(2)
    while ContinuousClock.now < seekDeadline, backend.currentPlaybackProgress < 2.9 {
        try await Task.sleep(for: .milliseconds(50))
    }
    let elapsed = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double ?? 0
    #expect(abs(elapsed - 3) < 0.3)
}

}


@MainActor
private final class NowPlayingTestDelegate: PlaybackBackendDelegate {
    weak var backend: AVQueuePlayerBackend?
    var currentID: String?

    func backendDidStartPlaying(with entryId: AudioEntryId) {
        currentID = entryId.id
        backend?.setNowPlayingMetadata(NowPlayingMetadata(title: entryId.id))
    }
    func backendStateChanged(with newState: AudioPlayerState, previous: AudioPlayerState) {}
    func backendDidFinishPlaying(entryId: AudioEntryId, stopReason: AudioPlayerStopReason, progress: Double, duration: Double) {}
    func backendUnexpectedError(error: AudioPlayerError) { Issue.record("Unexpected playback error: \(error)") }
    func backendDidFinishBuffering(with entryId: AudioEntryId) {}
    func backendDidSkipQueueEntry(entryId: AudioEntryId) { Issue.record("Unexpected skip: \(entryId.id)") }
}
