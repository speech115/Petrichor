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
    private let fileURL: URL
    private let fileManager: FileManager

    init(
        documentsURL: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0],
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
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
        guard !pending.isEmpty else { return }

        let events = pending
        pending.removeAll()

        // The FileHandle seek+write is I/O that must not pin the main actor
        // during the short backgrounding window; the pending swap above stays
        // on the main actor, only the disk write hops off. Scene-phase
        // transitions fire `.inactive` then `.background` back-to-back, so two
        // flushes can overlap — the serial queue keeps each seek+write atomic.
        let fileURL = self.fileURL
        let fileManager = self.fileManager

        do {
            try await Task.detached(priority: .userInitiated) {
                try Self.writeQueue.sync {
                    try Self.write(events, to: fileURL, fileManager: fileManager)
                }
            }.value
        } catch {
            pending.insert(contentsOf: events, at: 0)
            Logger.error("PlaybackJournal flush failed: \(error)")
        }
    }

    /// Serializes the detached file writes (see `flush()`).
    nonisolated private static let writeQueue = DispatchQueue(label: "petrichor.playback-journal.write")

    nonisolated private static func write(
        _ events: [PlaybackJournalEvent],
        to fileURL: URL,
        fileManager: FileManager
    ) throws {
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
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: fileURL, options: .atomic)
        }
    }
}
