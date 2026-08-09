import Foundation
import GRDB
@testable import Petrichor

/// A throwaway file-backed `DatabasePool` for tests, created inside the
/// caller's temp directory (the test's own `defer` removes that directory).
/// A true in-memory pool is not available: `DatabasePool` hard-requires WAL
/// (no journal-mode override in this GRDB version), and SQLite refuses WAL on
/// shared-cache in-memory databases. A temp file also exercises the exact
/// WAL path production uses, minus Application Support.
func makeTestDatabasePool(in directory: URL) throws -> DatabasePool {
    try DatabasePool(
        path: directory.appendingPathComponent("test-\(UUID().uuidString).db").path
    )
}

/// Deterministic `MetadataReader` for scan seam tests, installed via
/// `MetadataEngine.readerOverride`. The scanner pipeline is exercised without
/// the simulator's media service, which is shared and intermittently fails
/// `AVAsset.load(.metadata)` under parallel test load. Artist and title are
/// parsed from the filename (`Artist - Title.mp3`); `overrides` supplies
/// values a filename cannot carry (album), keyed by absolute file path.
final class TestMetadataReader: MetadataReader, @unchecked Sendable {
    static let shared = TestMetadataReader()

    private let lock = NSLock()
    private var overrides: [String: (artist: String?, title: String?, album: String?)] = [:]

    func setOverride(
        for url: URL,
        artist: String? = nil,
        title: String? = nil,
        album: String? = nil
    ) {
        lock.lock()
        overrides[url.path] = (artist, title, album)
        lock.unlock()
    }

    func reset() {
        lock.lock()
        overrides.removeAll()
        lock.unlock()
    }

    func extractMetadata(
        from url: URL,
        externalArtwork: Data?,
        artworkCache: ArtworkCompressionCache?
    ) async -> TrackMetadata {
        var metadata = TrackMetadata(url: url)
        let base = url.deletingPathExtension().lastPathComponent

        let override = lock.withLock { overrides[url.path] }

        if let override {
            metadata.artist = override.artist
            metadata.title = override.title
            metadata.album = override.album
        } else {
            let parts = base.components(separatedBy: " - ")
            if parts.count >= 2 {
                metadata.artist = parts[0]
                metadata.title = parts.dropFirst().joined(separator: " - ")
            } else {
                metadata.title = base
            }
        }

        metadata.duration = 1
        return metadata
    }
}

/// Writes a short silent WAV. Generated rather than checked in so tests carry
/// no binary fixture, and silent because only the transport matters. A queue
/// entry pointing at a *missing* file is not a valid fixture: AVPlayerItem
/// fails asynchronously and `handleItemFailure` drops it from the queue,
/// which races with the bookkeeping assertions.
func makeSilentWAV(seconds: Int = 2) throws -> URL {
    let sampleRate = 44_100
    let channels = 1
    let bitsPerSample = 16
    let byteRate = sampleRate * channels * bitsPerSample / 8
    let blockAlign = channels * bitsPerSample / 8
    let dataSize = byteRate * seconds

    var data = Data()
    func append(_ string: String) { data.append(contentsOf: Array(string.utf8)) }
    func append(u32 value: Int) { data.append(contentsOf: withUnsafeBytes(of: UInt32(value).littleEndian, Array.init)) }
    func append(u16 value: Int) { data.append(contentsOf: withUnsafeBytes(of: UInt16(value).littleEndian, Array.init)) }

    append("RIFF")
    append(u32: 36 + dataSize)
    append("WAVE")
    append("fmt ")
    append(u32: 16)
    append(u16: 1)
    append(u16: channels)
    append(u32: sampleRate)
    append(u32: byteRate)
    append(u16: blockAlign)
    append(u16: bitsPerSample)
    append("data")
    append(u32: dataSize)
    data.append(Data(count: dataSize))

    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(UUID().uuidString).wav")
    try data.write(to: url)
    return url
}
