import Foundation
import Testing
@testable import Petrichor

private func makeEntry(_ name: String) -> QueueEntry {
    QueueEntry(entryId: AudioEntryId(id: name), url: URL(fileURLWithPath: "/tmp/\(name).mp3"))
}

@Test func setQueueInstallsEntriesInOrder() {
    let backend = AVQueuePlayerBackend()
    let entries = [makeEntry("a"), makeEntry("b"), makeEntry("c")]

    backend.setQueue(entries, startingAt: 0, startPaused: true)

    #expect(backend.queue.map(\.id) == ["a", "b", "c"])
}

@Test func insertNextPlacesEntryRightAfterCurrent() {
    let backend = AVQueuePlayerBackend()
    backend.setQueue([makeEntry("a"), makeEntry("b")], startingAt: 0, startPaused: true)

    backend.insertNext(makeEntry("x"))

    #expect(backend.queue.map(\.id) == ["a", "x", "b"])
    #expect(backend.hasQueuedSuccessor)
}

@Test func removingTheOnlySuccessorClearsTheFlag() {
    let backend = AVQueuePlayerBackend()
    backend.setQueue([makeEntry("a"), makeEntry("b")], startingAt: 0, startPaused: true)

    backend.removeQueueEntry(id: AudioEntryId(id: "b"))

    #expect(backend.hasQueuedSuccessor == false)
    #expect(backend.queueIndex(of: AudioEntryId(id: "b")) == nil)
}

@Test func shuffleKeepsPlayedAndCurrentInPlace() {
    let backend = AVQueuePlayerBackend()
    let entries = (0..<10).map { makeEntry("t\($0)") }
    backend.setQueue(entries, startingAt: 2, startPaused: true)

    backend.shuffleQueue()

    #expect(backend.queue.prefix(3).map(\.id) == ["t0", "t1", "t2"])
    #expect(backend.queue.count == 10)
}
