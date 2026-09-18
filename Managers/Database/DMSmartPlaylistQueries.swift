//
//  DatabaseManager class extension
//  Petrichor
//
//  Smart playlist query builder for fetching tracks from database
//  based on Smart Playlist criteria
//

import Foundation
import GRDB

extension DatabaseManager {
    // MARK: - Smart Playlist Query Builder

    /// The filtered (not yet sorted or limited) track query for a smart playlist's criteria.
    /// Shared by the track-fetch and count paths so the filter logic lives in one place.
    func smartPlaylistFilteredQuery(
        _ criteria: SmartPlaylistCriteria
    ) -> QueryInterfaceRequest<Track> {
        var query = applyDuplicateFilter(Track.all())
        if let whereClause = buildWhereClause(for: criteria) {
            query = query.filter(whereClause)
        }
        return query
    }

    /// Count tracks matching a criteria (honoring its limit) within an already-open read.
    func countSmartPlaylistTracks(
        _ criteria: SmartPlaylistCriteria,
        db: Database
    ) throws -> Int {
        let query = smartPlaylistFilteredQuery(criteria)
        if let limit = criteria.limit {
            return try query.limit(limit).fetchCount(db)
        }
        return try query.fetchCount(db)
    }

    /// Count how many library tracks match a criteria's rules, ignoring any limit. Used by
    /// the editor's live "Matches N songs" footer to convey how selective the rules are
    /// (the limit is a separate, explicit cap). Opens its own read.
    func countMatchesForCriteria(_ criteria: SmartPlaylistCriteria) async -> Int {
        do {
            return try await dbQueue.read { db in
                return try self.smartPlaylistFilteredQuery(criteria).fetchCount(db)
            }
        } catch {
            Logger.error("Failed to count smart playlist matches: \(error)")
            return 0
        }
    }

    /// Build and run a smart playlist's full track query (filter, sort, limit, artwork) within
    /// an already-open read.
    private func fetchSmartPlaylistTracks(
        for criteria: SmartPlaylistCriteria,
        db: Database,
        populateArtwork: Bool = true
    ) throws -> [Track] {

        var query = smartPlaylistFilteredQuery(criteria)
        query = applySorting(to: query, criteria: criteria)
        if let limit = criteria.limit {
            query = query.limit(limit)
        }

        var tracks = try query.fetchAll(db)
        // List contexts pass `false` and fill thumbnails themselves
        // (populateAlbumArtworkThumbnailsForTracks).
        if populateArtwork {
            try populateAlbumArtworkForTracks(&tracks, db: db)
        }
        return tracks
    }

    /// Build and execute a database query for a smart playlist
    func getTracksForSmartPlaylist(
        _ playlist: Playlist,
        populateArtwork: Bool = true
    ) async throws -> [Track] {
        guard playlist.type == .smart,
              let criteria = playlist.smartCriteria else {
            return []
        }

        return try await dbQueue.read { db in
            try self.fetchSmartPlaylistTracks(for: criteria, db: db, populateArtwork: populateArtwork)
        }
    }

    /// Get tracks for a smart playlist synchronously (for use in pinned items)
    func getTracksForSmartPlaylistSync(_ playlist: Playlist, populateArtwork: Bool = true) -> [Track] {
        guard playlist.type == .smart,
              let criteria = playlist.smartCriteria else {
            return []
        }

        do {
            return try dbQueue.read { db in
                try self.fetchSmartPlaylistTracks(for: criteria, db: db, populateArtwork: populateArtwork)
            }
        } catch {
            Logger.error("Failed to get tracks for smart playlist '\(playlist.name)': \(error)")
            return []
        }
    }

    /// Build WHERE clause from smart playlist criteria
    internal func buildWhereClause(for criteria: SmartPlaylistCriteria) -> SQLExpression? {
        let expressions = criteria.rules.compactMap { rule in
            buildExpression(for: rule)
        }
        
        guard let first = expressions.first else { return nil }
        
        switch criteria.matchType {
        case .all:
            // AND all conditions together
            return expressions.dropFirst().reduce(first) { result, expr in
                result && expr
            }
        case .any:
            // OR all conditions together
            return expressions.dropFirst().reduce(first) { result, expr in
                result || expr
            }
        }
    }
    
