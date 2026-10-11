// Library query policy is the platform seam: Rust builds macOS queries; GRDB encodes dates.
import Foundation
import GRDB
#if os(macOS)
import PetrichorCore
#endif

enum LibraryQueryPolicy {
#if os(macOS)
    static func buildFTS5Query(_ searchText: String) -> String {
        libraryFtsQuery(text: searchText)
    }

    static func buildWhereClause(for criteria: SmartPlaylistCriteria) -> SQLExpression? {
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
        let fragment = librarySmartFilter(rules: rules, matchAll: criteria.matchType == .all)
        guard !fragment.sql.isEmpty else { return nil }
        return SQL(sql: fragment.sql, arguments: arguments(fragment)).sqlExpression
    }

    static func applySorting(to query: QueryInterfaceRequest<Track>, criteria: SmartPlaylistCriteria) -> QueryInterfaceRequest<Track> {
        guard let sortBy = criteria.sortBy else { return query }
        let fragment = librarySmartSort(
            field: sortBy,
            ascending: criteria.sortAscending,
            distantPast: Date.distantPast.timeIntervalSince1970,
            distantFuture: Date.distantFuture.timeIntervalSince1970
        )
        guard !fragment.sql.isEmpty else { return query }
        return query.order(SQL(sql: fragment.sql, arguments: arguments(fragment)).sqlOrdering)
    }

    private static func arguments(_ fragment: QueryFragment) -> StatementArguments {
        StatementArguments(fragment.arguments.map { argument -> DatabaseValue in
            switch argument {
            case .text(let value): return value.databaseValue
            case .number(let value): return value.databaseValue
            case .integer(let value): return value.databaseValue
            case .date(let timestamp): return Date(timeIntervalSince1970: timestamp).databaseValue
            }
        })
    }
#else
    /// FTS query builder with support for handling special characters
    static func buildFTS5Query(_ searchText: String) -> String {
        let tokens = searchText.split(separator: " ").map { String($0) }
        
        let processedTokens = tokens.map { token -> String in
            let tokenStr = String(token)
            
            let problematicChars = CharacterSet(charactersIn: "\"*^:()[]{}~-")
            
            if tokenStr.rangeOfCharacter(from: problematicChars) != nil {
                let escaped = tokenStr.replacingOccurrences(of: "\"", with: "\"\"")
                return "\"\(escaped)\""
            } else if tokenStr.contains(".") {
                let escaped = tokenStr.replacingOccurrences(of: "\"", with: "\"\"")
                return "\"\(escaped)\" OR \"\(escaped)\"*"
            } else {
                return "\(tokenStr)*"
            }
        }
        
        return processedTokens.joined(separator: " AND ")
    }
    
    /// Build WHERE clause from smart playlist criteria
    static func buildWhereClause(for criteria: SmartPlaylistCriteria) -> SQLExpression? {
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
    private static func buildExpression(for rule: SmartPlaylistCriteria.Rule) -> SQLExpression? {
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
    private static func buildLikePattern(for value: String, condition: SmartPlaylistCriteria.Condition) -> String {
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
    
    private static func buildBooleanExpression(column: Column, rule: SmartPlaylistCriteria.Rule) -> SQLExpression? {
        let value = rule.value.lowercased() == "true"
        
        switch rule.condition {
        case .equals:
            return column == value
        default:
            return nil
        }
    }
    
    private static func buildStringExpression(column: Column, rule: SmartPlaylistCriteria.Rule) -> SQLExpression? {
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
    
    private static func buildNumericExpression(column: Column, rule: SmartPlaylistCriteria.Rule) -> SQLExpression? {
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
    
    private static func buildDateExpression(column: Column, rule: SmartPlaylistCriteria.Rule) -> SQLExpression? {
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
    
    private static func buildYearExpression(column: Column, rule: SmartPlaylistCriteria.Rule) -> SQLExpression? {
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
    
    static func applySorting(to query: QueryInterfaceRequest<Track>, criteria: SmartPlaylistCriteria) -> QueryInterfaceRequest<Track> {
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
#endif
}
