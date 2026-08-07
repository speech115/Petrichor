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

        #expect(backend.preloadedItemCount == 17, "текущий + 16 следующих, а не вся очередь")
        #expect(backend.queue.count == 40, "логическая очередь хранит всё")
    }
}

@Test func shortQueuesPreloadEverything() throws {
    try withFixture { url in
        let backend = AVQueuePlayerBackend()
        backend.setQueue(makeManyEntries(5, url: url), startingAt: 0, startPaused: true)

        #expect(backend.preloadedItemCount == 5)
    }
}

@Test func appendRefillsOnlyUpToTheCap() throws {
    try withFixture { url in
        let backend = AVQueuePlayerBackend()
        backend.setQueue(makeManyEntries(10, url: url), startingAt: 0, startPaused: true)

        (0..<10).forEach { _ in backend.append(makeEntry("extra", url: url)) }

        #expect(backend.preloadedItemCount == 17, "долив не превышает lookahead-окно")
        #expect(backend.queue.count == 20)
    }
}

@Test func jumpingDeepIntoTheQueueReloadsOnlyItsWindow() throws {
    try withFixture { url in
        let backend = AVQueuePlayerBackend()
        backend.setQueue(makeManyEntries(40, url: url), startingAt: 0, startPaused: true)

        backend.playQueueEntry(at: 20, startPaused: true)

        #expect(backend.preloadedItemCount == 17, "окно лимитировано даже при прыжке в середину очереди")
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
}
