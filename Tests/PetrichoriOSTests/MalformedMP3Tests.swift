import Foundation
import Testing
@testable import Petrichor

/// Hypotheses about the real iOS tag reader (`AVAssetMetadataReader`, so the
/// simulator's AVFoundation) on broken files: truncated downloads, garbage
/// with an `.mp3` name, a tag header that lies about its size, and the text
/// encodings `makeSilentMP3` never writes (UTF-16 with BOM, ID3v2.4 UTF-8,
/// NUL-terminated frames). No retries or loosened assertions on a flake — see
/// `AVAssetMetadataReaderTests`.
struct MalformedMP3Tests {
    private let reader = AVAssetMetadataReader()

    // MARK: - Broken files

    /// Cut points land in the ID3 header, inside a frame, in the first MPEG
    /// frame and mid-stream. The reader must come back with sane numbers.
    @Test(arguments: [0, 1, 3, 9, 10, 25, 60, 200, 1_000, 20_000])
    func truncatedFileYieldsSaneMetadata(keptBytes: Int) async throws {
        let full = try makeSilentMP3(artist: "Artist", title: "Title", album: "Album", trackNumber: 3, totalTracks: 12, seconds: 2)
        defer { try? FileManager.default.removeItem(at: full) }
        let url = try writeTemporaryMP3(Data(contentsOf: full).prefix(keptBytes))
        defer { try? FileManager.default.removeItem(at: url) }

        let metadata = await reader.extractMetadata(from: url, externalArtwork: nil, artworkCache: nil)

        #expect(metadata.duration.isFinite)
        #expect(metadata.duration >= 0 && metadata.duration <= 2.5, "duration \(metadata.duration)")
        if let bitrate = metadata.bitrate {
            #expect(bitrate > 0)
        }
    }

    @Test(arguments: FuzzText.seeds(8))
    func garbageWithAnMP3NameYieldsSaneMetadata(seed: UInt64) async throws {
        var rng = SeededGenerator(seed: seed)
        var bytes = (0..<Int.random(in: 0...8_192, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) }
        // Half the cases start like a real file, so the parser commits to it.
        switch seed % 3 {
        case 0: bytes.insert(contentsOf: Array("ID3".utf8) + [3, 0, 0, 0, 0, 2, 0], at: 0)
        case 1: bytes.insert(contentsOf: [0xFF, 0xFB, 0x90, 0x00], at: 0)
        default: break
        }
        let url = try writeTemporaryMP3(Data(bytes))
        defer { try? FileManager.default.removeItem(at: url) }

        let metadata = await reader.extractMetadata(from: url, externalArtwork: nil, artworkCache: nil)

        #expect(metadata.duration.isFinite && metadata.duration >= 0, "duration \(metadata.duration)")
    }

    /// The header claims a ~256 MB tag in front of a one-second file.
    @Test func tagHeaderClaimingMoreThanTheFileHolds() async throws {
        var data = Data("ID3".utf8)
        data.append(contentsOf: [3, 0, 0, 0x7F, 0x7F, 0x7F, 0x7F])
        data.append(id3TextFrame("TIT2", "Title", encoding: 0, version: 3))
        data.append(silentMPEGFrames(seconds: 1))
        let url = try writeTemporaryMP3(data)
        defer { try? FileManager.default.removeItem(at: url) }

        let metadata = await reader.extractMetadata(from: url, externalArtwork: nil, artworkCache: nil)

        #expect(metadata.duration.isFinite && metadata.duration >= 0, "duration \(metadata.duration)")
    }

    // MARK: - Text encodings

