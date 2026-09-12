//
// JSONLPlaybackJournal
//
// iOS writer for the PlaybackJournal seam. Events accumulate in memory and
// flush as JSONL lines into Documents/Sync/playback-journal.jsonl — the same
// moment AppCoordinator saves playback state (backgrounding).
//

import Foundation

@MainActor
final class JSONLPlaybackJournal: PlaybackJournal {
    private var pending: [PlaybackJournalEvent] = []
    private var flushTask: Task<Void, Never>?
    private let fileURL: URL

    init(
        documentsURL: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    ) {
        self.fileURL = documentsURL
            .appendingPathComponent("Sync", isDirectory: true)
            .appendingPathComponent("playback-journal.jsonl")
    }

    func trackPlayed(relativePath: String, at date: Date) {
        guard !relativePath.isEmpty else { return }
        pending.append(.played(path: relativePath, at: date))
    }

    func favoriteChanged(relativePath: String, value: Bool, at date: Date) {
        guard !relativePath.isEmpty else { return }
        pending.append(.favorite(path: relativePath, value: value, at: date))
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
