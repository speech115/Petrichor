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

        let metadata = try await withTimeout(seconds: 15) {
            await reader.extractMetadata(from: url, externalArtwork: nil, artworkCache: nil)
        }

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
    /// malformed. `title`/`artist` still get a value because
    /// `extractMetadata`'s filename fallback runs after the tag parse
    /// (`FilenameMetadataFallback`), so the fixture name is asserted through
    /// that fallback rather than treated as a leak from the tag path.
    @Test func fileWithNoTagsHasEmptyFieldsNotAnError() async throws {
        let url = try makeSilentMP3() // no artist/title/album -> no ID3 header written at all
        defer { try? FileManager.default.removeItem(at: url) }

        let metadata = try await withTimeout(seconds: 15) {
            await reader.extractMetadata(from: url, externalArtwork: nil, artworkCache: nil)
        }

        // Filename fallback: `makeSilentMP3` names the file after a random
        // UUID with no " - " separator, so `FilenameMetadataFallback` leaves
        // artist nil and sets the title to the bare filename.
        #expect(metadata.artist == nil)
        #expect(metadata.title == url.deletingPathExtension().lastPathComponent)
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

        let metadata = try await withTimeout(seconds: 15) {
            await reader.extractMetadata(from: url, externalArtwork: nil, artworkCache: nil)
        }

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
        // Filename fallback still runs: the random UUID filename has no
        // " - " separator, so title falls back to the bare filename.
        #expect(metadata.title == url.deletingPathExtension().lastPathComponent)
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

        let metadata = try await withTimeout(seconds: 15) {
            await reader.extractMetadata(from: url, externalArtwork: nil, artworkCache: nil)
        }

        #expect(metadata.albumArtist == "Raw Key Album Artist")
        #expect(metadata.composer == "Raw Key Composer")
        #expect(metadata.genre == "Raw Key Genre")
    }
}

// MARK: - Timeout helper

/// Seam tests here talk to the simulator's real media service through
/// `AVAsset.load`, which the project has already observed to intermittently
/// hang or fail under parallel test load (`TestFixtures.swift`). A hang
/// should show up as a clear timeout failure, not as the whole test run
/// stalling until the outer CI timeout kills it with no diagnostic.
struct SeamTimeoutError: Error, CustomStringConvertible {
    let seconds: Double
    var description: String { "Timed out after \(seconds)s waiting on AVAssetMetadataReader" }
}

func withTimeout<T: Sendable>(
    seconds: Double,
    operation: @escaping @Sendable () async -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw SeamTimeoutError(seconds: seconds)
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
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
        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
    ) else { return nil }

    context.setFillColor(red: 0.4, green: 0.2, blue: 0.8, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))

    guard let cgImage = context.makeImage() else { return nil }
    return ImageUtils.encodeJPEG(cgImage, quality: 0.9)
}
