import Foundation
import GRDB
import PetrichorCore

extension DatabaseManager {
    var hideDuplicateTracks: Bool { UserDefaults.standard.bool(forKey: "hideDuplicateTracks") }

    func databaseDate(_ cell: DatabaseCell?) -> Date? {
        Track.databaseDate(cell)
    }

    func tracks(_ result: DatabaseTrackRows) throws -> [Track] {
        var tracks = try result.tracks.map(Track.init(storageProjection:))
        guard !result.artworks.isEmpty else { return tracks }
        let (artworkByAlbum, artworkByTrack) = artworkMaps(result.artworks)
        for index in tracks.indices {
            if let id = tracks[index].albumId, let data = artworkByAlbum[id] {
                tracks[index].albumArtworkData = data
            } else if let id = tracks[index].trackId, let data = artworkByTrack[id] {
                tracks[index].albumArtworkData = data
            }
        }
        return tracks
    }

    private func artworkMaps(_ artworks: [DatabaseArtwork]) -> (album: [Int64: Data], track: [Int64: Data]) {
        var artworkByAlbum: [Int64: Data] = [:]
        var artworkByTrack: [Int64: Data] = [:]
        for artwork in artworks {
            if artwork.album { artworkByAlbum[artwork.id] = artwork.bytes.data } else { artworkByTrack[artwork.id] = artwork.bytes.data }
        }
        return (artworkByAlbum, artworkByTrack)
    }

    private func readTracks(_ operation: () throws -> DatabaseTrackRows) -> [Track] {
        do { return try tracks(operation()) } catch {
            Logger.error("Failed to read library tracks: \(error)")
            return []
        }
    }

    func populateAlbumArtworkForTracks(_ tracks: inout [Track]) {
        do {
            let fallbackTracks = tracks.filter { $0.albumArtworkData == nil && $0.trackId != nil }
            let (artworkByAlbum, artworkByTrack) = try artworkMaps(core.artworkBatch(
                albumIds: tracks.compactMap(\.albumId).removingDuplicates(),
                trackIds: fallbackTracks.compactMap(\.trackId),
                trackAlbumIds: fallbackTracks.map(\.albumId)
            ))
            for index in tracks.indices {
                if let id = tracks[index].albumId, let data = artworkByAlbum[id] {
                    tracks[index].albumArtworkData = data
                } else if tracks[index].albumArtworkData == nil,
                          let id = tracks[index].trackId, let data = artworkByTrack[id] {
                    tracks[index].albumArtworkData = data
                }
            }
        } catch { Logger.error("Failed to populate album artwork: \(error)") }
    }

    func populateAlbumArtworkThumbnailsForTracks(_ tracks: inout [Track], limit: Int? = nil) {
        var seen = Set<Int64>()
        var ids: [Int64] = []
        let headroom = limit.map { max($0 * 4, $0) }
        for track in tracks {
            if let headroom, ids.count >= headroom { break }
            if let id = track.albumId, seen.insert(id).inserted { ids.append(id) }
        }
        guard !ids.isEmpty else { return }
        do {
            let thumbnails = try artworkMaps(core.albumArtworks(ids: ids, thumbnail: true)).album
            var filled = 0
            for index in tracks.indices {
                if let limit, filled >= limit { break }
                if let id = tracks[index].albumId, let data = thumbnails[id] {
                    tracks[index].albumArtworkThumbnail = data
                    filled += 1
                }
            }
        } catch { Logger.error("Failed to populate album artwork thumbnails: \(error)") }
    }

    func getArtworkData(albumId: Int64?, trackId: Int64?) -> Data? {
        do { return try core.artwork(albumId: albumId, trackId: trackId) } catch {
            Logger.error("Failed to fetch artwork: \(error)")
            return nil
        }
    }

    func getAlbumArtworkThumbnail(albumId: Int64) -> Data? {
        do { return try core.albumThumbnail(id: albumId) } catch {
            Logger.error("Failed to fetch album thumbnail: \(error)")
            return nil
        }
    }

    func getArtistArtworkThumbnail(name: String) -> Data? {
        do {
            return try core.artistThumbnail(name: name, requiresFetchedImage: ArtistBioManager.shared.isArtistInfoFetchEnabled)
        } catch {
            Logger.error("Failed to fetch artist thumbnail: \(error)")
            return nil
        }
    }

    func populateAlbumArtworkForFullTrack(_ track: inout FullTrack) {
        guard let id = track.albumId else { return }
        if let data = getArtworkData(albumId: id, trackId: nil) { track.albumArtworkData = data }
    }

    func fullTrack(trackId: Int64) async throws -> FullTrack? {
        try await Task.detached { try self.records(self.core.fullTrack(id: trackId), as: FullTrack.self).first }.value
    }