    /// Build SQL expression for a single rule
    private func buildExpression(for rule: SmartPlaylistCriteria.Rule) -> SQLExpression? {
        if let affirmativeCondition = rule.condition.affirmativeTwin {
            let affirmativeRule = SmartPlaylistCriteria.Rule(
                field: rule.field,
                condition: affirmativeCondition,
                value: rule.value
            )
            guard let expression = buildExpression(for: affirmativeRule) else {
                return nil
            }
            // Unlike NOT, IS NOT 1 treats a NULL affirmative result as false and includes it.
            return SQL("(\(expression)) IS NOT 1").sqlExpression
        }

        switch rule.field {
        case "isFavorite":
            return buildBooleanExpression(column: Track.Columns.isFavorite, rule: rule)
            
        case "playCount":
            return buildNumericExpression(column: Track.Columns.playCount, rule: rule)
            
        case "lastPlayedDate":
            return buildDateExpression(column: Track.Columns.lastPlayedDate, rule: rule)
            
        case "dateAdded":
            return buildDateExpression(column: Track.Columns.dateAdded, rule: rule)
            
        case "title":
            return buildStringExpression(column: Track.Columns.title, rule: rule)
            
        case "artist":
            return buildStringExpression(column: Track.Columns.artist, rule: rule)
            
        case "album":
            return buildStringExpression(column: Track.Columns.album, rule: rule)
            
        case "albumArtist":
            return buildStringExpression(column: Track.Columns.albumArtist, rule: rule)
            
        case "genre":
            return buildStringExpression(column: Track.Columns.genre, rule: rule)
            
        case "year":
            return buildYearExpression(column: Track.Columns.year, rule: rule)
            
        case "composer":
            return buildStringExpression(column: Track.Columns.composer, rule: rule)

        case "duration":
            return buildNumericExpression(column: Track.Columns.duration, rule: rule)

        case "trackNumber":
            return buildNumericExpression(column: Track.Columns.trackNumber, rule: rule)

        case "discNumber":
            return buildNumericExpression(column: Track.Columns.discNumber, rule: rule)

        case "filename":
            // Matches against the full path (folder + filename + extension), not just the basename.
            return buildStringExpression(column: Track.Columns.path, rule: rule)

        default:
            Logger.warning("Unsupported smart playlist field: \(rule.field)")
            return nil
        }
    }
    
    // MARK: - Helper Methods
    
    /// Build LIKE pattern based on condition
    private func buildLikePattern(for value: String, condition: SmartPlaylistCriteria.Condition) -> String {
        switch condition {
        case .contains:
            return "%\(value)%"
        case .startsWith:
            return "\(value)%"
        case .endsWith:
            return "%\(value)"
        default:
            return "%\(value)%"
        }
    }
    
    // MARK: - Expression Builders
    
    private func buildBooleanExpression(column: Column, rule: SmartPlaylistCriteria.Rule) -> SQLExpression? {
        let value = rule.value.lowercased() == "true"
        
        switch rule.condition {
        case .equals:
            return column == value
        default:
            return nil
        }
    }
    
    private func buildStringExpression(column: Column, rule: SmartPlaylistCriteria.Rule) -> SQLExpression? {
        switch rule.condition {
        case .equals:
            // Case-insensitive exact match using COLLATE NOCASE
            return column.collating(.nocase) == rule.value
        case .contains, .startsWith, .endsWith:
            // Case-insensitive pattern matching
            let pattern = buildLikePattern(for: rule.value, condition: rule.condition)
            return column.collating(.nocase).like(pattern)
        case .regex:
            // SQLite calls regexp(pattern, value) for the `value REGEXP pattern` syntax.
            return SQL("\(column) REGEXP \(rule.value)").sqlExpression
        default:
            return nil
        }
    }
    
