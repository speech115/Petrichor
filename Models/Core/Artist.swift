import Foundation
import GRDB

class Artist: Identifiable, ObservableObject, FetchableRecord, PersistableRecord {
    var id: Int64?
    let name: String
    let normalizedName: String
    var sortName: String?
    var artworkData: Data?

    // External API metadata
    @Published var bio: String?
    var bioSource: String?
    var bioUpdatedAt: Date?

    @Published var imageUrl: String?
    var imageSource: String?
    var imageUpdatedAt: Date?

    // External identifiers
    var discogsId: String?
    var musicbrainzId: String?
    var spotifyId: String?
    var appleMusicId: String?

    // Additional metadata
    var country: String?
    var formedYear: Int?
    var disbandedYear: Int?
    var genres: [String]?
    var websites: [String]?
    var members: [String]?

    // Stats
    @Published var totalTracks: Int = 0
    @Published var totalAlbums: Int = 0

    // Timestamps
    var createdAt: Date?
    var updatedAt: Date?

    // MARK: - Initialization

    init(name: String) {
        self.name = name
        self.normalizedName = ArtistParser.normalizeArtistName(name)
        self.sortName = name
    }

    // MARK: - GRDB Configuration

    static let databaseTableName = "artists"

    enum Columns {
        static let id = Column("id")
        static let name = Column("name")
        static let normalizedName = Column("normalized_name")
        static let sortName = Column("sort_name")
        static let artworkData = Column("artwork_data")
        static let bio = Column("bio")
        static let bioSource = Column("bio_source")
        static let bioUpdatedAt = Column("bio_updated_at")
        static let imageUrl = Column("image_url")
        static let imageSource = Column("image_source")
        static let imageUpdatedAt = Column("image_updated_at")
        static let discogsId = Column("discogs_id")
        static let musicbrainzId = Column("musicbrainz_id")
        static let spotifyId = Column("spotify_id")
        static let appleMusicId = Column("apple_music_id")
        static let country = Column("country")
        static let formedYear = Column("formed_year")
        static let disbandedYear = Column("disbanded_year")
        static let genres = Column("genres")
        static let websites = Column("websites")
        static let members = Column("members")
        static let totalTracks = Column("total_tracks")
        static let totalAlbums = Column("total_albums")
        static let createdAt = Column("created_at")
        static let updatedAt = Column("updated_at")
    }

    // MARK: - FetchableRecord

    required init(row: Row) throws {
        id = row[Columns.id]
        name = row[Columns.name]
        normalizedName = row[Columns.normalizedName]
        sortName = row[Columns.sortName]
        artworkData = row[Columns.artworkData]
        bio = row[Columns.bio]
        bioSource = row[Columns.bioSource]
        bioUpdatedAt = row[Columns.bioUpdatedAt]
        imageUrl = row[Columns.imageUrl]
        imageSource = row[Columns.imageSource]
        imageUpdatedAt = row[Columns.imageUpdatedAt]
        discogsId = row[Columns.discogsId]
        musicbrainzId = row[Columns.musicbrainzId]
        spotifyId = row[Columns.spotifyId]
        appleMusicId = row[Columns.appleMusicId]
        country = row[Columns.country]
        formedYear = row[Columns.formedYear]
        disbandedYear = row[Columns.disbandedYear]

        // Decode JSON arrays
        if let genresJSON: String = row[Columns.genres],
           let data = genresJSON.data(using: .utf8) {
            genres = try? JSONDecoder().decode([String].self, from: data)
        }

        if let websitesJSON: String = row[Columns.websites],
           let data = websitesJSON.data(using: .utf8) {
            websites = try? JSONDecoder().decode([String].self, from: data)
        }

        if let membersJSON: String = row[Columns.members],
           let data = membersJSON.data(using: .utf8) {
            members = try? JSONDecoder().decode([String].self, from: data)
        }

        totalTracks = row[Columns.totalTracks]
        totalAlbums = row[Columns.totalAlbums]
        createdAt = row[Columns.createdAt]
        updatedAt = row[Columns.updatedAt]
    }

    // MARK: - PersistableRecord

    func encode(to container: inout PersistenceContainer) throws {
        container[Columns.id] = id
        container[Columns.name] = name
        container[Columns.normalizedName] = normalizedName
        container[Columns.sortName] = sortName
        container[Columns.artworkData] = artworkData
        container[Columns.bio] = bio
        container[Columns.bioSource] = bioSource
        container[Columns.bioUpdatedAt] = bioUpdatedAt
        container[Columns.imageUrl] = imageUrl
        container[Columns.imageSource] = imageSource
        container[Columns.imageUpdatedAt] = imageUpdatedAt
        container[Columns.discogsId] = discogsId
        container[Columns.musicbrainzId] = musicbrainzId
        container[Columns.spotifyId] = spotifyId
        container[Columns.appleMusicId] = appleMusicId
        container[Columns.country] = country
        container[Columns.formedYear] = formedYear
        container[Columns.disbandedYear] = disbandedYear

        // Encode JSON arrays
        if let genres = genres {
            container[Columns.genres] = try? JSONEncoder().encode(genres).utf8String
        }

        if let websites = websites {
            container[Columns.websites] = try? JSONEncoder().encode(websites).utf8String
        }

        if let members = members {
            container[Columns.members] = try? JSONEncoder().encode(members).utf8String
        }

        container[Columns.totalTracks] = totalTracks
        container[Columns.totalAlbums] = totalAlbums
        container[Columns.createdAt] = createdAt ?? Date()
        container[Columns.updatedAt] = Date()
    }

    func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    // MARK: - Associations

    static let tracks = hasMany(TrackArtist.self)
    static let albums = hasMany(Album.self)
}

// MARK: - Equatable

extension Artist: Equatable {
    static func == (lhs: Artist, rhs: Artist) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Hashable

extension Artist: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Data Extension

extension Data {
    var utf8String: String? {
        String(data: self, encoding: .utf8)
    }
}
