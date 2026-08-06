import Foundation
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
}
