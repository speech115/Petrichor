import Foundation
import PetrichorCore

extension DatabaseManager {
    func trackImport(from metadata: TrackMetadata, at url: URL, folderId: Int64) throws -> TrackImport {
        let file = observeLibraryFile(url)
        let artwork = metadata.artworkData
        let thumbnail = artwork.flatMap { ImageUtils.makeThumbnail(from: $0, source: url.path) }
        let extended = String(data: try JSONEncoder().encode(metadata.extended), encoding: .utf8)
        return TrackImport(
            path: file.path, filename: url.lastPathComponent,
            basename: url.deletingPathExtension().lastPathComponent, format: url.pathExtension, folderId: folderId,
            modified: file.modified, size: file.size, duration: metadata.duration, compilation: metadata.compilation,
            lossless: metadata.lossless, artwork: artwork, thumbnail: thumbnail,
            extendedJson: extended,
            title: metadata.title,
            artist: metadata.artist,
            album: metadata.album,
            composer: metadata.composer,
            genre: metadata.genre,
            year: metadata.year,
            albumArtist: metadata.albumArtist,
            releaseDate: metadata.releaseDate,
            originalReleaseDate: metadata.originalReleaseDate,
            mediaType: metadata.mediaType,
            codec: metadata.codec,
            sortTitle: metadata.sortTitle,
            sortArtist: metadata.sortArtist,
            sortAlbum: metadata.sortAlbum,
            sortAlbumArtist: metadata.sortAlbumArtist,
            trackNumber: metadata.trackNumber.map { Int64($0) },
            totalTracks: metadata.totalTracks.map { Int64($0) },
            discNumber: metadata.discNumber.map { Int64($0) },
            totalDiscs: metadata.totalDiscs.map { Int64($0) },
            rating: metadata.rating.map { Int64($0) },
            bpm: metadata.bpm.map { Int64($0) },
            bitrate: metadata.bitrate.map { Int64($0) },
            sampleRate: metadata.sampleRate.map { Int64($0) },
            channels: metadata.channels.map { Int64($0) },
            bitDepth: metadata.bitDepth.map { Int64($0) }
        )
    }
}
