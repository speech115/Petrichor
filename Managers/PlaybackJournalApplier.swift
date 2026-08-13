//
// PlaybackJournalApplier
//
// macOS side of the PlaybackJournal seam: read a transferred JSONL file,
// match events to library rows by path suffix, mutate play counts / favorites,
// and advance the UserDefaults cursor so a re-import is a no-op.
//

import Foundation
import GRDB

enum PlaybackJournalApplier {
    typealias Summary = PlaybackJournalApplyResult

    /// Applies journal events from `fileURL` against `databaseManager`.
    /// Cursor state lives in `defaults` so tests can inject an isolated suite.
    static func apply(
        fileURL: URL,
        databaseManager: DatabaseManager,
        defaults: UserDefaults = .standard
    ) throws -> Summary {
        let events = try PlaybackJournalCodec.decodeLines(
            String(contentsOf: fileURL, encoding: .utf8)
        )
        let cursor = PlaybackJournalCursorStore.load(from: defaults)

        let rows: [(id: Int64, state: PlaybackJournalTrackState)] = try databaseManager.dbQueue.read { db in
            try Track.fetchAll(db).compactMap { track in
                guard let id = track.trackId else { return nil }
                return (
                    id,
                    PlaybackJournalTrackState(
                        path: LibraryPathStore.storedPath(for: track.url),
                        playCount: track.playCount,
                        isFavorite: track.isFavorite,
                        lastPlayedDate: track.lastPlayedDate
                    )
                )
            }
        }

        var states = rows.map(\.state)
        let result = PlaybackJournalApply.apply(events: events, to: &states, cursor: cursor)

        try databaseManager.dbQueue.write { db in
            for index in states.indices where states[index] != rows[index].state {
                let state = states[index]
                let id = rows[index].id
                try Track
                    .filter(Track.Columns.trackId == id)
                    .updateAll(
                        db,
                        Track.Columns.playCount.set(to: state.playCount),
                        Track.Columns.isFavorite.set(to: state.isFavorite),
                        Track.Columns.lastPlayedDate.set(to: state.lastPlayedDate)
                    )
            }
        }

        if let newCursor = result.cursor {
            PlaybackJournalCursorStore.save(newCursor, to: defaults)
        }

        return result
    }
}