    private func buildNumericExpression(column: Column, rule: SmartPlaylistCriteria.Rule) -> SQLExpression? {
        guard let numericValue = Double(rule.value) else { return nil }

        switch rule.condition {
        case .equals:
            // Match the whole integer unit so a fractional-second duration still matches a
            // "M:SS" rule; for integer columns (play count, track/disc number) this is exact.
            return column >= numericValue && column < numericValue + 1
        case .greaterThan:
            return column > numericValue
        case .greaterThanOrEqual:
            return column >= numericValue
        case .lessThan:
            return column < numericValue
        case .lessThanOrEqual:
            return column <= numericValue
        default:
            return nil
        }
    }
    
    private func buildDateExpression(column: Column, rule: SmartPlaylistCriteria.Rule) -> SQLExpression? {
        // Handle "Xdays" format for relative dates
        if rule.value.hasSuffix("days") {
            let daysString = rule.value.replacingOccurrences(of: "days", with: "")
            guard let days = Int(daysString) else { return nil }
            
            let cutoffDate = Date().addingTimeInterval(-Double(days) * 24 * 60 * 60)
            
            switch rule.condition {
            case .greaterThan:
                // For "in the last X days", we want dates greater than the cutoff
                return column != nil && column > cutoffDate
            case .lessThan:
                return column != nil && column < cutoffDate
            default:
                return nil
            }
        }
        
        // Handle absolute calendar dates ("yyyy-MM-dd"), matching by day in the local
        // calendar so the stored time-of-day is ignored.
        if let day = SmartPlaylistDate.date(from: rule.value) {
            let calendar = Calendar.current
            let startOfDay = calendar.startOfDay(for: day)
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else { return nil }

            switch rule.condition {
            case .equals:
                // "on" that day
                return column != nil && column >= startOfDay && column < nextDay
            case .greaterThan:
                // "after" that day (strictly later than the whole day)
                return column != nil && column >= nextDay
            case .lessThan:
                // "before" the start of that day
                return column != nil && column < startOfDay
            default:
                return nil
            }
        }

        return nil
    }
    
    private func buildYearExpression(column: Column, rule: SmartPlaylistCriteria.Rule) -> SQLExpression? {
        // Year is stored as text. Exact match is a plain string compare, but greater/less
        // must compare numerically: a lexicographic compare would match non-numeric years
        // like "Unknown Year" (which sorts after digits). CAST makes the compare numeric and
        // turns non-numeric years into 0, which we exclude.
        switch rule.condition {
        case .equals:
            return column == rule.value
        case .greaterThan, .lessThan:
            guard let yearValue = Int(rule.value) else { return nil }
            let numericYear = cast(column, as: .integer)
            if rule.condition == .greaterThan {
                return numericYear > yearValue
            } else {
                return numericYear > 0 && numericYear < yearValue
            }
        default:
            return buildStringExpression(column: column, rule: rule)
        }
    }
    
    // MARK: - Sorting
    
    private func applySorting(to query: QueryInterfaceRequest<Track>, criteria: SmartPlaylistCriteria) -> QueryInterfaceRequest<Track> {
        guard let sortBy = criteria.sortBy else { return query }
        
        let columns: [String: Column] = [
            "title": Track.Columns.title, "artist": Track.Columns.artist,
            "album": Track.Columns.album, "playCount": Track.Columns.playCount,
            "dateAdded": Track.Columns.dateAdded, "duration": Track.Columns.duration,
            "year": Track.Columns.year, "genre": Track.Columns.genre,
            "trackNumber": Track.Columns.trackNumber, "discNumber": Track.Columns.discNumber,
            "filename": Track.Columns.path
        ]
        let expression: SQLExpression
        switch sortBy {
        case "lastPlayedDate":
            let nilDate = criteria.sortAscending ? Date.distantPast : Date.distantFuture
            expression = Track.Columns.lastPlayedDate ?? nilDate
        case "dateFavorited":
            expression = Track.Columns.dateFavorited ?? Date.distantPast
        default:
            guard let column = columns[sortBy] else { return query }
            expression = column.sqlExpression
        }
        return query.order(criteria.sortAscending ? expression.asc : expression.desc)
    }
}
