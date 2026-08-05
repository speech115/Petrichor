//
// AVAssetMetadataReader
//
// iOS `MetadataReader` built on AVFoundation. Reads ID3/MP3 tags and audio
// properties via AVURLAsset; the MP3-only scope keeps the mapping surface small.
//

import AVFoundation
import Foundation

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

        func string(for commonKey: AVMetadataKey) -> String? {
            guard let item = items.first(where: { $0.commonKey == commonKey }),
                  let value = item.value else { return nil }
            return stringValue(value)
        }

        func string(forRawKeys keys: [String], in items: [AVMetadataItem]) -> String? {
            for key in keys {
                if let item = items.first(where: { ($0.key as? String)?.lowercased() == key.lowercased() }),
                   let value = item.value,
                   let string = stringValue(value) {
                    return string
                }
            }
            return nil
        }

        func stringValue(_ value: Any) -> String? {
            if let string = value as? String {
                return string.isEmpty ? nil : string
            }
            if let number = value as? NSNumber {
                return number.stringValue
            }
            return nil
        }

        metadata.title = string(for: .commonKeyTitle)
        metadata.artist = string(for: .commonKeyArtist)
        metadata.album = string(for: .commonKeyAlbumName)
        metadata.albumArtist = string(for: AVMetadataKey(rawValue: "albumArtist"))
            ?? string(forRawKeys: ["©ART", "TPE2"], in: items)
        metadata.composer = string(for: AVMetadataKey(rawValue: "composer"))
            ?? string(forRawKeys: ["©wrt", "TCOM"], in: items)
        metadata.genre = string(for: AVMetadataKey(rawValue: "genre"))
            ?? string(forRawKeys: ["©gen", "TCON", "gnre"], in: items)

        if let yearItem = byKey[AVMetadataIdentifier.id3MetadataYear.rawValue] {
            metadata.year = stringValue(yearItem.value ?? "")
            metadata.releaseDate = metadata.year
        } else if let dateItem = items.first(where: { $0.commonKey == .commonKeyCreationDate }) {
            let dateString = stringValue(dateItem.value ?? "")
            metadata.releaseDate = dateString
            metadata.year = MetadataMapping.year(fromDateString: dateString ?? "")
        }

        if let trackNumberItem = items.first(where: { $0.identifier == .id3MetadataTrackNumber }) {
            let trackInfo = Self.trackNumberInfo(from: trackNumberItem)
            metadata.trackNumber = trackInfo.number
            metadata.totalTracks = trackInfo.total
        }

        if let artworkItem = items.first(where: { $0.commonKey == .commonKeyArtwork }),
           let data = artworkItem.dataValue ?? artworkItem.value as? Data {
            metadata.artworkData = await MetadataMapping.compressedArtwork(
                from: data,
                source: metadata.url.lastPathComponent,
                cache: nil
            )
        }
    }

    private static func trackNumberInfo(from item: AVMetadataItem) -> (number: Int?, total: Int?) {
        if let data = item.dataValue, data.count >= 2 {
            let number = Int(data[0])
            let total = data.count >= 3 ? Int(data[2]) : nil
            return (number > 0 ? number : nil, total)
        }
        if let number = item.numberValue {
            return (number.intValue, nil)
        }
        if let string = item.value as? String {
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
