import Foundation
import GRDB

struct TrackArtist: FetchableRecord, PersistableRecord {
    let trackId: Int64
    let artistId: Int64
    let role: String // 'artist', 'composer', 'album_artist'
    let position: Int

    // MARK: - Initialization

    init(trackId: Int64, artistId: Int64, role: String = "artist", position: Int = 0) {
        self.trackId = trackId
        self.artistId = artistId
        self.role = role
        self.position = position
    }

    // MARK: - GRDB Configuration

    static let databaseTableName = "track_artists"

    enum Columns {
        static let trackId = Column("track_id")
        static let artistId = Column("artist_id")
        static let role = Column("role")
        static let position = Column("position")
    }

    // MARK: - FetchableRecord

    init(row: Row) throws {
        trackId = row[Columns.trackId]
        artistId = row[Columns.artistId]
        role = row[Columns.role]
        position = row[Columns.position]
    }

    // MARK: - PersistableRecord

    func encode(to container: inout PersistenceContainer) throws {
        container[Columns.trackId] = trackId
        container[Columns.artistId] = artistId
        container[Columns.role] = role
        container[Columns.position] = position
    }

    // MARK: - Associations

    static let track = belongsTo(Track.self, using: ForeignKey(["track_id"]))
    static let artist = belongsTo(Artist.self, using: ForeignKey(["artist_id"]))
}

// MARK: - Role Constants

extension TrackArtist {
    enum Role {
        static let artist = "artist"
        static let composer = "composer"
        static let albumArtist = "album_artist"
    }
}
