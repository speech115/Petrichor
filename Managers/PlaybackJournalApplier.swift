//
// PlaybackJournalApplier
//
// macOS side of the PlaybackJournal seam: read a transferred JSONL file,
// match events to library rows by path suffix, mutate play counts / favorites,
// and advance the cursor in the same DB write so a re-import is a no-op.
//

import Foundation
import GRDB

enum PlaybackJournalApplier {
    typealias Summary = PlaybackJournalApplyResult

    /// Applies journal events from `fileURL` against `databaseManager`.
    /// Cursor and track mutations share one write transaction.
    static func apply(
        fileURL: URL,
        databaseManager: DatabaseManager
    ) throws -> Summary {
        let events = try PlaybackJournalCodec.decodeLines(
            String(contentsOf: fileURL, encoding: .utf8)
        )

        return try databaseManager.dbQueue.write { db in
            let cursor = try Date.fetchOne(
                db,
                sql: "SELECT applied_through FROM playback_journal_cursor WHERE singleton = 1"
            )

            let rows: [(id: Int64, state: PlaybackJournalTrackState)] = try Track.fetchAll(db).compactMap { track in
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

            var states = rows.map(\.state)
            let result = PlaybackJournalApply.apply(events: events, to: &states, cursor: cursor)

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

            if let newCursor = result.cursor {
                try db.execute(
                    sql: """
                    INSERT INTO playback_journal_cursor (singleton, applied_through) VALUES (1, ?)
                    ON CONFLICT(singleton) DO UPDATE SET applied_through = excluded.applied_through
                    """,
                    arguments: [newCursor]
                )
            }

            return result
        }
    }
}
