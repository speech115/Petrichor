import Foundation

struct ExtendedMetadata: Codable {
    // Additional identifiers
    var isrc: String?
    var barcode: String?
    var catalogNumber: String?

    // MusicBrainz identifiers
    var musicBrainzArtistId: String?
    var musicBrainzAlbumId: String?
    var musicBrainzAlbumArtistId: String?
    var musicBrainzTrackId: String?
    var musicBrainzReleaseGroupId: String?
    var musicBrainzWorkId: String?

    // Acoustic fingerprinting
    var acoustId: String?
    var acoustIdFingerprint: String?

    // Additional credits
    var originalArtist: String?
    var producer: String?
    var engineer: String?
    var lyricist: String?
    var conductor: String?
    var remixer: String?
    var performer: [String: String]?

    // Publishing/Label info
    var label: String?
    var publisher: String?
    var copyright: String?

    // Additional descriptive fields
    var key: String? // Musical key
    var mood: String?
    var language: String?
    var lyrics: String?
    var comment: String?
    var subtitle: String?
    var grouping: String? // Work/grouping for classical
    var movement: String? // Classical movement

    // Technical metadata
    var replayGainAlbum: String?
    var replayGainTrack: String?
    var encodedBy: String?
    var encoderSettings: String?

    // Additional date information
    var recordingDate: String?

    // Podcast/audiobook specific
    var podcastUrl: String?
    var podcastCategory: String?
    var podcastDescription: String?
    var podcastKeywords: String?

    // iTunes specific fields not covered by main columns
    var itunesAdvisory: String?
    var itunesAccount: String?
    var itunesPurchaseDate: String?

    // Gapless playback info
    var gaplessData: String?

    // Additional sort fields
    var sortComposer: String?

    // Custom fields for future extensibility
    var customFields: [String: String]?

    // Helper to convert to/from JSON
    func toJSON() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func fromJSON(_ json: String?) -> ExtendedMetadata? {
        guard let json = json,
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ExtendedMetadata.self, from: data)
    }
}
