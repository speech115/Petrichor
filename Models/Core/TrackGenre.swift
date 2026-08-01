import Foundation
import GRDB

struct TrackGenre: FetchableRecord, PersistableRecord {
    let trackId: Int64
    let genreId: Int64

    // MARK: - Initialization

    init(trackId: Int64, genreId: Int64) {
        self.trackId = trackId
        self.genreId = genreId
    }

    // MARK: - GRDB Configuration

    static let databaseTableName = "track_genres"

    enum Columns {
        static let trackId = Column("track_id")
        static let genreId = Column("genre_id")
    }

    // MARK: - FetchableRecord

    init(row: Row) throws {
        trackId = row[Columns.trackId]
        genreId = row[Columns.genreId]
    }

    // MARK: - PersistableRecord

    func encode(to container: inout PersistenceContainer) throws {
        container[Columns.trackId] = trackId
        container[Columns.genreId] = genreId
    }

    // MARK: - Associations

    static let track = belongsTo(Track.self, using: ForeignKey(["track_id"]))
    static let genre = belongsTo(Genre.self, using: ForeignKey(["genre_id"]))
}
