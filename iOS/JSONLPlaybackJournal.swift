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
        pending.append(
            PlaybackJournalEvent(timestamp: date, kind: .played, path: relativePath, value: nil)
        )
    }

    func favoriteChanged(relativePath: String, value: Bool, at date: Date) {
        guard !relativePath.isEmpty else { return }
        pending.append(
            PlaybackJournalEvent(timestamp: date, kind: .favorite, path: relativePath, value: value)
        )
    }

    func flush() {
        guard !pending.isEmpty else { return }

        let events = pending
        pending.removeAll()

        do {
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
        } catch {
            pending.insert(contentsOf: events, at: 0)
            Logger.error("PlaybackJournal flush failed: \(error)")
        }
    }
}
