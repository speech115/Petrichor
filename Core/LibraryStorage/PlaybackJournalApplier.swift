import Foundation
import PetrichorCore

enum PlaybackJournalApplier {
    typealias Summary = PlaybackJournalApplyResult

    static func apply(fileURL: URL, databaseManager: DatabaseManager) throws -> Summary {
        let events = try PlaybackJournalCodec.decodeLines(String(contentsOf: fileURL, encoding: .utf8))
        let inputs = events.map { event -> DatabaseJournalEvent in
            let favorite: Bool?
            switch event {
            case .played: favorite = nil
            case .favorite(_, let value, _): favorite = value
            }
            return DatabaseJournalEvent(
                path: event.path, timestamp: event.timestamp.timeIntervalSince1970, favorite: favorite
            )
        }
        let result = try databaseManager.core.applyPlaybackJournal(
            events: inputs, now: Date().timeIntervalSince1970
        )
        return Summary(
            applied: Int(result.applied), skipped: Int(result.skipped),
            cursor: result.cursor.map(Date.init(timeIntervalSince1970:))
        )
    }
}
