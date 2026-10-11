//
// LoftyMetadataReader
//
// The macOS `MetadataReader`, backed by the Rust core (`rust/`, the `lofty`
// crate, bound through UniFFI). Rust returns raw tag values; normalization
// stays in the shared `MetadataMapping`. Playback stays on Crescendo.
//

import Foundation
import PetrichorCore

struct LoftyMetadataReader: MetadataReader {
    /// Extensions the Rust reader can parse.
    static var supportedFileExtensions: [String] {
        supportedExtensions()
    }

    func extractMetadata(
        from url: URL,
        externalArtwork: Data?,
        artworkCache: ArtworkCompressionCache?
    ) async -> TrackMetadata {
        var metadata = TrackMetadata(url: url)

        let tags: AudioTags
        do {
            tags = try readTags(path: url.path)
        } catch {
            Logger.error("Failed to read metadata for \(url.lastPathComponent): \(error.localizedDescription)")
            metadata.artworkData = externalArtwork
            return metadata
        }

        map(tags, into: &metadata)

        if tags.durationSeconds > 0 {
            metadata.duration = await MetadataMapping.validatedDuration(
                tags.durationSeconds,
                codec: tags.codec,
                url: url,
                sourceName: "lofty"
            )
        }
        if let artwork = tags.artwork {
            metadata.artworkData = await MetadataMapping.compressedArtwork(
                from: artwork,
                source: url.lastPathComponent,
                cache: artworkCache
            )
        }
        if metadata.artworkData == nil {
            metadata.artworkData = externalArtwork
        }

        return metadata
    }

    private func map(_ tags: AudioTags, into metadata: inout TrackMetadata) {
        metadata.title = tags.title
        metadata.artist = tags.artist
        metadata.album = tags.album
        metadata.albumArtist = tags.albumArtist
        metadata.composer = tags.composer
        metadata.genre = tags.genre
        metadata.trackNumber = tags.trackNumber.map(Int.init)
        metadata.totalTracks = tags.totalTracks.map(Int.init)
        metadata.discNumber = tags.discNumber.map(Int.init)
        metadata.totalDiscs = tags.totalDiscs.map(Int.init)
        metadata.bpm = tags.bpm.map(Int.init)
        metadata.compilation = tags.compilation

        metadata.releaseDate = tags.recordingDate
        metadata.originalReleaseDate = tags.originalReleaseDate
        metadata.year = (tags.recordingDate ?? tags.originalReleaseDate)
            .flatMap(MetadataMapping.year(fromDateString:))

        metadata.sortTitle = tags.sortTitle
        metadata.sortArtist = tags.sortArtist
        metadata.sortAlbum = tags.sortAlbum
        metadata.sortAlbumArtist = tags.sortAlbumArtist

        metadata.codec = tags.codec
        metadata.bitrate = tags.bitrate.map(Int.init)
        metadata.sampleRate = tags.sampleRate.map(Int.init)
        metadata.channels = tags.channels.map(Int.init)
        metadata.bitDepth = tags.bitDepth.map(Int.init)
        metadata.lossless = MetadataMapping.isTrackLossless(
            codec: tags.codec,
            fileExtension: metadata.url.pathExtension
        )

        let source = tags.extended
        metadata.extended.isrc = source.isrc
        metadata.extended.catalogNumber = source.catalogNumber
        metadata.extended.musicBrainzArtistId = source.musicbrainzArtistId
        metadata.extended.musicBrainzAlbumId = source.musicbrainzAlbumId
        metadata.extended.musicBrainzAlbumArtistId = source.musicbrainzAlbumArtistId
        metadata.extended.musicBrainzTrackId = source.musicbrainzTrackId
        metadata.extended.musicBrainzReleaseGroupId = source.musicbrainzReleaseGroupId
        metadata.extended.musicBrainzWorkId = source.musicbrainzWorkId
        metadata.extended.acoustId = source.acoustid
        metadata.extended.acoustIdFingerprint = source.acoustidFingerprint
        metadata.extended.originalArtist = source.originalArtist
        metadata.extended.producer = source.producer
        metadata.extended.engineer = source.engineer
        metadata.extended.lyricist = source.lyricist
        metadata.extended.conductor = source.conductor
        metadata.extended.remixer = source.remixer
        metadata.extended.label = source.label
        metadata.extended.copyright = source.copyright
        metadata.extended.key = source.key
        metadata.extended.mood = source.mood
        metadata.extended.language = source.language
        metadata.extended.lyrics = source.lyrics
        metadata.extended.comment = source.comment
        metadata.extended.subtitle = source.subtitle
        metadata.extended.grouping = source.grouping
        metadata.extended.movement = source.movement
        metadata.extended.encodedBy = source.encodedBy
        metadata.extended.encoderSettings = source.encoderSettings
        metadata.extended.sortComposer = source.sortComposer
        metadata.extended.replayGainTrack = source.replayGainTrack.map { String(format: "%+.2f dB", $0) }
        metadata.extended.replayGainAlbum = source.replayGainAlbum.map { String(format: "%+.2f dB", $0) }
    }
}
