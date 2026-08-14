import CoreGraphics
import Foundation
import Testing
@testable import Petrichor

/// Seam test «отображение метаданных `AVAsset`» (design spec, пункт 3;
/// ticket 08). Calls `AVAssetMetadataReader` directly — not through
/// `MetadataEngine`/the scan pipeline, which is exactly where
/// `TestMetadataReader` (`TestFixtures.swift`) substitutes a deterministic
/// stub for `AVAssetMetadataReader` so the scan doesn't depend on the
/// simulator's media service. Going through the scan can never exercise the
/// real ID3 parsing in `AVAssetMetadataReader.map(_:into:)`; only calling the
/// reader directly can.
///
/// About flakiness (see `TestFixtures.swift`, `TestMetadataReader`'s doc
/// comment): `AVAsset.load(...)` on the simulator hits the same shared media
/// service these tests are built to exercise, and it has been observed to
/// intermittently fail under parallel test load. If that happens here, it
/// must not be papered over with retries, `XCTSkip`, or loosened assertions
/// — a seam test that passes by luck is worse than no test. Reproductions go
/// in the ticket 8 report, not into weaker assertions.
///
/// No local timeout wrapper: `AVAsset.load` does not abandon on task
/// cancellation, so a `TaskGroup` deadline cannot unbound a hung load. A
/// hang surfaces as the suite/CI timeout; that is honest, not a silent stall
/// behind a helper that claims to fail cleanly.
struct AVAssetMetadataReaderTests {
    private let reader = AVAssetMetadataReader()

