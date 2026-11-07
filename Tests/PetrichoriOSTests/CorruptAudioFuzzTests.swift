import Foundation
import Testing
@testable import Petrichor

/// Seam fuzz for `AVAssetMetadataReader`: a library holds files that were cut
/// short by a failed copy, tagged by broken taggers, or are not audio at all.
/// Reading one must return a `TrackMetadata` with a sane duration, never crash.
/// Each seed mutates a tagged silent MP3 one way; seeds are fixed, so a failing
/// one replays exactly. Serialized for the reason `AVAssetMetadataReaderTests`
/// gives: the simulator's media service is shared.
@Suite(.serialized)
struct CorruptAudioFuzzTests {
    private let reader = AVAssetMetadataReader()

    @Test(arguments: [UInt64](1...16))
    func corruptedMP3StillReturnsMetadata(seed: UInt64) async throws {
        let source = try makeSilentMP3(
            artist: "Annabel",
            title: "Above Your Hand",
            album: "Fuzz Album",
            genre: "Post-Hardcore",
            year: "2011",
            trackNumber: 4,
            totalTracks: 12
        )
        defer { try? FileManager.default.removeItem(at: source) }

        var bytes = try Data(contentsOf: source)
        var rng = SeededGenerator(seed: seed)
        corrupt(&bytes, using: &rng)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fuzz-\(seed)-\(UUID().uuidString).mp3")
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let metadata = await reader.extractMetadata(from: url, externalArtwork: nil, artworkCache: nil)

        #expect(metadata.url == url)
        #expect(metadata.duration.isFinite)
        #expect(metadata.duration >= 0)
    }

    @Test func emptyFileReturnsEmptyMetadata() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-\(UUID().uuidString).mp3")
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let metadata = await reader.extractMetadata(from: url, externalArtwork: nil, artworkCache: nil)

        #expect(metadata.title == nil)
        #expect(metadata.duration == 0)
    }

    /// One of four corruptions, picked by the seed: a mangled ID3 header
    /// (version, flags, syncsafe size), a truncated file, a frame whose size
    /// claims more bytes than exist, or random bytes sprayed over the file.
    private func corrupt(_ data: inout Data, using rng: inout SeededGenerator) {
        guard data.count > 16 else { return }
        switch rng.next() % 4 {
        case 0:
            for _ in 0..<3 {
                let index = Int.random(in: 3..<10, using: &rng)
                data[index] = UInt8.random(in: 0...255, using: &rng)
            }
        case 1:
            let length = Int.random(in: 1..<data.count, using: &rng)
            data = Data(data.prefix(length))
        case 2:
            let start = Int.random(in: 10..<min(data.count - 4, 64), using: &rng)
            for index in start..<(start + 4) {
                data[index] = 0xFF
            }
        default:
            for _ in 0..<max(1, data.count / 50) {
                let index = Int.random(in: 0..<data.count, using: &rng)
                data[index] = UInt8.random(in: 0...255, using: &rng)
            }
        }
    }
}
