import Foundation
import PetrichorCore

extension DatabaseManager {
    func databaseSmartCriteria(_ criteria: SmartPlaylistCriteria) -> DatabaseSmartCriteria {
        let rules = criteria.rules.map { rule -> QueryRule in
            var start: Date?
            var end: Date?
            let relative = rule.value.hasSuffix("days")
            if rule.field == "dateAdded" || rule.field == "lastPlayedDate" {
                if relative, let days = Int(rule.value.replacingOccurrences(of: "days", with: "")) {
                    start = Date().addingTimeInterval(-Double(days) * 24 * 60 * 60)
                } else if let day = SmartPlaylistDate.date(from: rule.value) {
                    start = Calendar.current.startOfDay(for: day)
                    if let start { end = Calendar.current.date(byAdding: .day, value: 1, to: start) }
                }
            }
            return QueryRule(
                field: rule.field,
                condition: rule.condition.rawValue,
                value: rule.value,
                dateStart: start?.timeIntervalSince1970,
                dateEnd: end?.timeIntervalSince1970,
                relativeDate: relative,
                numericValue: Double(rule.value),
                integerValue: Int64(rule.value)
            )
        }
        return DatabaseSmartCriteria(
            rules: rules,
            matchAll: criteria.matchType == .all,
            sortBy: criteria.sortBy,
            ascending: criteria.sortAscending,
            limit: criteria.limit.map(Int64.init),
            distantPast: Date.distantPast.timeIntervalSince1970,
            distantFuture: Date.distantFuture.timeIntervalSince1970
        )
    }

    func countMatchesForCriteria(_ criteria: SmartPlaylistCriteria) async -> Int {
        let converted = databaseSmartCriteria(criteria)
        let hide = hideDuplicateTracks
        return await Task.detached {
            do { return Int(try self.core.smartCount(criteria: converted, hideDuplicates: hide, honorLimit: false)) } catch {
                Logger.error("Failed to count smart playlist matches: \(error)")
                return 0
            }
        }.value
    }

    func getTracksForSmartPlaylist(_ playlist: Playlist, populateArtwork: Bool = true) async throws -> [Track] {
        guard playlist.type == .smart, let criteria = playlist.smartCriteria else { return [] }
        let converted = databaseSmartCriteria(criteria)
        let hide = hideDuplicateTracks
        return try await Task.detached {
            try self.tracks(self.core.smartTracks(criteria: converted, hideDuplicates: hide, artwork: populateArtwork))
        }.value
    }

    func getTracksForSmartPlaylistSync(_ playlist: Playlist, populateArtwork: Bool = true) -> [Track] {
        guard playlist.type == .smart, let criteria = playlist.smartCriteria else { return [] }
        do {
            return try tracks(core.smartTracks(
                criteria: databaseSmartCriteria(criteria),
                hideDuplicates: hideDuplicateTracks,
                artwork: populateArtwork
            ))
        } catch {
            Logger.error("Failed to get tracks for smart playlist '\(playlist.name)': \(error)")
            return []
        }
    }
}
