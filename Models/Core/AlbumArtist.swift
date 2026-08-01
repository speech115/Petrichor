import Foundation
import GRDB

struct AlbumArtist: FetchableRecord, PersistableRecord {
    let albumId: Int64
    let artistId: Int64
    let role: String
    let position: Int

    // MARK: - Initialization

    init(albumId: Int64, artistId: Int64, role: String = "primary", position: Int = 0) {
        self.albumId = albumId
        self.artistId = artistId
        self.role = role
        self.position = position
    }

    // MARK: - GRDB Configuration

    static let databaseTableName = "album_artists"

    enum Columns {
        static let albumId = Column("album_id")
        static let artistId = Column("artist_id")
        static let role = Column("role")
        static let position = Column("position")
    }

    // MARK: - FetchableRecord

    init(row: Row) throws {
        albumId = row[Columns.albumId]
        artistId = row[Columns.artistId]
        role = row[Columns.role]
        position = row[Columns.position]
    }

    // MARK: - PersistableRecord

    func encode(to container: inout PersistenceContainer) throws {
        container[Columns.albumId] = albumId
        container[Columns.artistId] = artistId
        container[Columns.role] = role
        container[Columns.position] = position
    }

    // MARK: - Associations

    static let album = belongsTo(Album.self, using: ForeignKey(["album_id"]))
    static let artist = belongsTo(Artist.self, using: ForeignKey(["artist_id"]))
}

// MARK: - Role Constants

extension AlbumArtist {
    enum Role {
        static let primary = "primary"
        static let featured = "featured"
        static let various = "various"
    }
}
