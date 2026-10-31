//
// JSONLPlaybackJournal
//
// Writer for the PlaybackJournal seam on both platforms. Each event is
// appended as soon as it is recorded, so the sync job finds it even while the
// app stays open; iOS flushes again on backgrounding to retry a failed write.
//

import Foundation

@MainActor
final class JSONLPlaybackJournal: PlaybackJournal {
    private var pending: [PlaybackJournalEvent] = []
    private var flushTask: Task<Void, Never>?
    private let fileURL: URL

    init(fileURL: URL = PlaybackJournalFiles.outbox) {
        self.fileURL = fileURL
    }

    func trackPlayed(relativePath: String, at date: Date) {
        record(.played(path: relativePath, at: date))
    }

    func favoriteChanged(relativePath: String, value: Bool, at date: Date) {
        record(.favorite(path: relativePath, value: value, at: date))
    }

    private func record(_ event: PlaybackJournalEvent) {
        guard !event.path.isEmpty else { return }
        pending.append(event)
        Task { await flush() }
    }

    func flush() async {
        if let flushTask {
            await flushTask.value
            return
        }
        guard !pending.isEmpty else { return }
        let task = Task {
            defer { flushTask = nil }
            await writePendingEvents()
        }
        flushTask = task
        await task.value
    }

    private func writePendingEvents() async {
        while !pending.isEmpty {
            let events = pending
            pending.removeAll()
            let fileURL = fileURL
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    Self.writeQueue.async {
                        continuation.resume(with: Result {
                            try Self.write(events, to: fileURL)
                        })
                    }
                }
            } catch {
                // Keep the failed batch ahead of events recorded during its write.
                pending.insert(contentsOf: events, at: 0)
                Logger.error("PlaybackJournal flush failed: \(error)")
                return
            }
        }
    }

    // ponytail: one process-wide writer; per-file queues only if multiple journals need throughput.
    nonisolated private static let writeQueue = DispatchQueue(label: "petrichor.playback-journal.write")

    nonisolated private static func write(
        _ events: [PlaybackJournalEvent],
        to fileURL: URL
    ) throws {
        let fileManager = FileManager()
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let payload = try events
            .map { try PlaybackJournalCodec.encodeLine($0) }
            .joined(separator: "\n") + "\n"
        let data = Data(payload.utf8)

        if fileManager.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            let offset = try handle.seekToEnd()
            do {
                try handle.write(contentsOf: data)
            } catch {
                // A partial append must not become a duplicate batch on retry.
                try handle.truncate(atOffset: offset)
                throw error
            }
        } else {
            try data.write(to: fileURL, options: .atomic)
        }
    }
}
