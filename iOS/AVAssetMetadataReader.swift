//
// AVAssetMetadataReader
//
// iOS `MetadataReader` built on AVFoundation. Reads ID3/MP3 tags and audio
// properties via AVURLAsset; the MP3-only scope keeps the mapping surface small.
//

import AVFoundation
import Foundation

/// Разбор имени файла как источник метаданных, когда теги их не содержат.
///
/// Библиотека пользователя смешивает два стиля имён: `#### - Исполнитель -
/// Название` (числовой префикс задаёт порядок в плейлистах и остаётся частью
/// заголовка) и обычный `Исполнитель - Название` без префикса — именно этот
/// второй случай встречается чаще всего там, где тег исполнителя реально
/// отсутствует.
enum FilenameMetadataFallback {
    private static let separator = " - "

    static func parse(_ url: URL) -> (artist: String?, title: String) {
        let base = url.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespaces)
        let parts = base.components(separatedBy: separator)

        guard parts.count >= 2 else {
            return (nil, base)
        }

        // `#### - Исполнитель - Название`: префикс остаётся частью заголовка.
        if parts.count >= 3, !parts[0].isEmpty, parts[0].allSatisfy(\.isNumber) {
            let artist = parts[1].trimmingCharacters(in: .whitespaces)
            return (artist, base)
        }

        // `Исполнитель - Название`.
        guard !parts[0].isEmpty, !parts[0].allSatisfy(\.isNumber) else {
            return (nil, base)
        }

        let artist = parts[0].trimmingCharacters(in: .whitespaces)
        let title = parts.dropFirst().joined(separator: separator)
            .trimmingCharacters(in: .whitespaces)
        return (artist, title)
    }
}

struct AVAssetMetadataReader: MetadataReader {
    /// MP3 is the only format the iOS port plays.
    static var supportedFileExtensions: [String] {
        ["mp3"]
    }

    func extractMetadata(
        from url: URL,
        externalArtwork: Data?,
        artworkCache: ArtworkCompressionCache?
    ) async -> TrackMetadata {
        var metadata = TrackMetadata(url: url)

        let asset = AVURLAsset(url: url)

        do {
            let (metadataItems, duration, audioTrack) = try await (
                asset.load(.metadata),
                asset.load(.duration),
                asset.loadTracks(withMediaType: .audio).first
            )

            await map(metadataItems, into: &metadata)

            let seconds = duration.seconds
            if seconds.isFinite, seconds > 0 {
                metadata.duration = await MetadataMapping.validatedDuration(
                    seconds,
                    codec: metadata.codec,
                    url: url,
                    sourceName: "AVAsset"
                )
            }

            if let audioTrack {
                do {
                    let (dataRate, formatDescriptions) = try await (
                        audioTrack.load(.estimatedDataRate),
                        audioTrack.load(.formatDescriptions)
                    )
                    if dataRate > 0 {
                        // AVAsset reports bytes/sec; Petrichor stores and displays kbps.
                        metadata.bitrate = Int((dataRate * 8) / 1000)
                    }
                    if let formatDescription = formatDescriptions.first {
                        if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee {
                            if asbd.mSampleRate > 0 {
                                metadata.sampleRate = Int(asbd.mSampleRate)
                            }
                            if asbd.mChannelsPerFrame > 0 {
                                metadata.channels = Int(asbd.mChannelsPerFrame)
                            }
                        }
                        metadata.codec = Self.codecName(for: formatDescription.mediaSubType)
                    }
                } catch {
                    Logger.warning("Failed to read audio properties for \(url.lastPathComponent): \(error.localizedDescription)")
                }
            }

            metadata.lossless = MetadataMapping.isTrackLossless(
                codec: metadata.codec,
                fileExtension: url.pathExtension,
                fallback: nil
            )
        } catch {
            Logger.error("Failed to load metadata for \(url.lastPathComponent): \(error.localizedDescription)")
        }

        // Artwork: prefer the embedded front cover, fall back to external.
        if metadata.artworkData == nil, let externalArtwork = externalArtwork {
            metadata.artworkData = externalArtwork
        }

        // Filename fallback: only for whatever the tags left empty. The
        // "Unknown Artist" placeholder is applied later, in shared code
        // (`DMMetadata.swift`) — here we only care whether a real value is
        // still missing.
        if metadata.artist?.nilIfEmpty == nil || metadata.title?.nilIfEmpty == nil {
            let parsed = FilenameMetadataFallback.parse(url)
            if metadata.artist?.nilIfEmpty == nil {
                metadata.artist = parsed.artist
            }
            if metadata.title?.nilIfEmpty == nil {
                metadata.title = parsed.title
            }
        }

        return metadata
    }

    // MARK: - Mapping