    func getDiscoverTracks(limit: Int = 50, excluding previousIds: [Int64] = [], populateArtwork: Bool = true) -> [Track] {
        readTracks { try core.discoverTracks(limit: Int64(limit), excludedIds: previousIds, artwork: populateArtwork) }
    }

    func getTracks(byIds trackIds: [Int64]) -> [Track] {
        readTracks { try core.tracksByIds(ids: trackIds, artwork: false) }
    }

    func getTracksWithArtwork(byIds trackIds: [Int64]) -> [Track] {
        var tracks = readTracks { try core.tracksByIds(ids: trackIds, artwork: true) }
        let positions = Dictionary(trackIds.enumerated().map { ($1, $0) }) { first, _ in first }
        tracks.sort { (positions[$0.trackId ?? -1] ?? .max) < (positions[$1.trackId ?? -1] ?? .max) }
        return tracks
    }

    private func statistic<T: DatabaseValueConvertible>(_ kind: DatabaseStatistic, default value: T) -> T {
        do { return try rows(core.libraryStatistic(kind: kind, hideDuplicates: hideDuplicateTracks)).first?["value"] ?? value } catch {
            Logger.error("Failed to read library statistic: \(error)")
            return value
        }
    }

    func getTotalTrackCount() -> Int { statistic(.trackCount, default: 0) }
    func getTotalDuration() -> Double { statistic(.duration, default: 0.0) }
    func getTotalFileSize() -> Int64 { statistic(.fileSize, default: Int64(0)) }
    func getArtistCount() -> Int { statistic(.artistCount, default: 0) }
    func getAlbumCount() -> Int { statistic(.albumCount, default: 0) }

    func databaseFilter(_ type: LibraryFilterType) -> DatabaseFilter {
        switch type {
        case .artists: .artists
        case .albumArtists: .albumArtists
        case .composers: .composers
        case .albums: .albums
        case .genres: .genres
        case .years: .years
        case .decades: .decades
        }
    }

    func getTracksByFilterType(_ filterType: LibraryFilterType, value: String, albumId: Int64? = nil, populateArtwork: Bool = true) -> [Track] {
        readTracks {
            try core.tracksForFilter(
                kind: databaseFilter(filterType),
                value: value,
                normalizedName: ArtistParser.normalizeArtistName(value),
                albumId: albumId,
                hideDuplicates: hideDuplicateTracks,
                roleOnly: false,
                artwork: populateArtwork
            )
        }.sorted { $0.title < $1.title }
    }

    func getTracksByFilterTypeContaining(_ filterType: LibraryFilterType, value: String) -> [Track] {
        guard filterType.usesMultiArtistParsing else { return getTracksByFilterType(filterType, value: value) }
        return readTracks {
            try core.tracksForFilter(
                kind: databaseFilter(filterType),
                value: value,
                normalizedName: ArtistParser.normalizeArtistName(value),
                albumId: nil,
                hideDuplicates: hideDuplicateTracks,
                roleOnly: true,
                artwork: false
            )
        }
    }

    func getTracksForArtistEntity(_ artistName: String, populateArtwork: Bool = true) -> [Track] {
        var tracks = readTracks {
            try core.tracksForArtist(
                name: artistName,
                normalizedName: ArtistParser.normalizeArtistName(artistName),
                hideDuplicates: hideDuplicateTracks,
                artwork: false
            )
        }
        if populateArtwork { populateAlbumArtworkForTracks(&tracks) }
        return tracks
    }

    func getTracksForAlbumEntity(_ albumEntity: AlbumEntity, populateArtwork: Bool = true) -> [Track] {
        var tracks = readTracks {
            try core.tracksForAlbum(
                id: albumEntity.albumId,
                title: albumEntity.name,
                artist: albumEntity.artistName,
                hideDuplicates: hideDuplicateTracks,
                artwork: false
            )
        }
        if populateArtwork { populateAlbumArtworkForTracks(&tracks) }
        return tracks
    }

    func getArtistNamesByRole() -> [String: [String: String]]? {
        do {
            var result: [String: [String: String]] = [:]
            for row in try rows(core.artistNamesByRole()) {
                let role: String = row["role"]
                let lookup: String = row["lookup"]
                result[role, default: [:]][lookup] = row["canonical"]
            }
            return result
        } catch {
            Logger.error("Failed to get artist names by role: \(error)")
            return nil
        }
    }

    func getTrackCountsByFormat() -> [String: Int] {
        do {
            var counts: [String: Int] = [:]
            for row in try rows(core.libraryStatistic(kind: .formats, hideDuplicates: hideDuplicateTracks)) {
                let format: String = row["fmt"] ?? ""
                let count: Int = row["cnt"] ?? 0
                counts[format.isEmpty ? "(none)" : format.lowercased(), default: 0] += count
            }
            return counts
        } catch {
            Logger.error("Failed to get track counts by format: \(error)")
            return [:]
        }
    }

