//
// PlaybackJournalApplier
//
// Applies the other device's journal (`PlaybackJournalFiles.inbox`): match
// events to library rows by path suffix, mutate play counts / favorites, and
// advance the cursor in the same DB write so a re-import is a no-op.
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
            // Runs on every foregrounding; without new events skip reading the library.
            guard events.contains(where: { event in cursor.map { event.timestamp > $0 } ?? true }) else {
                return Summary(applied: 0, skipped: 0, cursor: cursor)
            }

            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, path, play_count, is_favorite, date_favorited, last_played_date FROM tracks"
            )
            let ids: [Int64] = rows.map { $0["id"] }
            let before = rows.map { row in
                PlaybackJournalTrackState(
                    path: row["path"],
                    playCount: row["play_count"],
                    isFavorite: row["is_favorite"],
                    dateFavorited: row["date_favorited"],
                    lastPlayedDate: row["last_played_date"]
                )
            }

            var states = before
            let result = PlaybackJournalApply.apply(events: events, to: &states, cursor: cursor)

            for index in states.indices where states[index] != before[index] {
                let state = states[index]
                try Track
                    .filter(Track.Columns.trackId == ids[index])
                    .updateAll(db, [
                        Track.Columns.playCount.set(to: state.playCount),
                        Track.Columns.isFavorite.set(to: state.isFavorite),
                        Track.Columns.dateFavorited.set(to: state.dateFavorited),
                        Track.Columns.lastPlayedDate.set(to: state.lastPlayedDate),
                    ])
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