    private func map(_ items: [AVMetadataItem], into metadata: inout TrackMetadata) async {
        var byKey: [String: AVMetadataItem] = [:]
        for item in items {
            guard let key = item.commonKey?.rawValue ?? item.identifier?.rawValue else { continue }
            if byKey[key] == nil {
                byKey[key] = item
            }
        }

        // `AVMetadataItem.value` and friends are deprecated since iOS 16 in
        // favor of `load(...)`, which is also the non-blocking path: values
        // load asynchronously instead of pinning the caller thread on I/O.
        //
        // A missing tag (no matching item) is normal and silent. A thrown
        // load error is different: the tag is present but AVFoundation
        // couldn't decode it (a truncated or malformed frame), and that goes
        // to the log via `Self.loggedLoad` instead of collapsing into the
        // same `nil` a missing tag produces — see ticket 08 / the ticket 03
        // review this fixes.
        let url = metadata.url

        func string(for commonKey: AVMetadataKey) async -> String? {
            guard let item = items.first(where: { $0.commonKey == commonKey }) else { return nil }
            let value = await Self.loggedLoad(tag: commonKey.rawValue, url: url) { try await item.load(.value) }
            return stringValue(value)
        }

        func string(forRawKeys keys: [String], in items: [AVMetadataItem]) async -> String? {
            for key in keys {
                guard let item = items.first(where: { ($0.key as? String)?.lowercased() == key.lowercased() }) else {
                    continue
                }
                let value = await Self.loggedLoad(tag: key, url: url) { try await item.load(.value) }
                if let string = stringValue(value) {
                    return string
                }
            }
            return nil
        }

        func stringValue(_ value: Any?) -> String? {
            if let string = value as? String {
                return string.isEmpty ? nil : string
            }
            if let number = value as? NSNumber {
                return number.stringValue
            }
            return nil
        }

        metadata.title = await string(for: .commonKeyTitle)
        metadata.artist = await string(for: .commonKeyArtist)
        metadata.album = await string(for: .commonKeyAlbumName)
        // `??` is an autoclosure, so the fallback must load in a separate step.
        metadata.albumArtist = await string(for: AVMetadataKey(rawValue: "albumArtist"))
        if metadata.albumArtist == nil {
            metadata.albumArtist = await string(forRawKeys: ["©ART", "TPE2"], in: items)
        }
        metadata.composer = await string(for: AVMetadataKey(rawValue: "composer"))
        if metadata.composer == nil {
            metadata.composer = await string(forRawKeys: ["©wrt", "TCOM"], in: items)
        }
        metadata.genre = await string(for: AVMetadataKey(rawValue: "genre"))
        if metadata.genre == nil {
            metadata.genre = await string(forRawKeys: ["©gen", "TCON", "gnre"], in: items)
        }

        if let yearItem = byKey[AVMetadataIdentifier.id3MetadataYear.rawValue] {
            let value = await Self.loggedLoad(tag: "year", url: url) { try await yearItem.load(.value) }
            metadata.year = stringValue(value)
            metadata.releaseDate = metadata.year
        } else if let dateItem = items.first(where: { $0.commonKey == .commonKeyCreationDate }) {
            let dateString = await Self.loggedLoad(tag: "creationDate", url: url) { try await dateItem.load(.stringValue) }
            let cleaned = dateString?.nilIfEmpty
            metadata.releaseDate = cleaned
            metadata.year = MetadataMapping.year(fromDateString: cleaned ?? "")
        }

        if let trackNumberItem = items.first(where: { $0.identifier == .id3MetadataTrackNumber }) {
            let trackInfo = await Self.trackNumberInfo(from: trackNumberItem, url: url)
            metadata.trackNumber = trackInfo.number
            metadata.totalTracks = trackInfo.total
        }

        if let artworkItem = items.first(where: { $0.commonKey == .commonKeyArtwork }) {
            // `??` is an autoclosure without an async overload (see the note
            // above), so the fallback attempt has to be its own step.
            var data = await Self.loggedLoad(tag: "artwork.data", url: url) { try await artworkItem.load(.dataValue) }
            if data == nil {
                data = await Self.loggedLoad(tag: "artwork.value", url: url) { try await artworkItem.load(.value) } as? Data
            }
            if let data {
                metadata.artworkData = await MetadataMapping.compressedArtwork(
                    from: data,
                    source: url.lastPathComponent,
                    cache: nil
                )
            }
        }
    }

    /// Loads an item's property, treating a missing value as expected
    /// (returns `nil` silently — most tags on most files are simply absent)
    /// and a thrown error as diagnostic-worthy (logs, then returns `nil`).
    /// The reader's contract to its caller does not change either way:
    /// `map(_:into:)` always returns a best-effort `TrackMetadata`, never
    /// throws. This only makes the "tag present but undecodable" case
    /// visible instead of indistinguishable from "tag absent".
    private static func loggedLoad<Value>(
        tag: String,
        url: URL,
        _ load: () async throws -> Value?
    ) async -> Value? {
        do {
            return try await load()
        } catch {
            Logger.warning("Failed to load \(tag) tag for \(url.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }

    private static func trackNumberInfo(from item: AVMetadataItem, url: URL) async -> (number: Int?, total: Int?) {
        if let data = await loggedLoad(tag: "trackNumber.data", url: url, { try await item.load(.dataValue) }),
           data.count >= 2 {
            let number = Int(data[0])
            let total = data.count >= 3 ? Int(data[2]) : nil
            return (number > 0 ? number : nil, total)
        }
        if let number = await loggedLoad(tag: "trackNumber.number", url: url, { try await item.load(.numberValue) }) {
            return (number.intValue, nil)
        }
        if let string = await loggedLoad(tag: "trackNumber.string", url: url, { try await item.load(.stringValue) }) {
            let parts = string.split(separator: "/").map { Int($0.trimmingCharacters(in: .whitespaces)) }
            return (parts.first ?? nil, parts.count > 1 ? parts[1] : nil)
        }
        return (nil, nil)
    }

    private static func codecName(for subtype: CMFormatDescription.MediaSubType) -> String {
        switch subtype.rawValue {
        case kAudioFormatMPEGLayer3:
            return "mp3"
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_LD, kAudioFormatMPEG4AAC_ELD:
            return "aac"
        case kAudioFormatLinearPCM:
            return "pcm"
        default:
            return "unknown"
        }
    }
}
