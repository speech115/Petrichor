import Foundation

enum SpecialTableColumn: String, Codable {
    case title
    case duration
    case trackNumber

    var displayName: String {
        switch self {
        case .title: return String(localized: "Title")
        case .duration: return String(localized: "Duration")
        case .trackNumber: return String(localized: "Track number")
        }
    }
}

enum TrackTableColumn: Codable, Hashable {
    case special(SpecialTableColumn)
    case libraryFilter(LibraryFilterType)

    // All available columns in order
    static var allColumns: [TrackTableColumn] {
        var columns: [TrackTableColumn] = [.special(.title), .special(.trackNumber)]

        // Add all LibraryFilterType columns
        for filterType in LibraryFilterType.allCases {
            columns.append(.libraryFilter(filterType))
        }

        columns.append(.special(.duration))
        return columns
    }

    var displayName: String {
        switch self {
        case .special(let specialColumn):
            return specialColumn.displayName
        case .libraryFilter(let filterType):
            return filterType.singularDisplayName
        }
    }

    var identifier: String {
        switch self {
        case .special(let specialColumn):
            return specialColumn.rawValue
        case .libraryFilter(let filterType):
            return filterType.rawValue
        }
    }

    var isRequired: Bool {
        switch self {
        case .special(.title):
            return true
        default:
            return false
        }
    }

    var defaultVisibility: Bool {
        switch self {
        case .special(.title), .special(.duration):
            return true
        case .special(.trackNumber):
            return false
        case .libraryFilter(let filterType):
            switch filterType {
            case .artists, .albums:
                return true
            default:
                return false
            }
        }
    }

    // Codable implementation
    enum CodingKeys: String, CodingKey {
        case type
        case value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .special(let specialColumn):
            try container.encode("special", forKey: .type)
            try container.encode(specialColumn.rawValue, forKey: .value)
        case .libraryFilter(let filterType):
            try container.encode("filter", forKey: .type)
            try container.encode(filterType.rawValue, forKey: .value)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "special":
            let value = try container.decode(String.self, forKey: .value)
            guard let specialColumn = SpecialTableColumn(rawValue: value) else {
                throw DecodingError.dataCorruptedError(forKey: .value, in: container, debugDescription: "Invalid special column")
            }
            self = .special(specialColumn)
        case "filter":
            let value = try container.decode(String.self, forKey: .value)
            guard let filterType = LibraryFilterType(rawValue: value) else {
                throw DecodingError.dataCorruptedError(forKey: .value, in: container, debugDescription: "Invalid filter type")
            }
            self = .libraryFilter(filterType)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Invalid column type")
        }
    }
}