    /// Full tag set: every `TrackMetadata` field the reader knows how to
    /// parse is present in the fixture and must come back correctly,
    /// including the fields (`albumArtist`, `composer`, `genre`) that only
    /// have a raw ID3 frame ID (`TPE2`/`TCOM`/`TCON`) and no AVFoundation
    /// common-key equivalent — the reader's first lookup (by common key)
    /// always misses for these three, so this fixture is what actually
    /// exercises the raw-key fallback, not just the common-key path.
    @Test func fullTagSetParsesEveryField() async throws {
        let artwork = try #require(makeTestJPEGData())
        let url = try makeSilentMP3(
            artist: "Annabel",
            title: "Above Your Hand",
            album: "Seam Test Album",
            albumArtist: "Annabel & Friends",
            composer: "J. Composer",
            genre: "Post-Hardcore",
            year: "2011",
            trackNumber: 4,
            totalTracks: 12,
            artwork: artwork
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let metadata = await reader.extractMetadata(from: url, externalArtwork: nil, artworkCache: nil)

        #expect(metadata.title == "Above Your Hand")
        #expect(metadata.artist == "Annabel")
        #expect(metadata.album == "Seam Test Album")
        #expect(metadata.albumArtist == "Annabel & Friends")
        #expect(metadata.composer == "J. Composer")
        #expect(metadata.genre == "Post-Hardcore")
        #expect(metadata.year == "2011")
        #expect(metadata.trackNumber == 4)
        #expect(metadata.totalTracks == 12)
        #expect(metadata.artworkData != nil)
        #expect(metadata.duration > 0)
    }

    /// A file with no ID3 tag at all: every tag-derived field must come back
    /// empty, and that is the correct, non-error outcome — distinct from the
    /// corrupted-file scenario below, where the file *has* a tag and it's
    /// malformed. `title`/`artist` stay empty here: the filename fallback is
    /// no longer the reader's job — it lives in the shared layer
    /// (`FilenameMetadataFallback`, applied by `DMMetadata.applyMetadataToTrack`),
    /// so `extractMetadata` returns the tag fields as it found them.
    @Test func fileWithNoTagsHasEmptyFieldsNotAnError() async throws {
        let url = try makeSilentMP3() // no artist/title/album -> no ID3 header written at all
        defer { try? FileManager.default.removeItem(at: url) }

        let metadata = await reader.extractMetadata(from: url, externalArtwork: nil, artworkCache: nil)

        #expect(metadata.artist == nil)
        #expect(metadata.title == nil)
        #expect(metadata.album == nil)
        #expect(metadata.albumArtist == nil)
        #expect(metadata.composer == nil)
        #expect(metadata.genre == nil)
        #expect(metadata.year == nil)
        #expect(metadata.trackNumber == nil)
        #expect(metadata.artworkData == nil)
        // The audio itself is still well-formed, so duration parses fine —
        // this is "no tags", not "no file".
        #expect(metadata.duration > 0)
    }

    /// A corrupted file: an ID3v2.3 header with a syncsafe size field lying
    /// about how much tag data follows (64 KB claimed, ~40 bytes actually
    /// written), no real frames, and no MPEG audio at all —
    /// `makeCorruptMP3()`. This must not crash the reader, and the failure
    /// must be visible: before ticket 08, `extractMetadata`'s outer
    /// `do`/`catch` (`AVAssetMetadataReader.swift`, the `asset.load(.metadata,
    /// .duration, ...)` tuple) already logs via `Logger.error` when the
    /// top-level asset load throws, which this fixture is expected to hit
    /// (the file has no audio frames, so duration/track loading has nothing
    /// to find). The reader's contract for a file it cannot parse is a
    /// harmless, mostly-empty `TrackMetadata` — not a thrown error out of
    /// `extractMetadata` itself, which has no `throws` in its signature.
    @Test func corruptedFileDoesNotCrashAndReturnsEmptyMetadata() async throws {
        let url = try makeCorruptMP3()
        defer { try? FileManager.default.removeItem(at: url) }

        let metadata = await reader.extractMetadata(from: url, externalArtwork: nil, artworkCache: nil)

        // No crash reaching this line is itself the primary assertion. The
        // file is unparseable, so every tag field is empty and duration
        // could not be determined.
        #expect(metadata.album == nil)
        #expect(metadata.albumArtist == nil)
        #expect(metadata.composer == nil)
        #expect(metadata.genre == nil)
        #expect(metadata.year == nil)
        #expect(metadata.trackNumber == nil)
        #expect(metadata.artworkData == nil)
        #expect(metadata.duration == 0)
        // The filename fallback moved to the shared layer, so the reader
        // returns empty title/artist for an unparseable file.
        #expect(metadata.artist == nil)
        #expect(metadata.title == nil)
    }

    /// The raw-key fallback in isolation: `albumArtist`/`composer`/`genre`
    /// carried *only* via their ID3 frame ID, with no other tag present.
    /// This is the narrowest reproduction of the fragile path called out in
    /// the independent review of ticket 03 — if the fallback's frame-ID
    /// matching (`($0.key as? String)?.lowercased() == key.lowercased()`)
    /// regresses, this is the test that catches it, not the full-tag-set
    /// test above (which would still pass on a coincidentally-right common
    /// key match for a different field).
    @Test func rawKeyFallbackAloneResolvesAlbumArtistComposerAndGenre() async throws {
        let url = try makeSilentMP3(
            albumArtist: "Raw Key Album Artist",
            composer: "Raw Key Composer",
            genre: "Raw Key Genre"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let metadata = await reader.extractMetadata(from: url, externalArtwork: nil, artworkCache: nil)

        #expect(metadata.albumArtist == "Raw Key Album Artist")
        #expect(metadata.composer == "Raw Key Composer")
        #expect(metadata.genre == "Raw Key Genre")
    }
}

// MARK: - Corrupt fixture (test-only)

/// Writes a `.mp3` that starts with a plausible ID3v2.3 header (correct
/// magic and version) but a syncsafe size field claiming far more tag data
/// than the file actually has, followed by garbage bytes instead of a real
/// frame or any MPEG audio. Lives in the test target: UI seeding never needs it.
private func makeCorruptMP3() throws -> URL {
    var data = Data()
    data.append(contentsOf: Array("ID3".utf8))
    data.append(contentsOf: [3, 0, 0]) // version 2.3, no flags
    let claimedSize = 1 << 16
    data.append(UInt8((claimedSize >> 21) & 0x7F))
    data.append(UInt8((claimedSize >> 14) & 0x7F))
    data.append(UInt8((claimedSize >> 7) & 0x7F))
    data.append(UInt8(claimedSize & 0x7F))
    data.append(contentsOf: Array("XXXX".utf8))
    data.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])
    data.append(Data(repeating: 0xAA, count: 32))

    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(UUID().uuidString).mp3")
    try data.write(to: url)
    return url
}

// MARK: - Test artwork

/// A tiny real JPEG, generated (not checked in as a binary fixture) via the
/// same `ImageUtils.encodeJPEG` production code the reader's artwork path
/// ultimately calls into (`MetadataMapping.compressedArtwork` ->
/// `ImageUtils.compressImage` -> `CGImageSourceCreateWithData`, which needs
/// bytes an actual image decoder accepts — a hand-rolled byte pair is not
/// enough). 8x8 solid color is the smallest CGImage `CGImageSourceCreateWithData`
/// reliably decodes back.
func makeTestJPEGData() -> Data? {
    let size = 8
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    ) else { return nil }

    context.setFillColor(red: 0.4, green: 0.2, blue: 0.8, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))

    guard let cgImage = context.makeImage() else { return nil }
    return ImageUtils.encodeJPEG(cgImage, quality: 0.9)
}