    func getAllTracks(populateArtwork: Bool = true) -> [Track] {
        var tracks = readTracks { try core.allTracks(hideDuplicates: hideDuplicateTracks, artwork: false) }
        if populateArtwork { populateAlbumArtworkForTracks(&tracks) }
        return tracks
    }

    func getRecentlyPlayedTracks(limit: Int = 10, populateArtwork: Bool = true) -> [Track] {
        var tracks = readTracks { try core.recentTracks(limit: Int64(limit), hideDuplicates: hideDuplicateTracks) }
        if populateArtwork { populateAlbumArtworkThumbnailsForTracks(&tracks) }
        return tracks
    }

    func getTrackCountForFolder(_ folderId: Int64) -> Int {
        do { return Int(try core.folderTrackCount(id: folderId)) } catch {
            Logger.error("Failed to count folder tracks: \(error)")
            return 0
        }
    }

    func getArtistId(for artistName: String) -> Int64? {
        do { return try core.artistId(name: artistName, normalizedName: ArtistParser.normalizeArtistName(artistName)) } catch {
            Logger.error("Failed to get artist ID: \(error)")
            return nil
        }
    }

    func getArtistArtworkAndBio(for artistName: String) -> (artworkData: Data?, bio: String?) {
        do {
            let result = try core.artistInfo(
                name: artistName,
                normalizedName: ArtistParser.normalizeArtistName(artistName),
                requiresFetchedImage: ArtistBioManager.shared.isArtistInfoFetchEnabled
            )
            guard let row = try rows(result).first else { return (nil, nil) }
            return (row["artwork_data"], row["bio"])
        } catch {
            Logger.error("Failed to get artist data: \(error)")
            return (nil, nil)
        }
    }

    func getTrackPlayCount(trackId: Int64) async throws -> Int? {
        try await Task.detached { try self.core.trackPlayCount(id: trackId).map(Int.init) }.value
    }

    func trackExists(withId trackId: Int64) -> Bool {
        do { return try core.trackExists(id: trackId) } catch {
            Logger.error("Failed to check track existence: \(error)")
            return false
        }
    }

    func findTrackByPath(_ path: String) async -> Track? {
        let stored = LibraryPathStore.storedPath(for: URL(fileURLWithPath: path))
        return await Task.detached { self.readTracks { try self.core.trackByPath(path: stored) }.first }.value
    }

    func tracksByFilenames(_ filenames: [String]) async -> [Track] {
        await Task.detached { self.readTracks { try self.core.tracksByFilenames(filenames: filenames.map { $0.lowercased() }) } }.value
    }

    func storedFilenames() async -> [String] {
        await Task.detached {
            do { return try self.core.storedFilenames() } catch {
                Logger.error("Failed to query stored filenames: \(error)")
                return []
            }
        }.value
    }

    func m3uQuery() -> M3UTrackResolver.Query {
        M3UTrackResolver.Query(
            findTrackByPath: { path in await self.findTrackByPath(path) },
            tracksByFilenames: { names in await self.tracksByFilenames(names) },
            storedFilenames: { await self.storedFilenames() }
        )
    }
}

extension Track {
    init(storageProjection row: DatabaseLightTrack) throws {
        guard let title = row.title, let artist = row.artist, let album = row.album,
              let composer = row.composer, let genre = row.genre, let year = row.year,
              let format = row.format, let duration = row.duration else {
            throw DatabaseError.scanFailed("Missing required track value")
        }
        url = LibraryPathStore.url(fromStored: row.path)
        self.format = format
        trackId = row.id
        folderId = row.folderId
        self.title = title
        self.artist = artist
        self.album = album
        self.composer = composer
        self.genre = genre
        self.year = year
        self.duration = HelperUtils.sanitizedDuration(duration)
        lossless = row.lossless
        codec = row.codec
        bitrate = row.bitrate.map(Int.init)
        sampleRate = row.sampleRate.map(Int.init)
        channels = row.channels.map(Int.init)
        dateAdded = Self.databaseDate(row.dateAdded)
        isFavorite = row.isFavorite
        dateFavorited = Self.databaseDate(row.dateFavorited)
        playCount = Int(row.playCount)
        lastPlayedDate = Self.databaseDate(row.lastPlayedDate)
        albumArtist = row.albumArtist
        trackNumber = row.trackNumber.map(Int.init)
        discNumber = row.discNumber.map(Int.init)
        isDuplicate = row.isDuplicate
        albumId = row.albumId
    }

    static func databaseDate(_ cell: DatabaseCell?) -> Date? {
        guard let cell else { return nil }
        let value: DatabaseValue
        switch cell {
        case .null: value = .null
        case let .integer(number): value = number.databaseValue
        case let .real(number): value = number.databaseValue
        case let .text(text): value = text.databaseValue
        case let .blob(bytes): value = bytes.databaseValue
        }
        return Date.fromDatabaseValue(value)
    }
}
