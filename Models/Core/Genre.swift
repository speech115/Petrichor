import Foundation
import GRDB

struct Genre: Identifiable, FetchableRecord, PersistableRecord {
    var id: Int64?
    let name: String

    // MARK: - Initialization

    init(name: String) {
        self.name = name
    }

    // MARK: - GRDB Configuration

    static let databaseTableName = "genres"

    enum Columns {
        static let id = Column("id")
        static let name = Column("name")
    }

    // MARK: - FetchableRecord

    init(row: Row) throws {
        id = row[Columns.id]
        name = row[Columns.name]
    }

    // MARK: - PersistableRecord

    func encode(to container: inout PersistenceContainer) throws {
        container[Columns.id] = id
        container[Columns.name] = name
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    // MARK: - Associations

    static let tracks = hasMany(Track.self, through: hasMany(TrackGenre.self), using: TrackGenre.track)

    var tracks: QueryInterfaceRequest<Track> {
        request(for: Genre.tracks)
    }
}

// MARK: - Equatable

extension Genre: Equatable {
    static func == (lhs: Genre, rhs: Genre) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Hashable

extension Genre: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