    @Test func utf16TagsWithByteOrderMarkReadBack() async throws {
        let url = try writeTaggedMP3(version: 3, frames: [
            id3TextFrame("TIT2", "Группа крови", encoding: 1, version: 3),
            id3TextFrame("TPE1", "Кино", encoding: 1, version: 3),
            id3TextFrame("TRCK", "4/12", encoding: 1, terminated: true, version: 3)
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let metadata = await reader.extractMetadata(from: url, externalArtwork: nil, artworkCache: nil)

        #expect(metadata.title == "Группа крови")
        #expect(metadata.artist == "Кино")
        #expect(metadata.trackNumber == 4)
        #expect(metadata.totalTracks == 12)
    }

    @Test func nulTerminatedLatin1TrackNumberReadsBack() async throws {
        let url = try writeTaggedMP3(version: 3, frames: [
            id3TextFrame("TIT2", "Title", encoding: 0, terminated: true, version: 3),
            id3TextFrame("TRCK", "7/9", encoding: 0, terminated: true, version: 3)
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let metadata = await reader.extractMetadata(from: url, externalArtwork: nil, artworkCache: nil)

        #expect(metadata.title == "Title")
        #expect(metadata.trackNumber == 7)
        #expect(metadata.totalTracks == 9)
    }

    @Test func id3v24UTF8TagsReadBack() async throws {
        let url = try writeTaggedMP3(version: 4, frames: [
            id3TextFrame("TIT2", "Выхода нет", encoding: 3, version: 4),
            id3TextFrame("TPE1", "Сплин", encoding: 3, version: 4),
            id3TextFrame("TRCK", "2/10", encoding: 3, version: 4)
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let metadata = await reader.extractMetadata(from: url, externalArtwork: nil, artworkCache: nil)

        #expect(metadata.title == "Выхода нет")
        #expect(metadata.artist == "Сплин")
        #expect(metadata.trackNumber == 2)
        #expect(metadata.totalTracks == 10)
    }
}

// MARK: - ID3 writer

private func writeTemporaryMP3(_ data: Data) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp3")
    try data.write(to: url)
    return url
}

private func writeTaggedMP3(version: UInt8, frames: [Data]) throws -> URL {
    let body = frames.reduce(Data(), +)
    var data = Data("ID3".utf8)
    data.append(contentsOf: [version, 0, 0])
    data.append(tagSize(body.count, syncsafe: true))
    data.append(body)
    data.append(silentMPEGFrames(seconds: 1))
    return try writeTemporaryMP3(data)
}

/// ID3v2 sizes: the tag header's (and every v2.4 frame's) is syncsafe — only
/// the low 7 bits of each byte count; v2.3 frame sizes are plain big-endian.
private func tagSize(_ value: Int, syncsafe: Bool) -> Data {
    guard syncsafe else {
        return Data(withUnsafeBytes(of: UInt32(value).bigEndian, Array.init))
    }
    return Data([21, 14, 7, 0].map { UInt8((value >> $0) & 0x7F) })
}

/// A text frame in one of the four ID3v2 encodings: 0 latin-1, 1 UTF-16 with
/// BOM (little-endian here), 2 UTF-16BE, 3 UTF-8.
private func id3TextFrame(
    _ id: String,
    _ text: String,
    encoding: UInt8,
    terminated: Bool = false,
    version: UInt8
) -> Data {
    var payload = Data([encoding])
    switch encoding {
    case 0:
        payload.append(text.data(using: .isoLatin1) ?? Data())
    case 1:
        payload.append(contentsOf: [0xFF, 0xFE])
        payload.append(utf16Bytes(text, littleEndian: true))
    case 2:
        payload.append(utf16Bytes(text, littleEndian: false))
    default:
        payload.append(Data(text.utf8))
    }
    if terminated {
        payload.append(contentsOf: encoding == 1 || encoding == 2 ? [0, 0] : [0])
    }

    var frame = Data(id.utf8)
    frame.append(tagSize(payload.count, syncsafe: version == 4))
    frame.append(contentsOf: [0, 0]) // flags
    frame.append(payload)
    return frame
}

/// MPEG-1 Layer III silence, as in `makeSilentMP3`: 128 kbps, 44.1 kHz,
/// 417-byte frames of 1152 samples.
private func silentMPEGFrames(seconds: Int) -> Data {
    var data = Data()
    let frameCount = Int((Double(seconds) * 44_100 / 1152).rounded(.up))
    for _ in 0..<frameCount {
        data.append(contentsOf: [0xFF, 0xFB, 0x90, 0x00])
        data.append(Data(count: 417 - 4))
    }
    return data
}
